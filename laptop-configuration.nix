#
# laptop-configuration.nix
#
# A NixOS module that turns your laptop into one half of an automated
# NAS backup setup. Import this from your existing configuration.nix:
#
#   imports = [
#     ./hardware-configuration.nix
#     ./laptop-configuration.nix
#   ];
#
# Before deploying:
#   - Run laptop-setup.sh once to generate the SSH key and encryption-
#     key file referenced below.
#   - Replace every YOUR_USERNAME with your real username.
#   - Replace every YOUR_NAS_IP with your NAS's static LAN IP
#     (or with "nas.local" if you've set up Avahi/mDNS).
#
# What this module does:
#   03:00  rsync home directory to NAS
#   03:30  nixos-rebuild switch from updated channel
#   03:45  nix-collect-garbage
#   03:50  nix-store --optimise
#   04:05  send unlock command to NAS (so gitea comes back after its
#          04:00 reboot)
#
# This module deliberately does NOT reboot the laptop. If you want it
# to reboot nightly too, uncomment the nightly-reboot block at the end.
#

{ config, pkgs, ... }:

{
  services.openssh.enable = true;

  # ---- 03:00 backup home dir to NAS ----
  systemd.services.nas-backup = {
    description = "rsync home directory to NAS";
    serviceConfig = {
      Type = "oneshot";
      User = "YOUR_USERNAME";
    };
    path = [ pkgs.rsync pkgs.openssh ];
    script = ''
      rsync -aAXH --delete \
        --exclude='.cache' \
        --exclude='.local/share/Trash' \
        --exclude='.local/share/docker' \
        --exclude='.local/share/containers' \
        --exclude='node_modules' \
        --exclude='.npm' \
        --exclude='.cargo/registry' \
        --exclude='.rustup' \
        --exclude='.gradle/caches' \
        --exclude='.m2/repository' \
        -e "ssh -i /home/YOUR_USERNAME/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new" \
        /home/YOUR_USERNAME/ \
        backup@YOUR_NAS_IP:/tank/backups/laptop/
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

  # ---- 04:05 send unlock command to NAS ----
  # The NAS reboots at 04:00 and comes up with the ZFS pool locked.
  # This service waits for the NAS to be reachable, then SSHes in as
  # root and pipes the encryption key to `zfs load-key`, mounts the
  # datasets, and restarts gitea.
  systemd.services.unlock-nas = {
    description = "Unlock the NAS encrypted pool";
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
        'zfs load-key tank/encrypted && zfs mount -a && systemctl --no-block restart gitea' \
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
  # Don't suspend on lid close when plugged in — just lock the screen.
  # The backup, rebuild, and unlock all run while you're away from the
  # laptop, so it must stay awake at night. Plug in before bed.
  services.logind = {
    lidSwitch = "suspend";                  # on battery: suspend (default)
    lidSwitchExternalPower = "lock";        # plugged in: lock only
    lidSwitchDocked = "ignore";             # docked: stay on
  };

  # ---- Optional: nightly reboot ----
  # Uncomment to reboot the laptop at 04:00 too. Useful if your kernel/
  # initrd updates frequently and you want to apply them automatically.
  # Note that nightly reboots cause Persistent=true timers to run again
  # on next boot if they were missed — usually fine, but means a missed
  # 03:00 backup could fire moments after you sit down in the morning.
  #
  # systemd.timers.nightly-reboot = {
  #   wantedBy = [ "timers.target" ];
  #   timerConfig.OnCalendar = "*-*-* 04:00:00";
  # };
  # systemd.services.nightly-reboot = {
  #   serviceConfig.Type = "oneshot";
  #   script = "${pkgs.systemd}/bin/systemctl reboot";
  # };
}
