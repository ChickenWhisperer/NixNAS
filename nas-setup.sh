#!/usr/bin/env bash
#
# nas-setup.sh — run once on the NAS, as root.
#
# Run AFTER nas-configuration.nix has been deployed (it creates the
# 'backup' user this script chowns to; gitea failing to start until
# this script finishes is expected).
#
# Usage:
#
#   sudo ./nas-setup.sh KEYFILE DISK1 DISK2
#       Fully non-interactive except the final YES confirmation.
#
#   sudo ./nas-setup.sh KEYFILE
#       Prompts for the two disk paths.
#
# Recommended workflow from the laptop (all copy-paste happens in your
# laptop's terminal; the NAS needs no console or GUI):
#
#   ssh YOUR_USERNAME@YOUR_NAS_IP 'ls -l /dev/disk/by-id/' | grep -v part
#   scp ~/.config/nas-key nas-setup.sh YOUR_USERNAME@YOUR_NAS_IP:/tmp/
#   ssh YOUR_USERNAME@YOUR_NAS_IP \
#     'sudo bash /tmp/nas-setup.sh /tmp/nas-key \
#       /dev/disk/by-id/ata-... /dev/disk/by-id/ata-...'
#   ssh YOUR_USERNAME@YOUR_NAS_IP 'shred -u /tmp/nas-key /tmp/nas-setup.sh'
#
# Creates (Design A: two independent encryption roots, one shared key):
#
#   tank                        (mirror, mountpoint=none)
#   tank/gitea-enc              encryption root -> /tank/gitea
#   tank/backups-enc            encryption root -> /tank/backups
#   tank/backups-enc/laptop     child            -> /tank/backups/laptop
#
# gitea-enc and backups-enc lock/unlock independently: gitea stays
# unlocked all day, backups are unlocked only during the 03:00 sync.
# Both use the same key (sha256 of your passphrase), so recovery needs
# only the one passphrase.
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

if [ -z "$KEYFILE" ] || [ ! -f "$KEYFILE" ]; then
  echo "Usage: $0 KEYFILE [DISK1 DISK2]" >&2
  echo "KEYFILE is the 64-char hex file produced by laptop-setup.sh" >&2
  exit 1
fi
KEYFILE="$(realpath "$KEYFILE")"

# Validate key contents (strip whitespace for the check only; the file
# itself is used as-is by ZFS, so it must already be clean).
KEYCHECK="$(tr -d '[:space:]' < "$KEYFILE")"
if [ "${#KEYCHECK}" -ne 64 ]; then
  echo "Key file should contain exactly 64 hex characters, found ${#KEYCHECK}." >&2
  echo "Regenerate with laptop-setup.sh (it writes the file without a newline)." >&2
  unset KEYCHECK
  exit 1
fi
unset KEYCHECK

# ---- Pick disks ----
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
  [ -z "$DISK1" ] && read -rp "First data disk  (full path): " DISK1
  [ -z "$DISK2" ] && read -rp "Second data disk (full path): " DISK2
fi

[ -e "$DISK1" ] || { echo "Not found: $DISK1" >&2; exit 1; }
[ -e "$DISK2" ] || { echo "Not found: $DISK2" >&2; exit 1; }

echo
echo "About to ERASE and create a ZFS mirror on:"
echo "  $DISK1"
echo "  $DISK2"
echo
read -rp "Type 'YES' to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  echo "Aborted."
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

# ---- Encryption root #1: gitea ----
# Explicit mountpoints everywhere: the dataset name and the filesystem
# path should correspond visibly (a hard-won lesson).
zfs create \
  -o encryption=aes-256-gcm \
  -o keyformat=hex \
  -o keylocation="file://$KEYFILE" \
  -o mountpoint=/tank/gitea \
  tank/gitea-enc

# ---- Encryption root #2: backups ----
zfs create \
  -o encryption=aes-256-gcm \
  -o keyformat=hex \
  -o keylocation="file://$KEYFILE" \
  -o mountpoint=/tank/backups \
  tank/backups-enc

zfs create \
  -o mountpoint=/tank/backups/laptop \
  tank/backups-enc/laptop

# ---- Switch key sources to prompt (stdin) ----
# From now on, keys are piped over SSH from the laptop; nothing on the
# NAS can unlock the pool by itself.
zfs set keylocation=prompt tank/gitea-enc
zfs set keylocation=prompt tank/backups-enc

# ---- Permissions ----
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
zfs list -o name,encryption,keystatus,mountpoint,used,available

cat <<'EOF'

Both encryption roots are currently unlocked. After any reboot they
are locked again. Normal operation:

  - gitea-enc:   unlocked by the laptop's unlock-nas timer at 04:05
                 (or manually: run `unlock-nas` on the laptop)
  - backups-enc: unlocked only during the 03:00 backup bracket

Now on the NAS: systemctl restart gitea
(it was failing until this pool existed; it should start cleanly now).

Finally, shred the key file you copied here:
  shred -u /tmp/nas-key

EOF
