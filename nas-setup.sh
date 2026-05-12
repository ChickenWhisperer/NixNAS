#!/usr/bin/env bash
#
# nas-setup.sh — run once on the NAS, as root.
#
# Run AFTER:
#   - laptop-setup.sh has produced an encryption key on the laptop
#   - nas-configuration.nix has been deployed on the NAS (which creates
#     the 'backup' user this script chowns to)
#
# Usage:
#
#   sudo ./nas-setup.sh KEYFILE DISK1 DISK2
#       Fully non-interactive except for the final YES confirmation.
#       This is the recommended invocation.
#
#   sudo ./nas-setup.sh KEYFILE
#       Prompts interactively for the two disk paths.
#
#   sudo ./nas-setup.sh
#       Prompts for everything (you'll need to paste the 64-char key).
#       Annoying without copy-paste; prefer one of the above.
#
# Recommended workflow from the laptop (no console access to the NAS
# needed; all copy-paste happens in your laptop's terminal):
#
#   # 1. Look at available disks
#   ssh YOUR_USERNAME@YOUR_NAS_IP 'ls -l /dev/disk/by-id/' | grep -v part
#
#   # 2. Copy key and script over
#   scp ~/.config/nas-key nas-setup.sh YOUR_USERNAME@YOUR_NAS_IP:/tmp/
#
#   # 3. Run setup with paths copy-pasted from step 1's output
#   ssh YOUR_USERNAME@YOUR_NAS_IP \
#     'sudo bash /tmp/nas-setup.sh /tmp/nas-key \
#       /dev/disk/by-id/ata-... /dev/disk/by-id/ata-...'
#
#   # 4. Clean up
#   ssh YOUR_USERNAME@YOUR_NAS_IP 'shred -u /tmp/nas-key /tmp/nas-setup.sh'
#
# Creates:
#   tank                       (mirror, mountpoint=none)
#   tank/encrypted             (aes-256-gcm, mountpoint=/tank, key from
#                               sha256 of your laptop passphrase)
#   tank/encrypted/gitea       -> mounted at /tank/gitea
#   tank/encrypted/backups     -> mounted at /tank/backups
#   tank/encrypted/backups/laptop -> mounted at /tank/backups/laptop
#

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

if zpool list tank &>/dev/null; then
  echo "Pool 'tank' already exists. Aborting." >&2
  exit 1
fi

# ---- Args ----
KEYFILE="${1:-}"
DISK1="${2:-}"
DISK2="${3:-}"

# ---- Read the key ----
# Priority: $1 (file path) > stdin (if not a tty) > prompt
if [ -n "$KEYFILE" ]; then
  if [ ! -f "$KEYFILE" ]; then
    echo "Key file not found: $KEYFILE" >&2
    exit 1
  fi
  KEY="$(cat "$KEYFILE")"
elif [ ! -t 0 ]; then
  KEY="$(cat)"
else
  echo "Paste the 64-character hex key (contents of laptop's ~/.config/nas-key):"
  read -rp "Key: " KEY
fi

# Strip any whitespace/newlines so e.g. an editor-added trailing newline
# doesn't break the 64-char check.
KEY="${KEY//[$'\t\r\n ']/}"

if [ "${#KEY}" -ne 64 ]; then
  echo "Expected 64 hex characters, got ${#KEY}. Aborting." >&2
  unset KEY
  exit 1
fi

# ---- Pick disks ----
# Skip interactive prompts if both were passed as args.
if [ -z "$DISK1" ] || [ -z "$DISK2" ]; then
  echo
  echo "Available disks (use the by-id path so the pool survives controller"
  echo "reshuffles or moving disks to another machine):"
  echo
  ls -l /dev/disk/by-id/ 2>/dev/null \
    | grep -E 'ata-|nvme-|scsi-' \
    | grep -v -- '-part' \
    || echo "(none found — is /dev/disk/by-id/ populated?)"

  echo
  [ -z "$DISK1" ] && read -rp "First data disk  (full path, e.g. /dev/disk/by-id/ata-...): " DISK1
  [ -z "$DISK2" ] && read -rp "Second data disk (full path):                                " DISK2
fi

[ -e "$DISK1" ] || { echo "Not found: $DISK1" >&2; unset KEY; exit 1; }
[ -e "$DISK2" ] || { echo "Not found: $DISK2" >&2; unset KEY; exit 1; }

echo
echo "About to ERASE and create a ZFS mirror on:"
echo "  $DISK1"
echo "  $DISK2"
echo
read -rp "Type 'YES' to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
  unset KEY
  exit 1
fi

# ---- Pool ----
zpool create -f \
  -o ashift=12 \
  -O compression=zstd \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -m none \
  tank mirror "$DISK1" "$DISK2"

# ---- Encrypted parent dataset ----
# Mountpoint=/tank means children inherit mountpoints under /tank,
# stripping the parent's dataset name. So tank/encrypted/gitea is
# mounted at /tank/gitea (not /tank/encrypted/gitea).
printf '%s' "$KEY" | zfs create \
  -o encryption=aes-256-gcm \
  -o keyformat=hex \
  -o keylocation=prompt \
  -o mountpoint=/tank \
  tank/encrypted
unset KEY

# ---- Children ----
zfs create tank/encrypted/gitea
zfs create tank/encrypted/backups
zfs create tank/encrypted/backups/laptop

# ---- Permissions ----
# The 'backup' user owns its drop folder so the laptop can rsync into
# it. The dataset name is tank/encrypted/backups/laptop but it mounts
# at /tank/backups/laptop (see comment on tank/encrypted above).
if id backup &>/dev/null; then
  chown backup:users /tank/backups/laptop
else
  echo
  echo "Note: 'backup' user doesn't exist yet. After applying the NixOS"
  echo "config that creates it, run:"
  echo "  chown backup:users /tank/backups/laptop"
fi

echo
echo "Done. Pool layout:"
zfs list -o name,encryption,mountpoint,used,available

cat <<'EOF'

The pool is currently unlocked. After any reboot it will be locked
again. The laptop's unlock-nas service handles this automatically at
04:05; for manual unlock during setup, from the laptop:

  ssh root@YOUR_NAS_IP \
    'zfs load-key tank/encrypted && zfs mount -a && systemctl restart gitea' \
    < ~/.config/nas-key

EOF
