#!/usr/bin/env bash
#
# recover.sh — full recovery onto a FRESH NixOS install.
#
# Scenario: your laptop is dead/lost. You have a new machine with a
# fresh NixOS install, on the same LAN as the (still working) NAS, and
# you remember your passphrase. This script:
#
#   1. Re-derives the encryption key from your passphrase
#   2. Generates a new SSH key on this machine
#   3. Unlocks both encryption roots on the NAS (you authenticate with
#      your NAS account password — this is why the NAS config keeps
#      PasswordAuthentication enabled)
#   4. Authorizes the new SSH key for the backup user
#   5. Pulls your entire backed-up home directory onto this machine
#   6. Re-locks the backups dataset and restores the nightly setup
#
# Requirements on this machine: ssh, scp, rsync, sha256sum.
# On a minimal NixOS install:  nix-shell -p openssh rsync coreutils
#
# KEEP A COPY OF THIS SCRIPT OFF YOUR LAPTOP: USB stick, printout,
# email to yourself. It can't help you if it only lives on the dead
# machine. (Your passphrase, written down separately, is the other
# half of the recovery story.)
#
# ----------------------------------------------------------------
# If the NAS ITSELF is dead: move the two data disks into any Linux
# machine with ZFS tools and run, as root:
#
#   zpool import -f tank
#   read -rs PASS; KEY=$(printf '%s' "$PASS" | sha256sum | awk '{print $1}')
#   printf '%s' "$KEY" | zfs load-key tank/gitea-enc
#   printf '%s' "$KEY" | zfs load-key tank/backups-enc
#   zfs mount -a
#
# Your data is then at /tank/backups/laptop and /tank/gitea.
# ----------------------------------------------------------------
#

set -euo pipefail

# ---- Tool check ----
for cmd in ssh scp rsync sha256sum ssh-keygen; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    echo "On NixOS: nix-shell -p openssh rsync coreutils" >&2
    exit 1
  fi
done

cat <<'EOF'
================================================================
NAS Recovery — fresh machine, working NAS
================================================================

You will be asked for:
  - The NAS's IP address
  - Your admin username on the NAS
  - Your NAS account password (a few times, for SSH + sudo)
  - Your memorized encryption passphrase (once)

EOF

read -rp "NAS IP address: " NAS_IP
read -rp "Your admin username on the NAS: " NAS_USER

# Reuse one SSH connection for all admin-user operations so you only
# type the account password once.
CTRL_DIR="$(mktemp -d)"
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$CTRL_DIR/cm" -o ControlPersist=10m -o StrictHostKeyChecking=accept-new)
trap 'ssh -O exit -o "ControlPath=$CTRL_DIR/cm" "$NAS_USER@$NAS_IP" 2>/dev/null; rm -rf "$CTRL_DIR"' EXIT

# ---- Step 1: derive the key ----
cat <<'EOF'

Type your memorized passphrase. It must match EXACTLY — same
capitalization, spaces, punctuation. If the unlock fails later,
just re-run this script and try again.

EOF
read -rsp "Passphrase: " PASS; echo
KEY="$(printf '%s' "$PASS" | sha256sum | awk '{print $1}')"
unset PASS

if [ "${#KEY}" -ne 64 ]; then
  echo "Internal error: derived key isn't 64 chars. Aborting." >&2
  unset KEY
  exit 1
fi

# ---- Step 2: new SSH key for this machine ----
SSH_KEY="${HOME}/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY" ]; then
  echo "Generating SSH key at $SSH_KEY"
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
fi

# ---- Step 3+4: unlock the NAS and authorize this machine ----
# The key and pubkey go to the NAS's /tmp, a root script consumes them
# (you'll type your account password for SSH, then again for sudo),
# and the key material is shredded on the NAS afterwards.
echo
echo "Copying key material to the NAS (enter your NAS account password)..."
printf '%s' "$KEY" > "$CTRL_DIR/recover.key"
unset KEY
scp "${SSH_OPTS[@]}" -q "$CTRL_DIR/recover.key" "${SSH_KEY}.pub" \
  "$NAS_USER@$NAS_IP:/tmp/" 
rm -f "$CTRL_DIR/recover.key"

