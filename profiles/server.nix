# What it costs to be a server in this fleet.
#
# A server here is a machine that is expected to be up, reboots unattended
# inside the nightly upgrade window, and is administered over SSH rather than
# sat in front of. Everything below follows from one of those three facts.
#
# Read ./common.nix first: the rule that a profile has no options applies here
# too. What a given server *runs* is not in this file - that is the `cg.*` and
# `cg.service.*` toggles in hosts/<name>/default.nix, and it is the part of a
# host file worth reading.
#
# Imported alongside ./common.nix, not instead of it.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # ============================================================================
  # Accounts
  # ============================================================================
  users = {
    # Nobody logs in as root. `cg.ssh-hardening` already refuses root over SSH;
    # this closes the console too.
    users.root.hashedPassword = "!"; # locks the account

    users.coryg = {
      # The password comes from SOPS, so it is the same after a reinstall and
      # is never set by hand. This is why `mutableUsers` can be off.
      #
      # Declared here rather than in `cg.sops-nix` because this is the only
      # thing that reads it: the laptop leaves `mutableUsers` alone and has no
      # use for the hash, and a secret nothing consumes is a secret a machine
      # should not be able to decrypt.
      hashedPasswordFile = config.sops.secrets."users/coryg".path;

      # Fixed, because files in the media tree are owned by it and that tree
      # outlives any particular install of either server.
      uid = 1000;

      extraGroups = [
        "podman" # container management
        "media" # access to media files
        "render" # GPU access
        "video" # video device access
      ];
    };

    # Shared file access between services. The GID is explicit for container
    # compatibility AND NFS consistency: both servers must agree on it or the
    # NFS export is owned by different groups on either side of the mount.
    groups.media.gid = 1011;

    # Nothing declares an account outside this repository.
    mutableUsers = false;
  };

  # `neededForUsers` puts it in /run/secrets-for-users, which is populated
  # before the users are built - an ordinary secret is decrypted too late for
  # a password hash to be read.
  sops.secrets."users/coryg".neededForUsers = true;

  # The home-manager side of that account. Identical on both servers, and
  # deliberately minimal - a shell prompt and the CLI tools, no desktop.
  home-manager.users.coryg = import ./home/server.nix;

  # ============================================================================
  # Networking
  # ============================================================================
  # Addresses are DHCP reservations recorded in fleet/default.nix, not static
  # configuration here. `mkForce` because the generated hardware.nix sets this
  # too and there is no value in the two disagreeing quietly.
  networking.useDHCP = lib.mkForce true;

  # ============================================================================
  # Staying awake
  # ============================================================================
  # A server that suspends is a server that is down.
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowSuspendThenHibernate = "no";
    AllowHybridSleep = "no";
  };

  # A server that is off should be startable without walking to it. Which
  # interface to arm is a fact about the machine, not about being a server, so
  # each host names its own in `cg.wake-on-lan.interfaces` - see
  # modules/nixos/wake-on-lan.nix for why that half is a module.
  cg.wake-on-lan.enable = true;

  # ============================================================================
  # Firmware
  # ============================================================================
  services.fwupd.enable = true;

  # Run firmware updates BEFORE nixos-upgrade, so anything pending is applied
  # during the reboot that nixos-upgrade may trigger rather than waiting for an
  # unrelated one. Servers only: the laptop applies firmware when asked, from
  # `cg.auto-upgrade`.
  systemd.services.fwupd-auto-update = {
    description = "Automatic firmware updates";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "nixos-upgrade.service" ];
    wantedBy = [ "nixos-upgrade.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.fwupd}/bin/fwupdmgr update -y --no-reboot";
      # Exit codes: 0=success, 1=no updates, 2=no devices
      SuccessExitStatus = [
        0
        1
        2
      ];
    };
  };

  # ============================================================================
  # Containers
  # ============================================================================
  # Several service modules run upstream images rather than packaging them;
  # podman is what they run on.
  virtualisation.podman = {
    enable = true;
    dockerCompat = true; # provides the `docker` command alias
    defaultNetwork.settings.dns_enabled = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # ============================================================================
  # System Packages
  # ============================================================================
  # What is needed to diagnose one of these machines over SSH at 2am. Anything
  # a *service* needs belongs to that service's module, not here.
  environment.systemPackages = with pkgs; [
    # System utilities
    vim
    neovim
    git
    htop
    btop
    tmux
    curl
    wget
    dig
    tree

    # Disk and storage utilities
    ncdu
    iotop
    smartmontools

    # Hardware monitoring
    lm_sensors
    intel-gpu-tools # for monitoring Quick Sync usage
    libva-utils # provides vainfo for checking VA-API

    # Container management
    podman-compose

    # Network utilities
    ethtool
    iperf3
    nfs-utils
  ];
}
