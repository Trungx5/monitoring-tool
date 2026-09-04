#!/bin/sh
#
# Installs node_exporter as a monitored agent: fetched, verified, run as its
# own unprivileged user, protected by Basic Auth, and reachable only from the
# monitoring server.
#
# The password is generated here and printed once at the end. It is never sent
# anywhere - you paste it into the dashboard yourself - so this script can be
# fetched over plain HTTPS from a public URL without leaking anything.
#
#   curl -fsSL https://monitoringtool.duckdns.org/install-agent.sh \
#     | sudo sh -s -- --monitor-ip 14.225.215.235
#
# Options:
#   --monitor-ip ADDR     only this address may reach the exporter (required)
#   --bind ADDR           listen address, default 0.0.0.0 (see --bind note below)
#   --port PORT           default 9100
#   --user NAME           Basic Auth username, default monitor
#   --version VER         node_exporter version, default below
#
# Re-running is safe: it replaces the binary and config and restarts the
# service. A new password is generated each run, so update the dashboard.

set -eu

VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
PORT=9100
BIND="0.0.0.0"
AUTH_USER="monitor"
MONITOR_IP=""
EXPORTER_USER="node_exporter"
CONF_DIR="/etc/node_exporter"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --monitor-ip) MONITOR_IP="${2:-}"; shift 2 ;;
        --bind)       BIND="${2:-}";       shift 2 ;;
        --port)       PORT="${2:-}";       shift 2 ;;
        --user)       AUTH_USER="${2:-}";  shift 2 ;;
        --version)    VERSION="${2:-}";    shift 2 ;;
        -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
        *)            die "unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run this with sudo"
[ -n "$MONITOR_IP" ] || die "--monitor-ip is required.
Pass the public address of your monitoring server, so the firewall rule
allows that machine and nothing else. Without it the exporter would be
open to anyone who finds the port."

command -v systemctl >/dev/null 2>&1 || die "this installer needs systemd"

# ---------------------------------------------------------------- packages
step "Checking prerequisites"
if command -v apt-get >/dev/null 2>&1; then
    PKG_INSTALL="apt-get install -y -qq"
    HTPASSWD_PKG="apache2-utils"
    apt-get update -qq >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    PKG_INSTALL="dnf install -y -q"
    HTPASSWD_PKG="httpd-tools"
elif command -v yum >/dev/null 2>&1; then
    PKG_INSTALL="yum install -y -q"
    HTPASSWD_PKG="httpd-tools"
else
    die "no supported package manager found (apt-get, dnf or yum)"
fi

for bin in curl tar; do
    command -v "$bin" >/dev/null 2>&1 || $PKG_INSTALL "$bin" >/dev/null
done
# htpasswd is the only portable way to produce the bcrypt hash the exporter
# expects; its own toolkit accepts nothing weaker.
command -v htpasswd >/dev/null 2>&1 || $PKG_INSTALL "$HTPASSWD_PKG" >/dev/null
command -v htpasswd >/dev/null 2>&1 || die "could not install htpasswd ($HTPASSWD_PKG)"

case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l|armv7)  ARCH=armv7 ;;
    armv6l)        ARCH=armv6 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac
say "    architecture: $ARCH"

# ---------------------------------------------------------------- download
step "Downloading node_exporter $VERSION"
TARBALL="node_exporter-${VERSION}.linux-${ARCH}.tar.gz"
BASE="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

curl -fsSL "${BASE}/${TARBALL}" -o "${TMP}/${TARBALL}" \
    || die "download failed. If version ${VERSION} no longer exists, re-run with
  --version <a version listed at github.com/prometheus/node_exporter/releases>"

