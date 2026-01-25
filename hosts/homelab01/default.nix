# Homelab Server - Optiplex 5080
# Primary server for self-hosted services
{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
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
      ];
    };
    kernel-hardening = {
      enable = true;
      level = "desktop";
    };
    apparmor.enable = true;
    firewall = {
      enable = true;
      # Service ports are opened by individual service modules
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

    reverse-proxy = {
      enable = true;
      email = "cory@gyarmathy.co";
      cloudflareTokenFile = config.sops.templates."caddy-cloudflare-env".path;

      services = {
        # Media - User Facing
        jellyfin = {
          subdomain = "jellyfin";
          port = 8096;
          localOnly = false;
        };
        requests = {
          subdomain = "requests";
          port = 5055;
          localOnly = false;
        };
        invite = {
          subdomain = "invite";
          port = 5690;
          localOnly = false;
        };

        # Media - Admin
        sonarr = {
          subdomain = "sonarr";
          port = 8989;
          localOnly = true;
        };
        radarr = {
          subdomain = "radarr";
          port = 7878;
          localOnly = true;
        };
        prowlarr = {
          subdomain = "prowlarr";
          port = 9696;
          localOnly = true;
        };
        bazarr = {
          subdomain = "bazarr";
          port = 6767;
          localOnly = true;
        };

        # Management
        huntarr = {
          subdomain = "huntarr";
          port = 9705;
          localOnly = true;
        };
        cleanuparr = {
          subdomain = "cleanuparr";
          port = 11011;
          localOnly = true;
        };

        # Monitoring
        grafana = {
          subdomain = "grafana";
          port = 3000;
          localOnly = true;
        };
        prometheus = {
          subdomain = "prometheus";
          port = 9090;
          localOnly = true;
        };

        # Infrastructure (homelab01's AdGuard)
        adguard = {
          subdomain = "adguard";
          port = 3080;
          localOnly = true;
        };

        downloads = {
          subdomain = "downloads";
          port = 8080; # qBittorrent
          localOnly = true;
        };
      };
    };

    adguard-home = {
      enable = true;
      role = "primary";
      webPort = 3080;
      bindAddresses = [
        "127.0.0.1"
        "10.20.2.85"
      ];
      # Route homelab02's services to homelab02
      extraRewrites = [
        # {
        #   domain = "downloads.gyarmathy.co";
        #   answer = "10.20.2.130";
        # }
        {
          domain = "adguard2.gyarmathy.co";
          answer = "10.20.2.130";
        }
      ];
    };

    # Media-stack
    # Shared infrastructure (REQUIRED)
    media-stack.enable = true;

    # Individual services
    jellyfin.enable = true;
    jellyseerr.enable = true;

    sonarr.enable = true;
    radarr.enable = true;
    prowlarr.enable = true;
    bazarr.enable = true;

    qbittorrent = {
      enable = true;
      vpn.enable = true;
    };

    flaresolverr.enable = true;

    recyclarr.enable = true;
    huntarr.enable = true;
    cleanuparr.enable = true;
    wizarr.enable = true;
    cross-seed = {
      enable = true;
      # Your private tracker indexer IDs from Prowlarr
      # Find at: Prowlarr -> Indexers -> click tracker -> ID in URL
      torznabIndexerIds = [ 8 ]; # IPT
      matchMode = "partial";
      includeSingleEpisodes = true;
    };
    unpackerr.enable = true;
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
    hostName = "homelab01";
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

    # Hardware monitoring
    lm_sensors
    intel-gpu-tools # For monitoring Quick Sync usage
    libva-utils # Provides vainfo for checking VA-API

    # Container management
    podman-compose

    # Network utilities
    ethtool
    iperf3
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
    # Explicit GID for container compatibility
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
