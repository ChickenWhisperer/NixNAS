# nix-nas-backup

A declarative, encrypted NAS + automated nightly backup setup on NixOS.

Pair a NAS (running gitea, ZFS mirror, snapshots, daily scrubs) with a
laptop (running rsync backups, auto-updates, screen-locked overnight).
Everything is configured in plain NixOS modules; the only state outside
the configs is a small encryption-key file on the laptop.

## What you get

- **Encrypted ZFS mirror** on the NAS, using a key derived from a
  passphrase you memorize. If the laptop dies, you can re-derive the
  key from memory and recover all data.
- **Hourly/daily/monthly snapshots** via sanoid, with point-in-time
  browsing (`/tank/backups/laptop/.zfs/snapshot/<name>/`) and `zfs diff`
  for change tracking.
- **Daily ZFS scrub** at 02:00 to catch silent disk corruption early.
- **Nightly rsync backup** of the laptop's home directory at 03:00,
  with sensible excludes for caches and container layers.
- **Auto-update + garbage collect + optimise + reboot** at 03:30–04:00
  on both machines.
- **Automatic pool unlock** at 04:05 from the laptop, so gitea comes
  back up after the nightly NAS reboot without manual intervention.
- **Gitea** running on the NAS for hosting personal repos, with state
  on the encrypted ZFS pool.
- **Recovery script** that walks you through unlocking the pool from
  any Linux machine if both the laptop and NAS die simultaneously.

## Hardware assumptions

- A NAS-style machine with at least three drives:
  - One small SSD for NixOS itself
  - Two larger drives of the same size for the ZFS mirror
- A laptop running NixOS, on the same local network as the NAS.

Different topologies work too — a single 3.5" drive instead of a mirror,
all three drives in a RAIDZ, more child datasets — but you'll need to
adjust the configs. The included scripts assume the mirror layout.

## Software assumptions

- NixOS installed on both machines.
- ZFS userland tools (`zfs`, `zpool`) available — the `nas-configuration.nix`
  enables this, but for recovery on a different machine you'll need a
  NixOS live ISO with ZFS enabled, or another distro with `zfsutils-linux`.

## Setup order

1. **Install NixOS** on both machines normally. `nixos-generate-config`
   produces each machine's `hardware-configuration.nix`.

2. **On the laptop**, run `laptop-setup.sh`. It generates an SSH keypair
   and an encryption-key file derived from a passphrase you choose. The
   passphrase is never stored — write it down somewhere safe.

3. **Edit `nas-configuration.nix`** to fill in:
   - `YOUR_HOSTID` — generate with `head -c4 /dev/urandom | od -A none -t x4`
   - `YOUR_TIMEZONE` — e.g. `America/New_York`
   - `YOUR_USERNAME` — your normal user account
   - `LAPTOP_SSH_PUBKEY` — the pubkey printed by `laptop-setup.sh`
     (paste it into all three places it appears)

4. **Deploy the NAS config**: copy `nas-configuration.nix` to the NAS's
   `/etc/nixos/configuration.nix` and run `sudo nixos-rebuild switch`.
   Gitea will fail to start — expected, the pool doesn't exist yet.

5. **Run `nas-setup.sh` on the NAS**, providing the encryption key and
   the two disk paths as arguments. The entire setup happens from your
   laptop terminal — the NAS does not need a GUI or console access.

   First, list the disks on the NAS so you can see their by-id paths:
   ```
   ssh YOUR_USERNAME@YOUR_NAS_IP 'ls -l /dev/disk/by-id/' | grep -v part
   ```
   Copy the two paths that correspond to your data drives (in your
   laptop terminal, where copy-paste works), then:
   ```
   scp ~/.config/nas-key nas-setup.sh YOUR_USERNAME@YOUR_NAS_IP:/tmp/
   ssh YOUR_USERNAME@YOUR_NAS_IP \
     'sudo bash /tmp/nas-setup.sh /tmp/nas-key /dev/disk/by-id/ata-DISK1 /dev/disk/by-id/ata-DISK2'
   ssh YOUR_USERNAME@YOUR_NAS_IP 'shred -u /tmp/nas-key /tmp/nas-setup.sh'
   ```
   The script confirms before destroying anything (you'll type `YES`
   once). Everything else is non-interactive.

6. **Restart gitea on the NAS**: `sudo systemctl restart gitea`. It
   should now be reachable at `http://YOUR_NAS_IP:3000`.

7. **Edit `laptop-configuration.nix`** to fill in your username, the
   NAS IP, and your timezone. Import it from your existing
   `/etc/nixos/configuration.nix`:
   ```nix
   imports = [ ./hardware-configuration.nix ./laptop-configuration.nix ];
   ```
   Then `sudo nixos-rebuild switch`.

8. **Test the loop**:
   ```
   sudo systemctl start nas-backup
   journalctl -u nas-backup -f
   ```
   First run will be slow (full copy); later runs only transfer changes.

## Daily operation

- 02:00 — NAS scrubs the pool.
- 03:00 — Laptop rsyncs home dir to NAS.
- 03:30 — Both machines pull channel updates and rebuild.
- 03:45 — Both machines garbage-collect the Nix store.
- 03:50 — Both machines optimise the Nix store.
- 04:00 — NAS reboots. (Laptop does not reboot in the default config;
  uncomment the relevant block if you want it to.)