# Verified against the checksum file published with the same release. This
# catches truncated and corrupted downloads; it is not protection against a
# compromised release, since both files come from the same place.
step "Verifying checksum"
if curl -fsSL "${BASE}/sha256sums.txt" -o "${TMP}/sha256sums.txt" 2>/dev/null; then
    EXPECTED="$(grep " ${TARBALL}\$" "${TMP}/sha256sums.txt" | awk '{print $1}')"
    ACTUAL="$(sha256sum "${TMP}/${TARBALL}" | awk '{print $1}')"
    [ -n "$EXPECTED" ] || die "no checksum published for ${TARBALL}"
    [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch - refusing to install.
  expected $EXPECTED
  got      $ACTUAL"
    say "    ok"
else
    die "could not fetch the checksum file - refusing to install unverified"
fi

tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
install -m 0755 "${TMP}/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" \
    /usr/local/bin/node_exporter

# ------------------------------------------------------------------ config
step "Creating user and configuration"
id -u "$EXPORTER_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$EXPORTER_USER"

AUTH_PASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-22)"
HASH="$(htpasswd -nbBC 10 "" "$AUTH_PASS" | tr -d ':\n' | sed 's/^\$2y\$/\$2y\$/')"

mkdir -p "$CONF_DIR"
cat > "${CONF_DIR}/web-config.yml" <<EOF
# Generated by install-agent.sh. The hash below is bcrypt; the plaintext
# password was printed once at install time and is not stored here.
basic_auth_users:
  ${AUTH_USER}: ${HASH}
EOF
chown -R root:"$EXPORTER_USER" "$CONF_DIR"
chmod 0750 "$CONF_DIR"
chmod 0640 "${CONF_DIR}/web-config.yml"

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${EXPORTER_USER}
Group=${EXPORTER_USER}
ExecStart=/usr/local/bin/node_exporter \\
    --web.listen-address=${BIND}:${PORT} \\
    --web.config.file=${CONF_DIR}/web-config.yml
Restart=always
RestartSec=5

# This process only reads /proc and /sys. Nothing it does needs write access
# to the filesystem or any capability at all.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter >/dev/null 2>&1
systemctl restart node_exporter

# ---------------------------------------------------------------- firewall
# Basic Auth over plain HTTP is base64, not encryption - anyone who can read
# the traffic can read the password. Restricting who can reach the port at all
# is the stronger control, which is why it comes first and the password second.
#
# An inactive firewall is never enabled here: turning on ufw or firewalld
# without an SSH rule already in place locks you out of your own machine.
step "Restricting access to ${MONITOR_IP}"
FW_DONE=no
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow from "$MONITOR_IP" to any port "$PORT" proto tcp >/dev/null
    say "    ufw rule added"
    FW_DONE=yes
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" \
source address=\"${MONITOR_IP}\" port port=\"${PORT}\" protocol=\"tcp\" accept" >/dev/null
    firewall-cmd --reload >/dev/null
    say "    firewalld rule added"
    FW_DONE=yes
fi

# ------------------------------------------------------------------ report
sleep 1
systemctl is-active --quiet node_exporter \
    || die "node_exporter did not start. Check: journalctl -u node_exporter -n 30"

HOST_ADDR="$BIND"
[ "$HOST_ADDR" = "0.0.0.0" ] && HOST_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$HOST_ADDR" ] || HOST_ADDR="<this machine's address>"

cat <<EOF

────────────────────────────────────────────────────────────────
 node_exporter is running.

 Add this target in the dashboard, under VPS Monitor → Add VPS:

   Target URL   http://${HOST_ADDR}:${PORT}/metrics
   Username     ${AUTH_USER}
   Password     ${AUTH_PASS}

 The password is shown here once and is not recoverable. Re-run
 this script to generate a new one.
────────────────────────────────────────────────────────────────
EOF

if [ "$FW_DONE" = no ]; then
    cat <<EOF
 NOTE: no active firewall was found, so port ${PORT} may be open to
 everyone. Basic Auth alone is weak over plain HTTP. Restrict it:

   ufw allow OpenSSH                 # do this first, or you lose SSH
   ufw allow from ${MONITOR_IP} to any port ${PORT} proto tcp
   ufw enable

 Or, if the machine is on a private network such as Tailscale,
 re-run with --bind <that interface's address> so the exporter
 never listens on the public one.

EOF
fi
