# Homelab Server - HP Elitedesk 800 G6 SFF
# NAS / secondary server for self-hosted services
#
# ROLE: Storage + Download
# - ZFS pool of 2x4TB HDDs
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
  # Auto-Upgrade
  # ============================================================================
  system.autoUpgrade = {
    enable = true;
    flake = "github:corygyarmathy/dotfiles#homelab02";
    dates = "04:15"; # Offset from homelab01
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "05:00";
    };
    randomizedDelaySec = "10min";
  };

  # ============================================================================
  # Module Toggles
  # ============================================================================
  cg = {
    # Security modules
    sops-nix.enable = true;
    ssh-hardening = {
      enable = true;
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGN2/Vvyb3abKAxdCYt9pxGgOho5uqtNzhpXVxGVw1gq coryg@xps15" # Allow access from your XPS 15
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDuSTywA1OKdG6SxdhkzaGvUFmWpvm592XJHKt0zNEsU coryg@homelab01"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPWfMUll4YosHtfkgs/68GAaszVU/VM94IrQzz4xZuPN restic-backup"
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
  };

  # ============================================================================
  # Service Toggles
  # ============================================================================

  cg.service = {
    backup = {
      enable = true;

      # homelab02 receives homelab01's cross-server backups here
      incomingPath = "/srv/backups/homelab01";

      paths = [
        # All arr service configs
        "/srv/arr"

        # Services with state outside /srv/arr
        "/var/lib/private/AdGuardHome"
      ];

      extraExclude = [
        # cross-seed logs are ~1GB
        "/srv/arr/cross-seed/logs/**"
      ];

      repositories = {
        # Cross-server: back up to homelab01
        cross-server = {
          repository = "sftp:coryg@10.20.2.85:/srv/backups/homelab02";
          schedule = "02:30";
        };
        # Offsite: Google Drive via rclone
        gdrive = {
          repository = "rclone:gdrive:backups/homelab/homelab02";
          schedule = "03:00";
        };
      };
    };
    immich.enable = false;
    home-assistant.enable = false;
    filebrowser.enable = true;

    monitoring = {
      enable = true;
      prometheus.enable = true;
      alertmanager = {
        enable = true;
        clusterPeers = [ "homelab01" ];
        email = {
          to = "cory@gyarmathy.co";
          from = "alerts@gyarmathy.co";
          authUsername = "alerts@gyarmathy.co";
          # smarthost uses the default (smtp.protonmail.ch:587)
        };
      };
      grafana.enable = false;
      zfs.enable = true;
      scrapeTargets = [
        "homelab01:9100"
        "homelab02:9100"
      ];
      smartctlTargets = [
        "homelab01:9633"
        "homelab02:9633"
      ];
      cloudflaredTarget = "homelab01:20241";

      vpn.enable = true;

      httpProbes = [
        {
          name = "jellyfin";
          url = "https://jellyfin.gyarmathy.co";
        }
        {
          name = "requests";
          url = "https://requests.gyarmathy.co";
        }
        {
          name = "sonarr";
          url = "https://sonarr.gyarmathy.co";
        }
        {
          name = "radarr";
          url = "https://radarr.gyarmathy.co";
        }
        {
          name = "prowlarr";
          url = "https://prowlarr.gyarmathy.co";
        }
        {
          name = "downloads";
          url = "https://downloads.gyarmathy.co";
        }
        {
          name = "grafana";
          url = "https://grafana.gyarmathy.co";
        }
        {
          name = "adguard-01";
          url = "https://adguard.gyarmathy.co";
        }
        {
          name = "adguard-02";
          url = "https://adguard2.gyarmathy.co";
        }
        {
          name = "autobrr";
          url = "https://autobrr.gyarmathy.co";
        }
        {
          name = "miniflux";
          url = "https://rss.gyarmathy.co";
        }
        {
          name = "wallabag";
          url = "https://read.gyarmathy.co";
        }
        {
          name = "filebrowser";
          url = "https://filebrowser.gyarmathy.co";
        }
      ];
    };

    orphan-cleanup = {
      enable = true;
      schedule = "daily";
      minAgeDays = 7;
      dryRun = false;
    };

    private-torrent-cleanup = {
      enable = true;
      schedule = "daily";
      minFreeGiB = 1000;
      minSeedTimeDays = 14;
      dryRun = false;
    };

    # -------------------------------------------------------------------------
    # NAS Storage (ZFS + NFS)
    # -------------------------------------------------------------------------
    # Note: The underlying disk mounts are handled by ZFS.
    # This module only sets up the ZFS pool and NFS export.
    nas-storage = {
      enable = true;
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

        # FileBrowser
        filebrowser = {
          subdomain = "filebrowser";
          port = 8085;
          rateLimitProfile = "media";
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
    };

    # -------------------------------------------------------------------------
    # Media Stack (Storage Server Mode)
    # -------------------------------------------------------------------------
    # On homelab02, media-stack provides local storage infrastructure
    # for the download services. The storage is exported via NFS.
    media-stack = {
      enable = true;
      dataPath = "/srv/media"; # ZFS pool
      configPath = "/srv/arr"; # Local config (not shared)
      user = "coryg";
      group = "media";
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
    seerr.enable = false;
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
  # ZFS Support
  # ============================================================================
  # The ZFS pool is NOT managed declaratively - it must be created manually:
  #
  #   sudo zpool create -f \
  #     -o ashift=12 \
  #     -O compression=lz4 \
  #     -O atime=off \
  #     -O xattr=sa \
  #     -O acltype=posixacl \
  #     -O mountpoint=/srv/media \
  #     tank /dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ES3V
  #
  #   sudo zpool add tank /dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ETEH
  #
  # The pool persists across OS reinstalls. extraPools imports it at boot.
  boot = {
    supportedFilesystems = [ "zfs" ];
    zfs.forceImportRoot = false;
    zfs.extraPools = [ "tank" ];
  };
  # Required for ZFS - must be unique per machine
  # Generate with: head -c 8 /etc/machine-id
  networking.hostId = "a7377c6b";
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
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
  # Firmware Updates (automated via fwupd)
  # ============================================================================
  services.fwupd.enable = true;

  # Run firmware updates BEFORE nixos-upgrade so any pending firmware
  # gets applied during the reboot that nixos-upgrade may trigger
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
  # Services
  # ============================================================================

  # Disable sleep/suspend - this is a server
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowSuspendThenHibernate = "no";
    AllowHybridSleep = "no";
  };

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
  # Swap
  # ============================================================================
  # Swapfile on the OS disk (ext4), NOT on ZFS to avoid deadlocks.
  swapDevices = [
    {
      device = "/swapfile";
      size = 16384; # MB (16 GB)
    }
  ];

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
