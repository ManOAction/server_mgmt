#!/usr/bin/env bash
set -euo pipefail

CONF_DIR="/etc/ssh/sshd_config.d"
CONF_FILE="$CONF_DIR/99-hardening.conf"
MAIN_CONF="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.$(date +%Y%m%d-%H%M%S).bak"

# 0) Preconditions
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi
command -v sshd >/dev/null || { echo "sshd not found"; exit 1; }

# 1) Backup main config (drop-ins are separate)
cp -a "$MAIN_CONF" "$BACKUP"
echo "Backed up $MAIN_CONF -> $BACKUP"

# 2) Ensure drop-in directory exists
mkdir -p "$CONF_DIR"

# 3) Write hardened overlay
cat > "$CONF_FILE" <<'EOF'
# ---- SSHD Hardening Overlay (managed) ----
# Authentication: keys only, no root login
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey

# Protocol & Session policy
Protocol 2
LoginGraceTime 20
MaxAuthTries 3
MaxSessions 10
MaxStartups 10:30:100
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
# Uncomment to restrict who may log in:
# AllowUsers jadmin deploy
# AllowGroups sshusers

# Modern crypto (OpenSSH 8.2+). Adjust if older version complains.
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Logging
SyslogFacility AUTHPRIV
LogLevel VERBOSE
EOF

chmod 644 "$CONF_FILE"
chown root:root "$CONF_FILE"
echo "Wrote $CONF_FILE"

# 4) Validate config syntax BEFORE reload
if sshd -t; then
  echo "Config test passed."
else
  echo "Config test FAILED. Restoring backup…" >&2
  mv -f "$BACKUP" "$MAIN_CONF"
  exit 1
fi

# 5) Reload daemon (safer than restart)
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
else
  systemctl reload sshd || true
fi
echo "sshd reloaded. Keep your current session open and test a new connection."

# 6) Quick report
echo
echo "Active sshd config includes:"
echo " - $MAIN_CONF (backup at $BACKUP)"
echo " - $CONF_FILE"
echo
echo "Tip: test from another terminal before closing this one:"
echo "     ssh -o PreferredAuthentications=publickey jadmin@<your-host>"
