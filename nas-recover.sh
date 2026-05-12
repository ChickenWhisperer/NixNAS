#!/usr/bin/env bash
#
# nas-recover.sh
#
# Walks you through unlocking the NAS encrypted pool and copying data
# off it, in the scenario where the laptop is dead/lost and you only
# have your memorized passphrase.
#
# Run this on any Linux machine with ZFS userland tools available:
#   - On the NAS itself if the NAS is still functional
#   - On a NixOS live ISO if you've moved the disks elsewhere
#     (nix-shell -p zfs to get the tools)
#   - On any distro with `zfsutils-linux` installed
#
# How the original encryption was set up:
#   - You chose a passphrase and memorized it.
#   - The actual ZFS key is sha256(passphrase), 64 hex characters.
#   - The laptop kept the hex on disk so daily unlocks were automatic.
#   - This script regenerates the hex from the passphrase you remember.
#
# KEEP A COPY OF THIS SCRIPT OFF THE LAPTOP. A USB stick, a printout,
# an email to yourself — anywhere you can reach if the laptop is dead.
#

set -euo pipefail

cat <<'EOF'
================================================================
NAS Recovery
================================================================

This script will:
  1. Re-derive the encryption key from your memorized passphrase
  2. Help you unlock the ZFS pool ("tank")
  3. Mount the encrypted datasets
  4. Print useful next-step commands

You can quit at any time with Ctrl-C; nothing destructive happens
without an explicit "YES" confirmation.

EOF

# ---- Sanity: do we have the tools? ----
for cmd in zpool zfs sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    echo "On NixOS live ISO, run: nix-shell -p zfs" >&2
    echo "On Debian/Ubuntu: apt install zfsutils-linux coreutils" >&2
    exit 1
  fi
done

# ---- Step 1: Find or import the pool ----
echo "Step 1: Locate the pool"
echo "-----------------------"
echo

if zpool list tank &>/dev/null; then
  echo "Pool 'tank' is already imported on this machine."
else
  echo "Scanning for importable pools..."
  echo
  zpool import || true
  echo
  cat <<'EOF'
If you saw a pool named 'tank' above, we'll import it now.

If you're running this on a NEW machine (the NAS died, you moved the
disks elsewhere), you'll need -f to force the import because the pool
remembers it belonged to a different machine. This is expected and
safe — there's no other machine currently using these disks.

EOF
  read -rp "Import 'tank' now? [y/N] " yn
  if [ "$yn" != "y" ] && [ "$yn" != "Y" ]; then
    echo "Aborted. You can import manually later with: zpool import -f tank"
    exit 0
  fi
  sudo zpool import -f tank
  echo "Pool imported."
fi
echo

# ---- Step 2: Re-derive the key from passphrase ----
echo "Step 2: Re-derive the encryption key"
echo "-------------------------------------"
echo
cat <<'EOF'
Type your memorized passphrase below. It will not be echoed.

IMPORTANT: it must match EXACTLY — same capitalization, same spaces,
same punctuation. The key is computed as:

    sha256(passphrase)  (with no trailing newline)

If you typo it, the unlock will fail; just run this script again.

EOF

read -rsp "Passphrase: " PASS; echo
KEY="$(printf '%s' "$PASS" | sha256sum | awk '{print $1}')"
unset PASS

if [ "${#KEY}" -ne 64 ]; then
  echo "Internal error: key isn't 64 chars (got ${#KEY}). Aborting." >&2
  unset KEY
  exit 1
fi

echo "Key derived (64 hex characters). Not displayed for safety."
echo

# ---- Step 3: Load the key ----
echo "Step 3: Unlock the dataset"
echo "---------------------------"
echo

KEYSTATUS="$(sudo zfs get -H -o value keystatus tank/encrypted 2>/dev/null || echo missing)"

if [ "$KEYSTATUS" = "available" ]; then
  echo "Pool is already unlocked. Skipping key load."
elif [ "$KEYSTATUS" = "missing" ]; then
  cat >&2 <<'EOF'

Couldn't find dataset 'tank/encrypted'. Either the pool layout is
different than expected, or the import didn't actually work.

Run `zfs list` to see what's actually there. The encrypted dataset
might be named differently (e.g. 'tank/enc' or just 'tank').

EOF
  unset KEY
  exit 1
else
  printf '%s' "$KEY" | sudo zfs load-key tank/encrypted
  echo "Key loaded successfully."
fi
unset KEY
echo

# ---- Step 4: Mount everything ----
echo "Step 4: Mount the datasets"
echo "---------------------------"
echo
sudo zfs mount -a
echo "Mounted. Current state:"
echo
zfs list -o name,mountpoint,used
echo
echo "Your data should now be accessible at /tank/ (or wherever the"
echo "datasets are mounted, per the list above)."
echo

# ---- Step 5: Next steps ----
echo "Step 5: What to do next"
echo "------------------------"
cat <<'EOF'

If you're recovering on the NAS itself, restart gitea so it picks up
the now-mounted state directory:

  sudo systemctl restart gitea

Common things you might want to do now:

  # Copy your laptop home backup to an external drive:
  rsync -aAXH --info=progress2 /tank/backups/laptop/ /mnt/external-drive/

  # Tar it up to a single archive (good for cold storage):
  tar -czf /mnt/external-drive/laptop-backup.tar.gz -C /tank/backups laptop

  # Pull a specific file:
  cp /tank/backups/laptop/Documents/whatever.pdf ~/Desktop/

  # See what's in the gitea repos (bare repos, use git clone to access):
  ls /tank/gitea/repositories/

  # Browse a previous snapshot (read-only):
  ls /tank/backups/laptop/.zfs/snapshot/

You're done with this script. The pool will stay unlocked until the
machine reboots or you run `zfs unload-key tank/encrypted`.
EOF
