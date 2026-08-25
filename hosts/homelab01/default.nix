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
  # Follows `deploy`, which CI fast-forwards only after every host builds
  # (ADR 0001). Both servers follow it and take each promoted revision the same
  # night; the canary role this host used to play was retired with the staged
  # rollout (ADR 0002).
  system.autoUpgrade = {
    enable = true;
    flake = "github:corygyarmathy/dotfiles/deploy#homelab01";
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
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGN2/Vvyb3abKAxdCYt9pxGgOho5uqtNzhpXVxGVw1gq coryg@xps15" # Allow access from your XPS 15
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPWfMUll4YosHtfkgs/68GAaszVU/VM94IrQzz4xZuPN restic-backup"
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
    user-security.enable = true;

    # This host reboots unattended after an upgrade, so a kernel or initrd that
    # will not come up would otherwise need someone in front of it. Enabled
    # here first, ahead of homelab02, because homelab02 holds the pool and its
    # ESP should not be the one this is proven on.
    boot-counting.enable = true;

    # Health-gate what boot counting cannot see: a generation that boots and
    # then fails to bring its services up. Reporting only for now - rollback
    # stays off until there is evidence about how often it would fire on a
    # host that is actually fine.
    upgrade-verify = {
      enable = true;
      criticalUnits = [
        "caddy.service" # everything published is behind it
        "jellyfin.service" # the reason this host exists
        # The media tree from homelab02 is an automount, so `srv-media.mount`
        # is legitimately inactive most of the time. The automount unit is the
        # one that is always meant to be up.
        "srv-media.automount"
      ];
    };
  };

  # ============================================================================
  # Service Toggles
  # ============================================================================
  cg.service = {
    backup = {
      enable = true;

      # homelab01 receives homelab02's cross-server backups here
      incomingPath = "/srv/backups/homelab02";

      paths = [
        # All arr service configs — backs up the whole directory so
        # new services are captured automatically
        "/srv/arr"

        # Services with state outside /srv/arr
        "/var/lib/jellyfin"
        "/var/lib/grafana"
        "/var/lib/private/AdGuardHome"
        "/var/lib/autobrr"
        "/var/lib/postgresql"
        "/var/lib/kavita"
        "/var/lib/recyclarr"

        # Digital garden publication dates. The vault, staging and built site
        # all regenerate from Obsidian Sync / the filter, but dates.json records
        # the first day each note was published and exists nowhere else. Back up
        # only this file: the deploy-key and sync state must not leave the host.
        "/var/lib/digital-garden/dates.json"
      ];

      extraExclude = [
        # Jellyfin transcodes (large, regenerable)
        "**/transcodes/**"

        # Flaresolverr has no persistent state worth backing up
        "/srv/arr/flaresolverr/**"

        # Recyclarr guide/template repo clones (~75MB), regenerated on run
        "/var/lib/recyclarr/resources/**"

        # Jellyfin - regenerable from library scan
        "/var/lib/jellyfin/metadata/**"
        "/var/lib/jellyfin/data/trickplay/**"
        "/var/lib/jellyfin/data/attachments/**"
        "/var/lib/jellyfin/data/subtitles/**"

        # Vikunja
        "/var/lib/vikunja"
      ];

      repositories = {
        # Cross-server: back up to homelab02's ZFS pool
        cross-server = {
          repository = "sftp:coryg@10.20.2.130:/srv/backups/homelab01";
          schedule = "02:30";
        };
        # Offsite: Google Drive via rclone
        gdrive = {
          repository = "rclone:gdrive:backups/homelab/homelab01";
          schedule = "03:00";
        };
      };
    };
    immich.enable = false;
    home-assistant.enable = false;
    miniflux.enable = true;
    wallabag.enable = true;

    # -------------------------------------------------------------------------
    # Digital Garden (published subset of the Obsidian vault)
    # -------------------------------------------------------------------------
    # Only notes carrying `publish: true` are ever copied out of the vault;
    # see modules/services/digital-garden/publish-filter.py.
    digital-garden = {
      enable = true;
      port = 8086;
      baseUrl = "garden.gyarmathy.co";
      siteTitle = "Cory Gyarmathy";
      footerLinks = {
        GitHub = "https://github.com/corygyarmathy";
      };
      source = "obsidian-sync";

      # The layout is one column with a masthead, and the stylesheet the
      # templates are written against is the module's default. There is no
      # theme to switch off: what used to be a dozen disabled plugins and a
      # page of CSS undoing the rest is now just the four templates the site
      # actually uses.
    };

    vikunja.enable = false; # Todo app

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
        autobrr = {
          subdomain = "autobrr";
          port = 7474;
          localOnly = true;
        };

        # Management
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

        # Monitoring internals. LAN-only like the other admin UIs - remote
        # access stays ssh-tunnelled. The Alertmanager UI is where silences
        # live and Prometheus' graph view backs every alert expression, so
        # both are one click from Grafana instead of an ssh port-forward.
        prometheus-ui = {
          subdomain = "prometheus";
          port = 9090;
          localOnly = true;
        };
        alertmanager-ui = {
          subdomain = "alertmanager";
          port = 9093;
          localOnly = true;
        };

        # RSS
        rss = {
          subdomain = "rss";
          port = 8082;
          localOnly = false;
        };
        read = {
          subdomain = "read";
          port = 8083;
          localOnly = false;
        };

        # Digital garden - static, public, no backend to protect
        garden = {
          subdomain = "garden";
          port = 8086;
          localOnly = false;
        };

        # Maintainerr - media library maintenance
        maintainerr = {
          subdomain = "maintainerr";
          port = 6246;
          localOnly = true;
          rateLimitProfile = "none"; # Scans entire Jellyfin library
        };

        # Reading
        kavita = {
          subdomain = "kavita";
          port = 5000;
          localOnly = false; # readers need external access
          rateLimitProfile = "media";
        };
        audiobookshelf = {
          subdomain = "audiobookshelf";
          port = 13378;
          localOnly = false; # listeners need external access for mobile apps
          rateLimitProfile = "media";
        };
        # Runs on homelab02, where the library is on local disk rather than the
        # NFS mount -- see the header of modules/services/media-stack/grimmory.nix.
        # Proxied from here because homelab01 owns the Cloudflare tunnel.
        grimmory = {
          subdomain = "grimmory";
          port = 6060;
          upstream = "10.20.2.130"; # homelab02
          localOnly = false; # readers need external access
          rateLimitProfile = "media";
        };
      };
    };

    monitoring = {
      enable = true;
      prometheus.enable = true;
      alertmanager = {
        enable = true;
        clusterPeers = [ "homelab02" ];
        ntfy.enable = true;
        email = {
          to = "cory@gyarmathy.co";
          from = "alerts@gyarmathy.co";
          authUsername = "alerts@gyarmathy.co";
          # smarthost uses the default (smtp.protonmail.ch:587)
        };
      };

      grafana.enable = true;
      zfs.enable = false;
      scrapeTargets = [
        "homelab01:9100"
        "homelab02:9100"
      ];
      smartctlTargets = [
        "homelab01:9633"
        "homelab02:9633"
      ];
      cloudflaredTarget = "homelab01:20241";

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
          # /health rather than the bare root the other entries use: this is
          # the readiness endpoint cleanuparr's podman healthcheck used to hit,
          # so probing it keeps exactly the signal that healthcheck gave.
          name = "cleanuparr";
          url = "https://cleanuparr.gyarmathy.co/health";
        }
        {
          name = "maintainerr";
          url = "https://maintainerr.gyarmathy.co";
        }
        {
          name = "kavita";
          url = "https://kavita.gyarmathy.co";
        }
        {
          name = "audiobookshelf";
          url = "https://audiobookshelf.gyarmathy.co";
        }
        {
          name = "garden";
          url = "https://garden.gyarmathy.co";
        }
      ];
    };

    # -------------------------------------------------------------------------
    # Push notifications (ntfy)
    # -------------------------------------------------------------------------
    # Carries the alerting stack's page channel; the Alertmanager routing and
    # bridge live in modules/services/monitoring/monitoring.nix. First-deploy
    # bootstrap steps are documented in modules/services/ntfy.nix.
    ntfy.enable = true;

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
          "hard" # prevents silent data loss on NFS timeouts
          "intr" # allow interrupting hung NFS operations with signals
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
    };

    # -------------------------------------------------------------------------
    # Media Management (Run Locally)
    # -------------------------------------------------------------------------
    # These are metadata-heavy and CPU-bound, not I/O-bound.
    # They access media via NFS but don't do heavy writes.

    seerr.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
    prowlarr.enable = true;
    bazarr.enable = true;
    flaresolverr.enable = true;
    recyclarr.enable = true;
    huntarr.enable = false;
    cleanuparr.enable = true;
    wizarr.enable = true;
    autobrr.enable = true;
    maintainerr.enable = true;

    # -------------------------------------------------------------------------
    # Reading Stack (Ebooks, Comics, Manga)
    # -------------------------------------------------------------------------
    # Reading and acquisition now live on homelab02, where the media pool is
    # local: Grimmory serves all four library types, Shelfmark acquires books,
    # Suwayomi pulls manga. Kavita stays here, still the better comic and manga
    # reader, and still reading the same directories over NFS.
    kavita.enable = true;
    # LazyLibrarian and Mylar3 were removed, replaced by Shelfmark and Suwayomi
    # respectively -- though Suwayomi does manga, not Western comics, so comics
    # are a manual search now. Their state is still on disk at
    # /srv/arr/lazylibrarian and /srv/arr/mylar3 and in the backups; nothing
    # here deletes it. Remove those directories by hand once you are sure.

    # Audiobooks
    audiobookshelf.enable = true;

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
        upstream = svc.upstream;
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

  # Home-manager configuration for this user
  home-manager.users.coryg = import ./home.nix;

  # ============================================================================
  # System Version
  # ============================================================================
  system.stateVersion = "24.11";
}