cat > "$CTRL_DIR/remote.sh" <<'REMOTE'
set -euo pipefail
mv /tmp/id_ed25519.pub /tmp/recover.pub 2>/dev/null || true

# Import the pool if this boot's import didn't happen
if ! zpool list tank &>/dev/null; then
  zpool import tank 2>/dev/null || zpool import -d /dev/disk/by-id tank
fi

# Unlock both encryption roots (skip any already unlocked)
for ds in tank/gitea-enc tank/backups-enc; do
  if [ "$(zfs get -H -o value keystatus "$ds")" != "available" ]; then
    zfs load-key -L file:///tmp/recover.key "$ds"
  fi
done
zfs mount -a
mountpoint -q /tank/backups/laptop || { echo "backups dataset failed to mount" >&2; exit 1; }

# Authorize the new machine's key for the backup user so rsync can
# pull without a password (the backup account has no password).
mkdir -p /tank/backups/.ssh
cat /tmp/recover.pub >> /tank/backups/.ssh/authorized_keys
chown -R backup:users /tank/backups/.ssh
chmod 700 /tank/backups/.ssh
chmod 600 /tank/backups/.ssh/authorized_keys

# Defensive: ensure gitea's expected state skeleton exists before restart.
# On an existing pool it already does; this guards the edge case where it
# doesn't. Safe here because `zfs mount -a` ran above, so /tank/gitea is a
# real mountpoint, not a stub on the root filesystem.
mkdir -p /tank/gitea/custom/conf
chown gitea:gitea /tank/gitea /tank/gitea/custom /tank/gitea/custom/conf

systemctl restart gitea || true
shred -u /tmp/recover.key /tmp/recover.pub
echo "NAS unlocked; new machine authorized."
REMOTE
scp "${SSH_OPTS[@]}" -q "$CTRL_DIR/remote.sh" "$NAS_USER@$NAS_IP:/tmp/remote.sh"

echo "Unlocking the NAS (enter your password again if sudo asks)..."
ssh "${SSH_OPTS[@]}" -t "$NAS_USER@$NAS_IP" 'sudo bash /tmp/remote.sh && rm -f /tmp/remote.sh'

# ---- Step 5: pull everything back ----
cat <<EOF

Pulling your home directory from the NAS into $HOME
(existing files with the same names will be overwritten; nothing is
deleted). This includes your OLD SSH key, which the NAS config already
trusts — so after this completes, the normal nightly setup works
without touching the NAS config.

EOF
rsync -aAXH --info=progress2 \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
  "backup@$NAS_IP:/tank/backups/laptop/" "$HOME"/

# ---- Step 6: restore nightly-setup state and re-lock backups ----
# ~/.config/nas-key came back with the rsync (same passphrase → same
# derived key), but write it explicitly in case the pull was partial.
mkdir -p "$HOME/.config"
# Re-derive rather than keep it in a variable this whole time:
read -rsp "Passphrase once more (to write ~/.config/nas-key): " PASS; echo
printf '%s' "$PASS" | sha256sum | awk '{printf "%s", $1}' > "$HOME/.config/nas-key"
unset PASS
chmod 600 "$HOME/.config/nas-key"

echo
echo "Re-locking the backups dataset (gitea stays up)..."
ssh "${SSH_OPTS[@]}" -t "$NAS_USER@$NAS_IP" \
  'sudo bash -c "zfs unmount tank/backups-enc/laptop; zfs unmount tank/backups-enc; zfs unload-key tank/backups-enc"'

cat <<'EOF'

================================================================
Recovery complete.

  - Your home directory is restored.
  - gitea is up; backups are re-sealed.
  - Your old SSH key is back at ~/.ssh/id_ed25519 and is the one
    the NAS's configuration.nix trusts declaratively.

Remaining steps to make this machine the new "laptop":

  1. Copy laptop-configuration.nix into /etc/nixos/, fill in your
     username and the NAS IP, import it from configuration.nix,
     and run: sudo nixos-rebuild switch
  2. Verify the timers exist:
       systemctl list-timers | grep -E 'nas-backup|unlock-nas'
  3. Optionally run a manual backup to confirm the loop:
       sudo systemctl start nas-backup

================================================================
EOF
