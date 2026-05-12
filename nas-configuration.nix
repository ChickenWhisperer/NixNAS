#
# nas-configuration.nix
#
# Full NixOS configuration for a headless NAS running gitea, with an
# encrypted ZFS mirror, daily scrubs, hourly snapshots, nightly auto-
# updates, and a 04:00 reboot.
#
# Use this as your /etc/nixos/configuration.nix on the NAS:
#   sudo cp nas-configuration.nix /etc/nixos/configuration.nix
#   sudo nixos-rebuild switch
#
# Before deploying, fill in:
#   - YOUR_HOSTID    (head -c4 /dev/urandom | od -A none -t x4)
#   - YOUR_TIMEZONE  (e.g. America/New_York; see /etc/zoneinfo for list)
#   - YOUR_USERNAME  (your admin account)
#   - LAPTOP_SSH_PUBKEY  (one full ssh-ed25519 line, pasted in 3 places)
#   - YOUR_NAS_IP    (only inside the gitea ROOT_URL, if you don't use Avahi)
#
# After first deploy, gitea will fail to start (the pool doesn't exist
# yet). Run nas-setup.sh, then `systemctl restart gitea`.
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

  # Must be unique to this machine. Generate with:
  #   head -c4 /dev/urandom | od -A none -t x4
  networking.hostId = "YOUR_HOSTID";

  # We intentionally do NOT use boot.zfs.extraPools. That option creates
  # a hard boot dependency on the pool existing — fine in steady state,
  # but it makes the system unbootable before the pool has been created
  # (the very first boot of this config), and turns a missing or
  # disconnected disk into a boot failure on a headless box.
  #
  # Instead we define a "best effort" import service that's allowed to
  # fail gracefully. The pool still auto-imports whenever it's present.
  boot.zfs.extraPools = [ ];

  systemd.services.zfs-import-tank = {
    description = "Import ZFS pool tank (best effort)";
    wantedBy = [ "zfs-import.target" ];
    after = [ "systemd-udev-settle.service" ];
    requires = [ "systemd-udev-settle.service" ];
    before = [ "zfs-mount.service" ];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathIsDirectory = "/proc/spl/kstat/zfs";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # `|| true` so the unit succeeds even when the pool doesn't exist.
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.zfs}/bin/zpool import -aN || true'";
    };
  };

  # Daily scrub at 02:00 (no-op if pool isn't imported)
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
      "LAPTOP_SSH_PUBKEY"   # paste the full ssh-ed25519 line here
    ];
  };

  # Dedicated user that the laptop SSHs in as to push rsync backups.
  # Its home is set to the encrypted ZFS dataset, so backups land
  # directly on the mirror.
  users.users.backup = {
    isNormalUser = true;
    home = "/tank/backups";
    createHome = false;  # the ZFS dataset provides this
    openssh.authorizedKeys.keys = [
      "LAPTOP_SSH_PUBKEY"   # same key as above
    ];
  };

  # Root SSH login (key-only) is allowed so the laptop's unlock-nas
  # service can load the ZFS key without a sudo prompt — sudo can't
  # prompt when stdin is the key file. If you'd rather not allow root
  # login at all, set up passwordless sudo for specific zfs commands
  # in security.sudo.extraRules instead.
  users.users.root.openssh.authorizedKeys.keys = [
    "LAPTOP_SSH_PUBKEY"   # same key as above
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;       # key-only
      PermitRootLogin = "prohibit-password"; # root via key only
    };
  };

  # ---- Gitea ----
  # Gitea fails to start until tank/encrypted is unlocked and mounted.
  # That's expected after every reboot. The laptop's unlock-nas service
  # handles it at 04:05; for manual unlock during setup, see README.
  services.gitea = {
    enable = true;
    stateDir = "/tank/gitea";
    lfs.enable = true;
    settings = {
      server = {
        # If you've set up Avahi/mDNS, you can use "nas.local" here.
        # Otherwise use your NAS's static LAN IP.
        DOMAIN = "YOUR_NAS_IP";
        ROOT_URL = "http://YOUR_NAS_IP:3000/";
        HTTP_PORT = 3000;
        SSH_PORT = 22;
      };
      service.DISABLE_REGISTRATION = true;
    };
  };

  # Convenience wrapper for gitea admin commands. After deploy, you can
  # run `gitea-admin admin user create --username ... --admin` etc.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "gitea-admin" ''
      exec sudo -u gitea ${config.services.gitea.package}/bin/gitea \
        --config /tank/gitea/custom/conf/app.ini "$@"
    '')
  ];

  # ---- Sanoid snapshots ----
  # Hourly snapshots make sense for gitea (data changes throughout the
  # day as you push commits). The backup dataset only receives writes
  # once a day at 03:00, so hourly snapshots there would be 23/24 empty
  # — daily-only is tidier.
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
      daily-only = {
        hourly = 0;
        daily = 30;
        monthly = 6;
        autosnap = true;
        autoprune = true;
      };
    };
    datasets = {
      "tank/encrypted/gitea".useTemplate = [ "default" ];
      "tank/encrypted/backups" = {
        useTemplate = [ "daily-only" ];
        recursive = true;  # also snapshot child datasets atomically
      };
    };
  };

  # ---- Sleep/suspend prevention ----
  # A NAS should never suspend on its own. logind handles lid/idle;
  # the masked targets are belt-and-suspenders against anything else
  # on the system trying to call systemctl suspend.
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

  # 04:00 reboot. After reboot the pool is LOCKED until the laptop's
  # unlock-nas service fires at 04:05.
  systemd.timers.nightly-reboot = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*-*-* 04:00:00";
  };
  systemd.services.nightly-reboot = {
    serviceConfig.Type = "oneshot";
    script = "${pkgs.systemd}/bin/systemctl reboot";
  };

  system.stateVersion = "25.11";
}
