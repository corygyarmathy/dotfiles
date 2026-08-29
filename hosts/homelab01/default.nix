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
  fleet,
  ...
}:
let
  inherit (fleet) domain;

  hostName = config.networking.hostName;

  # The fleet's always-on machines: what gets scraped, peered and backed up.
  # `peer` is the other one - this fleet has exactly two, and the day it has
  # three is the day the things below that assume one peer need revisiting.
  servers = lib.attrNames (lib.filterAttrs (_: host: host.kind == "server") fleet.hosts);
  peers = lib.remove hostName servers;
  peer = lib.head peers;

  # Fleet-wide duties this host does not own. `gateway` is its own name, but
  # reading it from ./fleet rather than assuming it keeps the two in step.
  gateway = fleet.roles.gateway;
  storage = fleet.hosts.${fleet.roles.storage};
in
{
  imports = [
    # Hardware configuration (generate with nixos-generate-config)
    ./hardware.nix

    # Quirks for this exact machine, from nixos-hardware
    inputs.hardware.nixosModules.common-cpu-intel
    inputs.hardware.nixosModules.common-pc
    inputs.hardware.nixosModules.common-pc-ssd

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
    flake = "github:corygyarmathy/dotfiles/deploy#${hostName}";
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

      # This host receives its peer's cross-server backups here
      incomingPath = "/srv/backups/${peer}";

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
        # Cross-server: back up to the peer's ZFS pool
        cross-server = {
          repository = "sftp:coryg@${fleet.hosts.${peer}.address}:/srv/backups/${hostName}";
          schedule = "02:30";
        };
        # Offsite: Google Drive via rclone
        gdrive = {
          repository = "rclone:gdrive:backups/homelab/${hostName}";
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
      baseUrl = "garden.${domain}";
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
    # What it serves is not written here. Each service module contributes its
    # own entry to `cg.publish` (modules/nixos/publish.nix) and Caddy is built
    # from that, so a port lives in exactly one place. The one decision left
    # to this host is which of them answer from outside the LAN, and that is
    # the `cg.publish` block further down.
    reverse-proxy = {
      enable = true;
      email = "cory@${domain}";
      cloudflareTokenFile = config.sops.templates."caddy-cloudflare-env".path;
    };

    monitoring = {
      enable = true;
      prometheus.enable = true;
      alertmanager = {
        enable = true;
        clusterPeers = peers;
        ntfy.enable = true;
        email = {
          to = "cory@${domain}";
          from = "alerts@${domain}";
          authUsername = "alerts@${domain}";
          # smarthost uses the default (smtp.protonmail.ch:587)
        };
      };

      grafana.enable = true;
      zfs.enable = false;
      cloudflaredTarget = "${gateway}:20241";

      # httpProbes is not set: it defaults to every service this host
      # publishes. The two hosts used to hand-maintain overlapping lists that
      # had drifted apart by six entries, with seven proxied hostnames probed
      # from nowhere.
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
      bindAddresses = [
        "127.0.0.1"
        fleet.hosts.${hostName}.address
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

      # Mount from the fleet's storage host
      storage = {
        type = "nfs";
        nfsServer = storage.address;
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
    # Ingress is every `cg.publish` entry with `localOnly = false`, read
    # directly by the module. The hand-written mapAttrs that used to sit here
    # was module-to-module wiring in a host file: the one place least able to
    # notice when the two sides stopped agreeing.
    cloudflare-tunnel.enable = true;

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
  # What this host puts on the internet
  # ============================================================================
  # Everything else about a publication - its hostname, its port, its
  # rate-limit profile - comes from the module that runs the service
  # (modules/nixos/publish.nix). Reachability does not: whether strangers can
  # reach a service is a decision about this fleet, not a property of the
  # software, so it is the one field a host writes.
  #
  # `localOnly` defaults to true, so this list is the complete answer to "what
  # is exposed", and forgetting to add something here fails closed. Anything
  # named below is also in the Cloudflare tunnel's ingress, which is what
  # actually carries the traffic.
  cg.publish = {
    jellyfin.localOnly = false;
    seerr.localOnly = false; # requests.
    wizarr.localOnly = false; # invite; the link is handed to new users.
    miniflux.localOnly = false; # rss.
    wallabag.localOnly = false; # read.
    digital-garden.localOnly = false; # garden; static and public by design.
    kavita.localOnly = false; # readers need it away from the LAN
    audiobookshelf.localOnly = false; # mobile apps stream from outside
    ntfy.localOnly = false; # push to phones on mobile data is the whole point

    # Grimmory is the one service this host proxies without running: it lives
    # on the storage host, where the library is on local disk rather than the
    # NFS mount (see the header of modules/services/media-stack/grimmory.nix),
    # and it is published from here because this host owns the tunnel.
    #
    # So the entry is written here rather than by the module - but the port is
    # still read from the module's own option, and the address from the fleet,
    # so neither is transcribed.
    grimmory = {
      port = config.cg.service.grimmory.port;
      upstream = storage.address;
      localOnly = false; # readers need external access
      rateLimitProfile = "media";
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
    # IP reserved by the DHCP server; the reservation itself is recorded in
    # fleet/default.nix, and mkHost sets hostName from the same place.
    useDHCP = lib.mkForce true;
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
