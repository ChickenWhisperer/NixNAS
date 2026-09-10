#
# laptop-configuration.nix  (Design A: split encryption roots)
#
# Import this from your existing /etc/nixos/configuration.nix:
#
#   imports = [
#     ./hardware-configuration.nix
#     ./laptop-configuration.nix
#   ];
#
# Before deploying:
#   - Run laptop-setup.sh once (generates ~/.ssh/id_ed25519 and
#     ~/.config/nas-key).
#   - Replace every YOUR_USERNAME with your real username.
#   - Replace every YOUR_NAS_IP with the NAS's static LAN IP.
#
# Encryption model on the NAS (two independent encryption roots, one key):
#   tank/gitea-enc    unlocked at 04:05, stays up all day
#   tank/backups-enc  locked ~23.9h/day; this module unlocks it for the
#                     duration of the 03:00 rsync, then re-locks it
#
# Nightly schedule:
#   03:00  unlock backups-enc -> rsync home -> re-lock backups-enc
#   03:30  nixos-rebuild switch from updated channel
#   03:45  nix-collect-garbage
#   03:50  nix-store --optimise
#   04:05  unlock gitea-enc on the NAS (it rebooted at 04:00)
#

{ config, pkgs, ... }:

{
  services.openssh.enable = true;

  # Manual helper: after any unscheduled NAS reboot, run `unlock-nas`
  # to bring gitea back up. (Backups stay sealed; the 03:00 bracket
  # opens them only while syncing.)
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "unlock-nas" ''
      set -e
      KEY_FILE="$HOME/.config/nas-key"
      if [ ! -f "$KEY_FILE" ]; then
        echo "Key file not found at $KEY_FILE — run laptop-setup.sh first." >&2
        exit 1
      fi
      ${pkgs.openssh}/bin/ssh root@YOUR_NAS_IP \
        'zfs load-key tank/gitea-enc 2>/dev/null; zfs mount tank/gitea-enc; systemctl --no-block restart gitea' \
        < "$KEY_FILE"
      echo "gitea unlocked."
    '')
  ];

  # ---- 03:00 bracketed backup: unlock -> rsync -> re-lock ----
  systemd.services.nas-backup = {
    description = "rsync home directory to NAS (bracketed unlock)";
    serviceConfig = {
      Type = "oneshot";
      User = "YOUR_USERNAME";
    };
    path = [ pkgs.rsync pkgs.openssh ];
    script = ''
      KEY_FILE="/home/YOUR_USERNAME/.config/nas-key"

      # Unlock and mount the backups encryption root. If any step fails,
      # abort loudly — rsync against an unmounted path would just error
      # against the empty stub directory (the backup user can't write
      # there), but there's no reason to even try.
      if ! ssh root@YOUR_NAS_IP \
          'zfs load-key tank/backups-enc 2>/dev/null; zfs mount tank/backups-enc; zfs mount tank/backups-enc/laptop; mountpoint -q /tank/backups/laptop' \
          < "$KEY_FILE"; then
        echo "Failed to unlock/mount backups dataset on NAS; aborting." >&2
        exit 1
      fi

      rc=0
      rsync -aAXH --delete \
        --exclude='.cache' \
        --exclude='.local/share/Trash' \
        --exclude='.local/share/docker' \
        --exclude='.local/share/containers' \
        --exclude='.steam' \
        --exclude='.local/share/Steam' \
        --exclude='node_modules' \
        --exclude='.npm' \
        --exclude='.cargo/registry' \
        --exclude='.rustup' \
        --exclude='.gradle/caches' \
        --exclude='.m2/repository' \
        -e "ssh -i /home/YOUR_USERNAME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" \
        /home/YOUR_USERNAME/ \
        backup@YOUR_NAS_IP:/tank/backups/laptop/ || rc=$?

      # Re-lock no matter what happened above. Sanoid snapshots still
      # run against the locked dataset (snapshotting is a metadata
      # operation and works while sealed).
      ssh root@YOUR_NAS_IP \
        'zfs unmount tank/backups-enc/laptop; zfs unmount tank/backups-enc; zfs unload-key tank/backups-enc'

      exit $rc
    '';
  };
  systemd.timers.nas-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;  # if missed (laptop asleep), run on next boot
    };
  };

  # ---- 03:30 nix-channel --update && nixos-rebuild switch ----
  system.autoUpgrade = {
    enable = true;
    dates = "03:30";
    allowReboot = false;
  };

  # ---- 03:45 nix-collect-garbage ----
  nix.gc = {
    automatic = true;
    dates = "03:45";
    options = "--delete-older-than 30d";
  };

  # ---- 03:50 nix-store --optimise ----
  nix.optimise = {
    automatic = true;
    dates = [ "03:50" ];
  };

  # ---- 04:05 unlock gitea on the NAS after its 04:00 reboot ----
  # Only gitea-enc. The backups root stays sealed until tomorrow's
  # 03:00 bracket.
  systemd.services.unlock-nas = {
    description = "Unlock the NAS gitea dataset after nightly reboot";
    serviceConfig = {
      Type = "oneshot";
      User = "YOUR_USERNAME";
    };
    path = [ pkgs.openssh ];
    script = ''
      # Wait up to 5 minutes for the NAS to come back from its reboot.
      for i in $(seq 1 30); do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
             root@YOUR_NAS_IP true 2>/dev/null; then
          break
        fi
        sleep 10
      done
      ssh root@YOUR_NAS_IP \
        'zfs load-key tank/gitea-enc && zfs mount tank/gitea-enc && systemctl --no-block restart gitea' \
        < /home/YOUR_USERNAME/.config/nas-key
    '';
  };
  systemd.timers.unlock-nas = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:05:00";
      Persistent = true;
    };
  };

  # ---- Lid behavior ----
  # The nightly jobs run while you're away, so the laptop must stay
  # awake when plugged in. Plug in before bed.
  services.logind = {
    lidSwitch = "suspend";              # on battery: suspend
    lidSwitchExternalPower = "lock";    # plugged in: lock only
    lidSwitchDocked = "ignore";         # docked: stay on
  };

  # ---- Optional: nightly reboot ----
  # Uncomment to reboot the laptop at 04:15 (after the unlock has
  # fired). Catches config bugs on a schedule you control and applies
  # kernel updates promptly.
  #
  # systemd.timers.nightly-reboot = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig.OnCalendar = "*-*-* 04:15:00";
  # };
  # systemd.services.nightly-reboot = {
  #   serviceConfig.Type = "oneshot";
  #   script = "${pkgs.systemd}/bin/systemctl reboot";
  # };
}
