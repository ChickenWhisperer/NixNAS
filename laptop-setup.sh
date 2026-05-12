#!/usr/bin/env bash
#
# laptop-setup.sh — run once on the laptop, as your normal user.
#
# Generates two things:
#   1. An SSH keypair at ~/.ssh/id_ed25519, used to authenticate to
#      the NAS as the backup user and as root (for unlocking).
#   2. The NAS encryption-key file at ~/.config/nas-key, derived as
#      sha256(passphrase). The passphrase itself is never stored, so
#      if this laptop is destroyed you can reconstruct the key from
#      memory using nas-recover.sh.
#

set -euo pipefail

SSH_KEY="${HOME}/.ssh/id_ed25519"
KEY_FILE="${HOME}/.config/nas-key"

# ---- SSH key ----
if [ -f "$SSH_KEY" ]; then
  echo "SSH key already exists at $SSH_KEY (keeping it)."
else
  echo "Generating SSH key at $SSH_KEY"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
fi

# ---- Encryption key ----
if [ -f "$KEY_FILE" ]; then
  echo
  echo "Key file already exists at $KEY_FILE."
  echo "Refusing to overwrite. Delete it manually if you really want to regenerate."
  exit 1
fi

mkdir -p "$(dirname "$KEY_FILE")"

cat <<'EOF'

Choose a passphrase for the NAS encryption.

IMPORTANT: write it down somewhere safe (paper in a fireproof box, a
password manager that syncs off this laptop, a steel plate in a safe,
etc). If you forget the passphrase AND lose this laptop, the NAS data
is unrecoverable. ZFS encryption has no backdoor.

EOF

read -rsp "Passphrase: " PASS; echo
read -rsp "Confirm:    " PASS2; echo

if [ "$PASS" != "$PASS2" ]; then
  echo "Passphrases don't match. Aborting." >&2
  unset PASS PASS2
  exit 1
fi

if [ "${#PASS}" -lt 16 ]; then
  cat >&2 <<'EOF'

Warning: passphrase is shorter than 16 characters.

SHA-256 is a fast hash, so an attacker who steals just the disks can
try billions of passphrases per second. A short or common passphrase
will not survive that. Consider 4-5 random dictionary words or a long
sentence.

EOF
  read -rp "Continue anyway? [y/N] " yn
  if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
    unset PASS PASS2
    exit 1
  fi
fi

printf '%s' "$PASS" | sha256sum | awk '{printf "%s", $1}' > "$KEY_FILE"
chmod 600 "$KEY_FILE"
unset PASS PASS2

cat <<EOF

================================================================
Done.

1. Encryption key written to: $KEY_FILE

2. Paste this SSH public key into nas-configuration.nix, in all three
   places marked LAPTOP_SSH_PUBKEY:

EOF
cat "${SSH_KEY}.pub"
cat <<EOF

3. After deploying nas-configuration.nix on the NAS, copy this script
   and the key file over and run nas-setup.sh as root:

     scp $KEY_FILE nas-setup.sh YOUR_USERNAME@YOUR_NAS_IP:/tmp/
     ssh YOUR_USERNAME@YOUR_NAS_IP 'sudo bash /tmp/nas-setup.sh /tmp/nas-key'
     ssh YOUR_USERNAME@YOUR_NAS_IP 'shred -u /tmp/nas-key /tmp/nas-setup.sh'

================================================================
EOF
