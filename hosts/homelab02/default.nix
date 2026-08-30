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

  # The host that owns the tunnel, the primary DNS instance and the wildcard.
  gateway = fleet.roles.gateway;
in
{
  imports = [
    # Declarative disk partitioning (manages OS + data disks)
    ./disko.nix

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
  # Follows `deploy`, the same ref as every other host. This host used to trail
  # by 24h on a separate ref so the storage node soaked each revision on
  # homelab01 first; ADR 0002 retires that and moves protection to activation
  # time instead - boot counting for a generation that will not come up,
  # health-gated activation for one that comes up broken.
  #
  # The 15 minute offset from homelab01 is not a soak and is not load-bearing.
  # It is kept because homelab01 mounts NFS from here, and two servers
  # rebooting into a new kernel simultaneously is worth avoiding on its own.
  system.autoUpgrade = {
    enable = true;
    flake = "github:corygyarmathy/dotfiles/deploy#${hostName}";
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
    # The account deploy-rs connects as when the laptop pushes a change (item 6
    # of the hardening plan). Only the laptop needs to reach it, so only the
    # laptop's key is authorized.
    deploy-rs = {
      enable = true;
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGN2/Vvyb3abKAxdCYt9pxGgOho5uqtNzhpXVxGVw1gq coryg@xps15"
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
    user-security.enable = true;

    # This host reboots unattended inside the 04:00-05:00 window and holds the
    # pool, so an initrd or kernel that will not come up is the failure that
    # costs the most here - and the one nobody can fix without standing in
    # front of it. Enabled after homelab01 proved the full round trip: counter
    # written, boot counted, boot-complete.target reached, entry blessed.
    boot-counting.enable = true;

    # Reporting only, and deliberately not armed here even when homelab01's is.
    # This host holds the pool and the NFS export; it is the last place to give
    # an automatic reverter the benefit of the doubt.
    upgrade-verify = {
      enable = true;
      criticalUnits = [
        "zfs-import-tank.service" # nothing below matters without the pool
        "nfs-server.service" # homelab01 mounts this
        "caddy.service" # everything published is behind it
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
        # All arr service configs
        "/srv/arr"

        # Services with state outside /srv/arr
        "/var/lib/private/AdGuardHome"

        # Suwayomi's database, installed extensions and library metadata.
        # The downloaded chapters live in the media pool and are not this.
        "/var/lib/suwayomi-server"
      ];

      extraExclude = [
        # cross-seed logs are ~1GB
        "/srv/arr/cross-seed/logs/**"

        # Grimmory's live MariaDB datadir. Restic snapshots of a running
        # database are torn and may not restore; grimmory-db-backup.timer
        # writes a consistent dump to /srv/arr/grimmory/db-dump at 02:00,
        # half an hour before the restic window, and that is what gets backed up.
        "/srv/arr/grimmory/mariadb/databases/**"
      ];

      repositories = {
        # Cross-server: back up to the peer
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
    filebrowser.enable = true;

    monitoring = {
      enable = true;
      prometheus.enable = true;
      alertmanager = {
        enable = true;
        clusterPeers = peers;
        # Push lane. The ntfy server itself lives on the gateway; this host runs
        # only the local alertmanager-ntfy bridge, so either host can still
        # deliver on its own if the other is down.
        #
        # The bridge's port is the module's default, which is off 8000 for
        # this host's sake: gluetun's control server is published there
        # (qbittorrent.nix), and with the old shared default the bridge lost
        # the bind race on every start - the 2026-08-26 upgrade that
        # introduced it was marked failed by its own activation.
        ntfy.enable = true;
        email = {
          to = "cory@${domain}";
          from = "alerts@${domain}";
          authUsername = "alerts@${domain}";
          # smarthost uses the default (smtp.protonmail.ch:587)
        };
      };
      grafana.enable = false;
      zfs.enable = true;
      cloudflaredTarget = "${gateway}:20241";

      vpn.enable = true;

      # httpProbes is not set: it defaults to every service this host
      # publishes. This host and its peer used to hand-maintain overlapping
      # lists that had drifted apart by six entries.
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
        # Only the peer mounts this export; scope it to that host rather than
        # the whole subnet so no other device can touch the media as root.
        allowedNetwork = "${fleet.hosts.${peer}.address}/32";
        exportPath = "/srv/media";
      };
      user = "coryg";
      group = "media";
    };

    # -------------------------------------------------------------------------
    # Reverse Proxy (Caddy)
    # -------------------------------------------------------------------------
    # What it serves is not written here. Each service module contributes its
    # own entry to `cg.publish` (modules/nixos/publish.nix) and Caddy is built
    # from that, so a port lives in exactly one place.
    #
    # Nothing this host publishes is internet-facing, so it has no `cg.publish`
    # block of its own: `localOnly` defaults to true. The tunnel lives on the
    # gateway, and grimmory - the one service here that answers from outside -
    # is published from there.
    reverse-proxy = {
      enable = true;
      email = "cory@${domain}";
      cloudflareTokenFile = config.sops.templates."caddy-cloudflare-env".path;

    };

    # -------------------------------------------------------------------------
    # DNS (AdGuard Home)
    # -------------------------------------------------------------------------
    adguard-home = {
      enable = true;
      role = "secondary";
      bindAddresses = [
        "127.0.0.1"
        fleet.hosts.${hostName}.address
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
    # Reading Stack
    # -------------------------------------------------------------------------
    # Grimmory lives here rather than with the other reading services on
    # homelab01, because it needs the library on local disk: over NFS it loses
    # UI file operations and its BookDrop watcher stops firing. Caddy and the
    # Cloudflare tunnel on homelab01 proxy across to it.
    grimmory = {
      enable = true;
      diskType = "LOCAL"; # /srv/media is the local ZFS pool on this host
    };

    # Search-and-grab for books and audiobooks, feeding Grimmory's BookDrop.
    # It lives here rather than on homelab01 with the other reading services
    # because BookDrop watches with inotify, which does not fire for writes
    # arriving over NFS from another machine. It shares Gluetun's network
    # namespace, so its UI is published by the gluetun container, not this one.
    #
    # This replaced LazyLibrarian, which is gone. Shelfmark covers the search
    # half; author monitoring was the other half and was given up knowingly,
    # since it was not being used.
    #
    # Needs a DNS rewrite in adguard-home.nix to reach this host -- the
    # wildcard there points everything else at homelab01.
    shelfmark.enable = true;

    # Manga sources, downloading CBZ into /srv/media/suwayomi. Kept out of the
    # curated manga tree because it writes its own layout; add it as its own
    # library in Grimmory. Here rather than homelab01 because manga downloads
    # are many small files and this host owns the pool.
    #
    # Also needs a DNS rewrite in adguard-home.nix.
    suwayomi.enable = true;

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
  # The server package set is in profiles/server.nix. Only this host has disks
  # to partition by hand.
  environment.systemPackages = [ pkgs.parted ];

  # ============================================================================
  # System Version
  # ============================================================================
  system.stateVersion = "24.11";
}
