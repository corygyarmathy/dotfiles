# Homelab Server - HP Elitedesk 800 G6 SFF
# NAS / secondary server for self-hosted services
#
# ROLE: Storage + Download
# - MergerFS pool of 2x4TB HDDs (disks managed by disko)
# - NFS export for homelab01
# - qBittorrent + VPN (downloads happen locally on storage)
# - cross-seed (needs access to torrents + media)
# - unpackerr (extracts downloads)
#
# INSTALLATION:
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#homelab02 \
#     root@10.20.2.130
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    # Declarative disk partitioning (manages OS + data disks)
    ./disko.nix

    # Hardware configuration (generate with nixos-generate-config)
    ./hardware.nix

    # Server-specific service modules
    ../../modules/services

    # Shared NixOS modules (reuse what makes sense)
    ../../modules/nixos
  ];

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg = {
    # Security modules
    sops-nix.enable = true;
    ssh-hardening = {
      enable = true;
      authorizedKeys = [
        # Allow access from your XPS 15
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGN2/Vvyb3abKAxdCYt9pxGgOho5uqtNzhpXVxGVw1gq coryg@xps15"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuSTywA1OKdG6SxdhkzaGvUFmWpvm592XJHKt0zNEsU coryg@homelab01"
      ];
    };
    kernel-hardening = {
      enable = true;
      level = "desktop";
    };
    apparmor.enable = true;
    firewall = {
      # Service ports are opened by individual service modules
      enable = true;
    };

    # Auto-upgrade for server
    auto-upgrade = {
      enable = true;
      mode = "server";
      flake = "github:corygyarmathy/dotfiles";
      firmware.enable = true;
      backgroundBuild.enable = true;
      upgradeUsers = [ "coryg" ];
    };
  };

  # ============================================================================
  # Service Toggles
  # ============================================================================

  cg.service = {
    backup.enable = false;
    immich.enable = false;
    home-assistant.enable = false;
    monitoring.enable = true;

    # -------------------------------------------------------------------------
    # NAS Storage (MergerFS + NFS)
    # -------------------------------------------------------------------------
    # Note: The underlying disk mounts are handled by disko.
    # This module only sets up the MergerFS pool and NFS export.
    nas-storage = {
      enable = true;
      diskMountPoints = [
        "/mnt/data/disk1"
        "/mnt/data/disk2"
      ];
      poolPath = "/srv/media";
      nfs = {
        enable = true;
        allowedNetwork = "10.20.2.0/24";
        exportPath = "/srv/media";
      };
      user = "coryg";
      group = "media";
    };

    # -------------------------------------------------------------------------
    # Reverse Proxy (Caddy)
    # -------------------------------------------------------------------------
    reverse-proxy = {
      enable = true;
      email = "cory@gyarmathy.co";
      cloudflareTokenFile = config.sops.templates."caddy-cloudflare-env".path;

      services = {
        # Download client
        downloads = {
          subdomain = "downloads";
          port = 8080; # qBittorrent
          localOnly = true;
          proxyExtraConfig = ''
            # qBittorrent auth fix - strip headers that trigger CSRF protection
            header_up -Origin
            header_up -Referer
            # Increase timeouts for large torrent lists
            transport http {
              response_header_timeout 30s
            }
          '';
        };

        # homelab02's AdGuard instance
        adguard2 = {
          subdomain = "adguard2";
          port = 3080;
          localOnly = true;
        };

        # Future NAS-related services would go here
        # e.g., syncthing, nextcloud, etc.
      };
    };

    # -------------------------------------------------------------------------
    # DNS (AdGuard Home)
    # -------------------------------------------------------------------------
    adguard-home = {
      enable = true;
      role = "secondary";
      webPort = 3080;
      bindAddresses = [
        "127.0.0.1"
        "10.20.2.130"
      ];
      # Route homelab02's services to homelab02
      extraRewrites = [
        # Route downloads subdomain to this host
        {
          domain = "downloads.gyarmathy.co";
          answer = "10.20.2.130";
        }
        {
          domain = "adguard2.gyarmathy.co";
          answer = "10.20.2.130";
        }
      ];
    };

    # -------------------------------------------------------------------------
    # Media Stack (Storage Server Mode)
    # -------------------------------------------------------------------------
    # On homelab02, media-stack provides local storage infrastructure
    # for the download services. The storage is exported via NFS.
    media-stack = {
      enable = true;
      dataPath = "/srv/media"; # MergerFS pool
      configPath = "/srv/arr"; # Local config (not shared)
      user = "coryg";
      group = "media";
      # Storage is local (MergerFS), not NFS
      storage.type = "local";
    };

    # -------------------------------------------------------------------------
    # Download Services (Run on NAS)
    # -------------------------------------------------------------------------
    # These services download files directly to local storage,
    # avoiding NFS write overhead.

    qbittorrent = {
      enable = true;
      vpn.enable = true;
    };

    cross-seed = {
      enable = true;
      # Your private tracker indexer IDs from Prowlarr
      # Find at: Prowlarr -> Indexers -> click tracker -> ID in URL
      torznabIndexerIds = [ 8 ]; # IPT
      matchMode = "partial";
      includeSingleEpisodes = true;
    };

    unpackerr.enable = true;

    # -------------------------------------------------------------------------
    # Services that stay on homelab01
    # -------------------------------------------------------------------------
    jellyfin.enable = false;
    jellyseerr.enable = false;
    sonarr.enable = false;
    radarr.enable = false;
    prowlarr.enable = false;
    bazarr.enable = false;
    flaresolverr.enable = false;
    recyclarr.enable = false;
    huntarr.enable = false;
    cleanuparr.enable = false;
    wizarr.enable = false;
  };

  # ============================================================================
  # Boot Configuration
  # ============================================================================
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    # Use latest LTS kernel for stability on server
    # kernelPackages = pkgs.linuxPackages_6_12;
  };

  # ============================================================================
  # Networking
  # ============================================================================
  networking = {
    # IP reserved by DHCP server
    useDHCP = lib.mkForce true;
    hostName = "homelab02";
    networkmanager.enable = true;
  };

  # ============================================================================
  # Localisation
  # ============================================================================
  time.timeZone = "Australia/Perth";
  i18n = {
    defaultLocale = "en_GB.UTF-8";
    extraLocaleSettings = {
      LC_ADDRESS = "en_AU.UTF-8";
      LC_IDENTIFICATION = "en_AU.UTF-8";
      LC_MEASUREMENT = "en_AU.UTF-8";
      LC_MONETARY = "en_AU.UTF-8";
      LC_NAME = "en_AU.UTF-8";
      LC_NUMERIC = "en_AU.UTF-8";
      LC_PAPER = "en_AU.UTF-8";
      LC_TELEPHONE = "en_AU.UTF-8";
      LC_TIME = "en_AU.UTF-8";
    };
  };

  # Disable root login entirely
  users.users.root = {
    hashedPassword = "!"; # locks the account
  };

  # ============================================================================
  # Hardware
  # ============================================================================
  # Enable hardware acceleration for transcoding (Intel Quick Sync)
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # VAAPI driver for newer Intel GPUs
      intel-vaapi-driver # VAAPI driver for older Intel GPUs
      vpl-gpu-rt # Intel Video Processing Library
      intel-compute-runtime # OpenCL support
    ];
  };

  # Require password for sudo (default), or if you want passwordless sudo for wheel:
  # security.sudo.wheelNeedsPassword = false;

  # ============================================================================
  # Environment
  # ============================================================================
  environment.sessionVariables = {
    GIT_EDITOR = "nvim";
    EDITOR = "nvim";
    # Help applications find VA-API drivers
    LIBVA_DRIVER_NAME = "iHD";
  };

  # ============================================================================
  # Services
  # ============================================================================

  # Firmware updates
  services.fwupd.enable = true;

  # Disable sleep/suspend - this is a server
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
    AllowSuspendThenHibernate=no
    AllowHybridSleep=no
  '';

  # Enable wake-on-LAN
  # You may need to also enable this in BIOS
  systemd.services.enable-wol = {
    description = "Enable Wake-on-LAN";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.ethtool}/bin/ethtool -s eno1 wol g";
    };
  };

  # ============================================================================
  # Virtualisation (for containers)
  # ============================================================================
  virtualisation.podman = {
    enable = true;
    dockerCompat = true; # Provides `docker` command alias
    defaultNetwork.settings.dns_enabled = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # ============================================================================
  # System Packages
  # ============================================================================
  # Basic packages for server administration
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
    mergerfs # For manual pool inspection
    mergerfs-tools # Useful utilities for MergerFS

    # Hardware monitoring
    lm_sensors
    intel-gpu-tools # For monitoring Quick Sync usage
    libva-utils # Provides vainfo for checking VA-API

    # Container management
    podman-compose

    # Network utilities
    ethtool
    iperf3
    nfs-utils # NFS tools
    parted
  ];

  # ============================================================================
  # Users
  # ============================================================================
  users = {
    users.coryg = {
      description = "Cory Gyarmathy";
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "podman" # Container management
        "media" # Access to media files
        "render" # GPU access
        "video" # Video device access
      ];
      hashedPasswordFile = config.sops.secrets."users/coryg".path;
      uid = 1000;
    };

    # Media group for shared file access between services
    # Explicit GID for container compatibility AND NFS consistency
    groups.media.gid = 1011;

    mutableUsers = false;
  };

  # No home-manager for server - keep it simple
  # If you later want user-specific config, add:
  # home-manager.users.coryg = import ./home.nix;

  # ============================================================================
  # System Version
  # ============================================================================
  system.stateVersion = "24.11";
}
