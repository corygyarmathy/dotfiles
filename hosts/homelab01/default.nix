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

    # What it costs to be a machine in this fleet, and to be a server in it.
    # Decisions rather than options - see profiles/common.nix.
    ../../profiles/common.nix
    ../../profiles/server.nix

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
    # The account deploy-rs connects as when the laptop pushes a change (items 6
    # and 10 of the hardening plan). Only the laptop needs to reach it, so only
    # the laptop's dedicated deploy key is authorized - revoking deploy access
    # must not require rotating the human admin key.
    deploy-rs = {
      enable = true;
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEptc3aZw3UltEoKboluqNvpFsYmirJxaoZg3AM3eB6f deploy@xps15"
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
      # An empty URL renders as muted text rather than as a link, so these two
      # hold their place in the header's link list until they have somewhere
      # to point - rather than shipping two 404s or two stub pages to stand in
      # for them. Fill in a URL and it becomes an ordinary link.
      footerLinks = {
        GitHub = "https://github.com/corygyarmathy";
        Projects = "";
        Resume = "";
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

    # The peer probes this host through its own `alive` endpoint
    # (host-alive.nix), which is decoupled from any service. This host's
    # tunnel routes both its own beacon and - because this host owns the
    # tunnel - the peer's, which the `cg.publish` block below names.
    host-alive.enable = true;

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

      # Reachability from outside this host (item 9 of
      # docs/plans/deployment-hardening.md). This host's own probes
      # (`httpProbes` above) run locally, so a change that cuts a host off from
      # the network looks fine from the inside. These probe the peer instead,
      # at the peer's own dedicated host-alive beacon (see
      # modules/services/host-alive.nix) - a dependency-free 200-responder that
      # is never moved or disabled with a service, so "homelab02 stops
      # answering" here really means homelab02 is out of reach, not that one of
      # its apps died. If it stops answering, this host - still up - pages.
      remoteProbes = [
        {
          name = "homelab02";
          url = "https://alive-homelab02.${domain}";
        }
      ];

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

    # This host's own host-alive beacon (modules/services/host-alive.nix).
    # It is declared by the module with `localOnly` left to the host; it must
    # be published publicly so the peer has a hostname to probe - whether that
    # probe crosses the LAN or the tunnel depends on the resolver, not on this
    # flag - hence `false` here.
    alive.localOnly = false;

    # The peer's host-alive beacon, published from here because this host owns
    # the tunnel. Written here rather than by the module for the same reason
    # grimmory is, but the port still comes from the peer's module - through
    # this host's own `host-alive.port`, which the module pins equal across
    # both servers (checks/publish.nix) - and the address from the fleet, so
    # neither is transcribed.
    alive-homelab02 = {
      port = config.cg.service.host-alive.port;
      upstream = storage.address;
      probe = false;
      localOnly = false; # the peer's beacon is published publicly, like any tunnel-routed service
    };

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
  # Hardware
  # ============================================================================
  # The NIC to arm for Wake-on-LAN. profiles/server.nix decides that this
  # machine should wake; only the machine knows what its interface is called.
  cg.wake-on-lan.interfaces = [ "eno1" ];

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
  # The editor variables are in profiles/common.nix; this one is about the GPU
  # above it.
  environment.sessionVariables = {
    # Help applications find VA-API drivers
    LIBVA_DRIVER_NAME = "iHD";
  };

  # ============================================================================
  # System Packages
  # ============================================================================
  # The server package set is in profiles/server.nix. Only this host owns the
  # tunnel, so only this host needs the client.
  environment.systemPackages = [ pkgs.cloudflared ];

  # ============================================================================
  # System Version
  # ============================================================================
  system.stateVersion = "24.11";
}
