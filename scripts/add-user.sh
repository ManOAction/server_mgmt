#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo ./add_user.sh <username> <public_key_file>
# Example: sudo ./add_user.sh deploy /tmp/deploy_id_rsa.pub

USERNAME="${1:-}"
PUBKEY_FILE="${2:-}"

if [[ -z "$USERNAME" || -z "$PUBKEY_FILE" ]]; then
  echo "Usage: $0 <username> <public_key_file>"
  exit 1
fi

if [[ ! -f "$PUBKEY_FILE" ]]; then
  echo "Public key file not found: $PUBKEY_FILE" >&2
  exit 1
fi

# 1) Create user if not exists
if id "$USERNAME" &>/dev/null; then
  echo "User $USERNAME already exists."
else
  echo "Creating user $USERNAME..."
  useradd -m -s /bin/bash "$USERNAME"
  passwd -l "$USERNAME"        # disable password login
fi

# 2) Add to sudo group (optional — comment out if not needed)
usermod -aG sudo "$USERNAME"

# 3) Setup SSH directory
USER_HOME="$(eval echo ~$USERNAME)"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
cat "$PUBKEY_FILE" >> "$AUTH_KEYS"

# 4) Fix permissions
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

# 5) Report
echo "User $USERNAME created/updated."
echo "Authorized key installed from $PUBKEY_FILE"
echo "Password login disabled. Use SSH keys only."

# 6) Quick test reminder
echo ">>> Test new login in another session before closing this one:"
echo "    ssh -i <private_key> ${USERNAME}@<your-host>"
