#
# nas-configuration.nix  (Design A: split encryption roots)
#
# Full NixOS configuration for a headless NAS running gitea, with an
# encrypted ZFS mirror, daily scrubs, snapshots, nightly auto-updates,
# and a 04:00 reboot.
#
# Use as /etc/nixos/configuration.nix on the NAS.
#
# Before deploying, fill in:
#   - YOUR HOSTID       head -c4 /dev/urandom | od -A none -t x4 OR YOUR OLD HOSTID IF YOU HAVE ONE
#   - YOUR TIMEZONE     e.g. America/New_York
#   - YOUR USERNAME     your admin account
#   - YOUR NAS_IP       the NAS's static LAN IP (reserve it in your router)
#   - LAPTOP SSH PUBKEY the ssh-ed25519 line from laptop-setup.sh
#                       (pasted in THREE places)
#   - system.stateVersion  the NixOS release you FIRST installed with;
#                          never change it afterwards
#
# Dataset layout (created by nas-setup.sh):
#   tank/gitea-enc           -> /tank/gitea    (unlocked all day)
#   tank/backups-enc         -> /tank/backups  (unlocked ~minutes/day)
#   tank/backups-enc/laptop  -> /tank/backups/laptop
#

{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # ---- Boot ----
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ---- ZFS ----
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "YOUR_HOSTID";

  # We intentionally do NOT use boot.zfs.extraPools. That option makes
  # the pool a hard boot dependency — fine in steady state, but it
  # makes the system unbootable before the pool has been created (the
  # very first boot of this config) and turns a missing disk into a
  # boot failure on a headless box.
  boot.zfs.extraPools = [ ];

  # Best-effort import with a retry loop. Historical note: earlier
  # versions of this service depended on systemd-udev-settle.service
  # to wait for disk enumeration; that unit was removed from modern
  # systemd, which made the service silently never run. The retry loop
  # achieves the same thing without the dependency: try the import,
  # and if the disks haven't enumerated yet, wait and try again.
  systemd.services.zfs-import-tank = {
    description = "Import ZFS pool tank (best effort)";
    wantedBy = [ "zfs-import.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "zfs-mount.service" ];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathIsDirectory = "/proc/spl/kstat/zfs";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for i in $(seq 1 12); do
        if ${pkgs.zfs}/bin/zpool list tank &>/dev/null; then
          exit 0
        fi
        ${pkgs.zfs}/bin/zpool import -aN 2>/dev/null && exit 0
        sleep 5
      done
      echo "Pool 'tank' not found after 60s; continuing without it."
      exit 0
    '';
  };

  # Daily scrub at 02:00 (no-op if pool isn't imported). Scrubs work
  # on locked datasets — they verify checksums of the ciphertext.
  services.zfs.autoScrub = {
    enable = true;
    interval = "*-*-* 02:00:00";
    pools = [ "tank" ];
  };
  services.zfs.trim.enable = true;

  # ---- Networking ----
  networking.hostName = "nas";
  networking.networkmanager.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 3000 ];
  time.timeZone = "YOUR_TIMEZONE";

  # ---- Users ----
  users.users.YOUR_USERNAME = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "LAPTOP_SSH_PUBKEY"
    ];
  };

  # Dedicated user the laptop SSHs in as to push rsync backups. Home is
  # the backups dataset mountpoint, so backups land on the mirror.
  users.users.backup = {
    isNormalUser = true;
    home = "/tank/backups";
    createHome = false;  # the ZFS dataset provides this
    openssh.authorizedKeys.keys = [
      "LAPTOP_SSH_PUBKEY"
    ];
  };

  # Root SSH login (key-only) lets the laptop's unlock and backup
  # brackets run `zfs load-key` with the key on stdin — sudo can't
  # prompt for a password when stdin carries the key.
  users.users.root.openssh.authorizedKeys.keys = [
    "LAPTOP_SSH_PUBKEY"
  ];

  services.openssh = {
    enable = true;
    settings = {
      # Password auth is enabled for regular users because recover.sh
      # (disaster recovery from a brand-new laptop with no trusted SSH
      # key) authenticates with your account password. Root remains
      # key-only regardless. If you set this to false, recovery from a
      # fresh machine requires console access to the NAS to authorize
      # a new key first.
      PasswordAuthentication = true;
      PermitRootLogin = "prohibit-password";
    };
  };

  # ---- Gitea ----
  services.gitea = {
    enable = true;
    stateDir = "/tank/gitea";
    lfs.enable = true;
    settings = {
      server = {
        DOMAIN = "YOUR_NAS_IP";
        ROOT_URL = "http://YOUR_NAS_IP:3000/";
        HTTP_PORT = 3000;
        SSH_PORT = 22;
      };
      service.DISABLE_REGISTRATION = true;
    };
  };

  # THE critical hardening: gitea must be structurally unable to start
  # against a bare directory. If the dataset isn't mounted (pool locked,
  # import failed, whatever), gitea simply stays down instead of
  # initializing a fresh database on the root filesystem — a failure
  # mode that looks like "my password stopped working" and costs an
  # evening to debug. The 04:05 unlock ends with a gitea restart, so
  # the system self-heals every morning.
  systemd.services.gitea = {
    unitConfig.ConditionPathIsMountPoint = "/tank/gitea";
    after = [ "zfs-mount.service" ];
  };

  # Gitea's NixOS pre-start script copies a default app.ini into
  # <stateDir>/custom/conf but never creates that directory tree, so on a
  # fresh (empty) dataset it fails and gitea hits its start-limit.
  # Recreate the skeleton on every rebuild. Guarded on the mountpoint so we
  # never create ghost directories on the root filesystem when the pool is
  # locked (the exact bug that produced the stray /tank/encrypted dir).
  # The directories live on the dataset, so once created they persist across
  # reboots and this acts as a repair/no-op thereafter.
  system.activationScripts.giteaStateSkeleton = ''
    if ${pkgs.util-linux}/bin/mountpoint -q /tank/gitea; then
      mkdir -p /tank/gitea/custom/conf
      chown gitea:gitea /tank/gitea /tank/gitea/custom /tank/gitea/custom/conf
    fi
  '';

  # Convenience wrapper for gitea CLI administration:
  #   gitea-admin admin user create --username you --random-password --admin
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "gitea-admin" ''
      exec sudo -u gitea ${config.services.gitea.package}/bin/gitea \
        --config /tank/gitea/custom/conf/app.ini "$@"
    '')
  ];

  # ---- Sanoid snapshots ----
  # Snapshots are metadata operations and work on locked datasets, so
  # backups-enc keeps its snapshot history even though it's sealed for
  # all but a few minutes a day.
  services.sanoid = {
    enable = true;
    templates = {
      default = {
        hourly = 24;
        daily = 30;
        monthly = 6;
        autosnap = true;
        autoprune = true;
      };
      # The backup dataset only receives writes once a day at 03:00;
      # hourly snapshots of it would be 23/24 empty.
      daily-only = {
        hourly = 0;
        daily = 30;
        monthly = 6;
        autosnap = true;
        autoprune = true;
      };
    };
    datasets = {
      "tank/gitea-enc".useTemplate = [ "default" ];
      "tank/backups-enc" = {
        useTemplate = [ "daily-only" ];
        recursive = true;  # include tank/backups-enc/laptop atomically
      };
    };
  };

  # ---- Sleep/suspend prevention ----
  # A NAS should never suspend. logind covers lid/idle; the masked
  # targets stop anything else from calling systemctl suspend.
  services.logind = {
    lidSwitch = "ignore";
    lidSwitchExternalPower = "ignore";
    lidSwitchDocked = "ignore";
  };
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # ---- Nightly maintenance ----
  # 03:30 nix-channel --update && nixos-rebuild switch
  system.autoUpgrade = {
    enable = true;
    dates = "03:30";
    allowReboot = false;  # we reboot explicitly at 04:00
  };

  # 03:45 nix-collect-garbage
  nix.gc = {
    automatic = true;
    dates = "03:45";
    options = "--delete-older-than 30d";
  };

  # 03:50 nix-store --optimise
  nix.optimise = {
    automatic = true;
    dates = [ "03:50" ];
  };

  # 04:00 reboot. Applies kernel updates promptly and surfaces config
  # bugs on a schedule you control instead of at a random bad moment.
  # After reboot both encryption roots are LOCKED; gitea stays down
  # (mount condition) until the laptop's 04:05 unlock brings it up.
  systemd.timers.nightly-reboot = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 04:00:00";
  };
  systemd.services.nightly-reboot = {
    serviceConfig.Type = "oneshot";
    script = "${pkgs.systemd}/bin/systemctl reboot";
  };

  # Set to the NixOS release you FIRST installed this machine with.
  # Do not change it on upgrades.
  system.stateVersion = "26.05";
}