- 04:05 — Laptop sends a recursive unlock command to the NAS, which
  loads the ZFS key, mounts datasets, and restarts gitea.

Gitea, sanoid, and the backup target are all on the encrypted pool, so
they all become available again automatically once 04:05 fires.

To check status the next morning:

```
systemctl list-timers --all | grep -E 'nas-backup|unlock-nas|nightly-reboot'
ssh YOUR_USERNAME@YOUR_NAS_IP 'systemctl is-active gitea && mount | grep -c /tank'
```

The mount count should be 4 (parent dataset + three children).

## Recovery

If the laptop dies, the NAS continues working but won't auto-unlock
after future reboots. Use `nas-recover.sh` from any Linux machine to
unlock manually using your memorized passphrase.

If both die, move the two data disks to any machine with ZFS support
and run `nas-recover.sh` there. It walks through:
- Importing the pool (with `-f` since it remembers a different host)
- Re-deriving the encryption key from your passphrase
- Mounting the datasets so your data is accessible

Keep a copy of `nas-recover.sh` somewhere outside the laptop: a USB
stick in a drawer, an email to yourself, a printout. The script can't
help you if it's only on the dead machine.

## Hostname resolution

The default configuration uses raw IP addresses everywhere. The NAS
should have a static IP — either reserve one in your router's DHCP
settings, or configure a static address on the NAS itself.

If you'd prefer hostnames like `nas.local`, enable Avahi on both
machines:

```nix
services.avahi = {
  enable = true;
  nssmdns4 = true;
  publish = { enable = true; addresses = true; workstation = true; };
  openFirewall = true;
};
```

Then replace `YOUR_NAS_IP` with `nas.local` throughout.

## Security model

- **Encryption at rest.** The ZFS data is encrypted with AES-256-GCM.
  The key is sha256 of a passphrase you choose. The passphrase itself
  is never written to disk; only the derived 64-character hex sits in
  `~/.config/nas-key` on the laptop. This lets you recover the key
  from memory if the laptop is lost.

- **Threat: someone steals just the data disks.** They get nothing —
  the key isn't on those disks. To brute-force the encryption they'd
  need to guess your passphrase, hash each guess, and try it. Choose a
  strong passphrase (4–5 random words minimum); SHA-256 is fast, so
  short/common passphrases will not survive.

- **Threat: someone steals the laptop and only the laptop.** They have
  the key file. The NAS is still on your network and theirs is not, so
  they can't directly unlock anything. Full-disk encryption on the
  laptop closes this hole.

- **Threat: someone steals everything in your house.** Game over.
  ZFS-mirror-plus-snapshots is excellent integrity and uptime
  protection but not a substitute for off-site backup. For anything
  truly irreplaceable, also push to an external cloud or off-site
  machine.

- **Assumption: trusted LAN during initial setup.** The unlock command
  travels from laptop to NAS over SSH, which encrypts everything in
  transit — so passive WiFi sniffing yields ciphertext, not your key.
  Once the laptop has successfully connected to the NAS once, the
  NAS's SSH host key is pinned in `~/.ssh/known_hosts`, and any later
  active MITM attempt fails with a loud host-key mismatch warning.

  The vulnerable window is the *first* SSH connection. The configs
  use `StrictHostKeyChecking=accept-new`, which trusts whatever host
  key the NAS presents that first time. If an attacker is positioned
  on your LAN during initial setup (e.g. your WiFi password leaked
  before you started), they could impersonate the NAS, capture the
  encryption key, and decrypt the disks.

  Best practice: do the initial setup over a wired connection or a
  network you trust. After the host key is pinned, an attacker with
  LAN access alone can no longer intercept the key in transit. (They'd
  need to additionally compromise either the laptop or the NAS to
  read host keys / `known_hosts` — at which point they have bigger
  attack surface than the unlock flow.)

## Customization notes

- **Single disk instead of mirror**: change `mirror "$DISK1" "$DISK2"`
  in `nas-setup.sh` to just `"$DISK1"`. You lose redundancy.
- **RAIDZ instead of mirror** (3+ disks): change to
  `raidz "$DISK1" "$DISK2" "$DISK3"`. You'll need to prompt for the
  third disk path.
- **Different schedule**: edit the `OnCalendar` and `dates` strings in
  the configs. They use [systemd.time(7)](https://www.freedesktop.org/software/systemd/man/systemd.time.html)
  syntax.
- **Different excludes for backup**: edit the `--exclude` list in the
  rsync script inside `laptop-configuration.nix`. Common additions:
  `.npm`, `.cargo/registry`, `.rustup`, `.gradle/caches`, `.m2/repository`.
- **No gitea**: comment out the `services.gitea` block and the
  corresponding `services.sanoid.datasets` entry. The rest works.

## Files

| File | Purpose |
| --- | --- |
| `nas-configuration.nix` | Full NixOS config for the NAS. Use as your `/etc/nixos/configuration.nix`. |
| `laptop-configuration.nix` | NixOS module for the laptop. Import from your existing config. |
| `laptop-setup.sh` | One-time setup on the laptop: generates SSH key + encryption-key file. |
| `nas-setup.sh` | One-time setup on the NAS: creates the encrypted ZFS pool and datasets. |
| `nas-recover.sh` | Standalone recovery walkthrough. Keep a copy off-machine. |

## License

See license file

## Notes

This project *does* include code written by AI.
