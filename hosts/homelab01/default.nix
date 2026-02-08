# Homelab Server - Optiplex 5080
# Primary server for self-hosted services
#
# ROLE: Compute + Streaming
# - Intel Quick Sync for Jellyfin transcoding
# - Media management (Sonarr, Radarr, Prowlarr, etc.)
# - NFS client to homelab02's storage
#
# The media-stack module here runs in "client" mode - it mounts
# storage from homelab02 via NFS.
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
  # Auto-Upgrade
  # ============================================================================
  system.autoUpgrade = {
    enable = true;
    flake = "github:corygyarmathy/dotfiles#homelab01";
    dates = "04:00";
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
  };

  # ============================================================================
  # Service Toggles
  # ============================================================================
  cg.service = {
    backup = {
      # NOTE: currently not working, refer to: https://github.com/rclone/rclone/issues/8873
      enable = false;
      paths = [
        # Media management services (from /srv/arr)
        "/srv/arr/sonarr"
        "/srv/arr/radarr"
        "/srv/arr/prowlarr"
        "/srv/arr/bazarr"
        "/srv/arr/jellyseerr"
        "/srv/arr/recyclarr"
        "/srv/arr/huntarr"
        "/srv/arr/cleanuparr"
        "/srv/arr/wizarr"

        # Jellyfin (separate location)
        "/var/lib/jellyfin"

        # AdGuard Home (primary)
        "/var/lib/private/AdGuardHome"
      ];

      extraExclude = [
        # Jellyfin transcodes and cache (large, regenerable)
        "**/transcodes/**"
      ];
    };
    immich.enable = false;
    home-assistant.enable = false;

    # -------------------------------------------------------------------------
    # Reverse Proxy (Caddy)
    # -------------------------------------------------------------------------
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
          rateLimitProfile = "media"; # Higher limits for media streaming
        };
        requests = {
          subdomain = "requests";
          port = 5055;
          localOnly = false;
          rateLimitProfile = "media"; # Users browse content frequently
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

        # Infrastructure (homelab01's AdGuard)
        adguard = {
          subdomain = "adguard";
          port = 3080;
          localOnly = true;
        };
        grafana = {
          subdomain = "grafana";
          port = 3000;
          localOnly = true;
        };

        # NOTE: downloads subdomain now routes to homelab02 via DNS
        # (see adguard-home.extraRewrites below)

      };

    };

    monitoring = {
      enable = true;
      role = "hub";

      scrapeTargets = [
        "homelab01:9100"
        "homelab02:9100"
      ];

      smartctlTargets = [
        "homelab01:9633"
        "homelab02:9633"
      ];

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

      ];

      alerting = {
        enable = true;
        email = {
          to = "cory@gyarmathy.co";
          from = "alerts@gyarmathy.co";
          authUsername = "alerts@gyarmathy.co";
          # smarthost uses the default (smtp.protonmail.ch:587)
        };
      };
    };

    # -------------------------------------------------------------------------
    # DNS (AdGuard Home)
    # -------------------------------------------------------------------------
    adguard-home = {
      enable = true;
      role = "primary";
      webPort = 3080;
      bindAddresses = [
        "127.0.0.1"
        "10.20.2.85"
      ];
    };

    # -------------------------------------------------------------------------
    # Media Stack (NFS Client Mode)
    # -------------------------------------------------------------------------
    # On homelab01, media-stack mounts storage from homelab02 via NFS.
    # This allows Sonarr/Radarr to manage files that live on the NAS.
    media-stack = {
      enable = true;
      dataPath = "/srv/media";
      configPath = "/srv/arr";
      user = "coryg";
      group = "media";

      # Mount from homelab02
      storage = {
        type = "nfs";
        nfsServer = "10.20.2.130"; # homelab02
        nfsExportPath = "/srv/media";
        nfsMountOptions = [
          "nfsvers=4.2"
          "soft"
          "timeo=150"
          "retrans=3"
          # Performance tuning for media files
          "rsize=1048576"
          "wsize=1048576"
          # Caching settings
          "ac"
          "actimeo=5"
        ];
      };
    };

    # -------------------------------------------------------------------------
    # Streaming Services (Run Locally)
    # -------------------------------------------------------------------------
    # These benefit from Quick Sync or need low-latency access

    jellyfin = {
      enable = true;
      postProcessingMode = "cut"; # or "chapters" }
    };

    # -------------------------------------------------------------------------
    # Media Management (Run Locally)
    # -------------------------------------------------------------------------
    # These are metadata-heavy and CPU-bound, not I/O-bound.
    # They access media via NFS but don't do heavy writes.

    jellyseerr.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
    prowlarr.enable = true;
    bazarr.enable = true;
    flaresolverr.enable = true;
    recyclarr.enable = true;
    huntarr.enable = true;
    cleanuparr.enable = true;
    wizarr.enable = true;

    # -------------------------------------------------------------------------
    # Download Services (NOW ON HOMELAB02)
    # -------------------------------------------------------------------------
    qbittorrent = {
      enable = false; # Moved to homelab02
      vpn.enable = true;
    };

    cross-seed = {
      enable = false; # Moved to homelab02
      torznabIndexerIds = [ 8 ];
      matchMode = "partial";
      includeSingleEpisodes = true;
    };

    unpackerr.enable = false; # Moved to homelab02

    # -------------------------------------------------------------------------
    # Cloudflare Tunnel
    # -------------------------------------------------------------------------
    cloudflare-tunnel = {
      enable = true;
      domain = "gyarmathy.co";

      # Map reverse-proxy services to cloudflare-tunnel format
      # Only pass the fields that cloudflare-tunnel understands
      services = lib.mapAttrs (name: svc: {
        subdomain = svc.subdomain;
        port = svc.port;
        localOnly = svc.localOnly;
      }) config.cg.service.reverse-proxy.services;
    };

    # -------------------------------------------------------------------------
    # Commercial Detection (Comskip)
    # -------------------------------------------------------------------------
    comskip = {
      enable = true;

      settings = {
        # Output settings
        output_edl = 1;
        delete_logo_file = 1;

        # Detection tuning - 111 uses all detection methods
        # Bitmask: 1(uniformity) + 2(logo) + 4(scene) + 8(resolution) + 16(CC) + 32(aspect) + 64(silence)
        detect_method = 111;
        verbose = 10; # Logging verbosity (0-10, higher = more verbose)

        # Commercial break constraints (in seconds)
        max_commercialbreak = 600; # Max length of entire commercial break
        min_commercialbreak = 60; # Min length of entire commercial break
        max_commercial_size = 300; # Max length of single commercial
        min_commercial_size = 15; # Min length of single commercial

        # Show segment constraints
        min_show_segment_length = 100; # Minimum show content between breaks

        # Detection sensitivity
        non_uniformity = 500; # Allows variation in commercial lengths (higher = more lenient)
        max_avg_brightness = 60; # For black frame detection

        # Logo detection parameters
        logo_present_modifier = 1; # Weight of logo presence in detection
        logo_filter = 2; # Logo filter strength

        # Performance
        threads = 4; # Parallel processing threads
      };
    };
    comskip-chapters.enable = true; # Enable processing into chapters in Jellyfin
  };

  # ============================================================================
  # Boot Configuration
  # ============================================================================
  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
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
    nfs-utils # NFS client tools

    # Cloudflare Tunnel
    cloudflared
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
