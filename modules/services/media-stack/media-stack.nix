# Media Stack - Shared Infrastructure
# This module provides common configuration for all media-related services:
# - Podman network creation
# - Directory structure with correct permissions
# - Shared path definitions
# - NFS mount configuration (for future NAS integration)
#
# All media services should reference paths from this module rather than
# defining their own, ensuring consistency and simplifying NAS migration.
#
# MIGRATION NOTES (homelab02 NAS):
# When the NAS arrives:
# 1. Set up NFS export on homelab02 at storage.nfsExportPath
# 2. Change storage.type = "nfs" and set storage.nfsServer
# 3. Rebuild - the NFS mount will be created automatically
# 4. Services will continue working with the same paths
{
  config,
  pkgs,
  lib,
  utils,
  ...
}:

let
  cfg = config.cg.service.media-stack;

  nfs = cfg.storage.type == "nfs";
  dataMountUnit = "${utils.escapeSystemdPath cfg.dataPath}.mount";

  # Whether a container volume ("host:container[:opts]") binds the media tree
  # or anything under it.
  bindsData =
    volume:
    let
      host = builtins.head (lib.splitString ":" volume);
    in
    host == cfg.dataPath || lib.hasPrefix "${cfg.dataPath}/" host;

  # Refuses to let a container start until the media tree is the NFS mount
  # rather than the bare directory underneath it. podman resolves a bind at
  # start and keeps it: a container that starts while the automount is down
  # binds the empty mountpoint and stays on it after the mount comes back,
  # which is what homelab01 did after the 2026-09-28 power cut - sonarr,
  # radarr and bazarr running against an empty /srv/media until restarted.
  #
  # Waits about a minute before failing so each failed start is far slower
  # than the unit's start limit (5 in 10s): the unit's Restart= then retries
  # indefinitely while the server is away, and a container that crash-loops
  # on its own still hits the limit and fails loudly as before.
  waitForData = pkgs.writeShellScript "media-data-mounted" ''
    set -u
    data=${lib.escapeShellArg cfg.dataPath}
    for _ in $(${pkgs.coreutils}/bin/seq 12); do
      # Touching the path is what fires the automount. Bounded because a hard
      # mount against a server that stopped answering blocks in stat().
      ${pkgs.coreutils}/bin/timeout 10 ${pkgs.coreutils}/bin/stat -f -- "$data/." >/dev/null 2>&1 || true
      if ${pkgs.util-linux}/bin/findmnt --noheadings --types nfs,nfs4 --mountpoint "$data" >/dev/null; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 5
    done
    echo "media-data-mounted: $data is not NFS-mounted; not starting against the bare mountpoint" >&2
    exit 1
  '';
in
{
  options.cg.service.media-stack = {
    enable = lib.mkEnableOption "media stack shared infrastructure";

    dataPath = lib.mkOption {
      type = lib.types.path;
      default = "/srv/media";
      description = ''
        Root path for all media data (downloads, tv, movies, music).
        All child services mount this as /data for hardlink support.

        Structure:
          /srv/media/
          ├── downloads/
          │   ├── complete/
          │   └── incomplete/
          ├── movies/
          ├── tv/
          ├── music/
          ├── books/
          ├── manga/
          ├── lightnovels/
          ├── comics/
          ├── audiobooks/
          └── bookdrop/
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.path;
      default = "/srv/arr";
      description = "Root path for service configuration directories";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "coryg";
      description = "User for container PUID and file ownership";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group for container PGID and file ownership";
    };

    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "downloads"
        "downloads/complete"
        "downloads/incomplete"
        "downloads/cross-seed"
        "movies"
        "tv"
        "music"
        "livetv"
        "books"
        "comics"
        "manga"
        "doujin"
        "lightnovels"
        "audiobooks"
        "podcasts"
        "bookdrop"
        "suwayomi"
        "whisparr"
      ];
      description = ''
        The media tree, relative to dataPath. This is the single definition of
        it: nas-storage creates these on the pool it owns, and the tmpfiles
        rules below create them on a host that stores media locally without
        nas-storage. Both used to carry their own copy and had already drifted
        apart, which is how bookdrop came to exist on one path and not the
        other. Add a directory here and both agree.
      '';
    };

    storage = {
      type = lib.mkOption {
        type = lib.types.enum [
          "local"
          "nfs"
        ];
        default = "local";
        description = ''
          Storage backend type.
          - local: Data stored directly on this host
          - nfs: Data mounted from NFS server (for NAS setup)
        '';
      };

      nfsServer = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "homelab02.local";
        description = "NFS server hostname or IP (when storage.type = nfs)";
      };

      nfsExportPath = lib.mkOption {
        type = lib.types.str;
        default = "/srv/media";
        description = "Export path on the NFS server";
      };

      nfsMountOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "nfsvers=4.2"
          "hard"
          "timeo=150"
          "retrans=3"
          "rsize=1048576"
          "wsize=1048576"
        ];
        description = "NFS mount options";
      };

      nfsFileSystem = lib.mkOption {
        type = lib.types.attrs;
        internal = true;
        readOnly = true;
        default = {
          device = "${cfg.storage.nfsServer}:${cfg.storage.nfsExportPath}";
          fsType = "nfs";
          options = cfg.storage.nfsMountOptions ++ [
            "x-systemd.automount"
            "x-systemd.idle-timeout=600"
            "x-systemd.requires=network-online.target"
            "x-systemd.after=network-online.target"
            "x-systemd.mount-timeout=30"
            "_netdev"
          ];
        };
        description = ''
          The fileSystems entry for dataPath when storage.type = nfs. An option
          only so a VM test can mount exactly this: the test VM replaces
          `fileSystems` with `virtualisation.fileSystems` wholesale.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Assertions for NFS configuration
    assertions = [
      {
        assertion = cfg.storage.type != "nfs" || cfg.storage.nfsServer != "";
        message = "media-stack: storage.nfsServer must be set when storage.type = nfs";
      }
    ];

    # Ensure podman is available
    virtualisation.oci-containers.backend = "podman";

    # Create the media group with explicit GID for container compatibility
    users.groups.${cfg.group} = {
      gid = lib.mkDefault 1011;
    };

    # NFS mount configuration (when using NAS)
    fileSystems.${cfg.dataPath} = lib.mkIf nfs cfg.storage.nfsFileSystem;

    # Never let the mount unit hit its start limit. Every access through the
    # automount is a start attempt, and when the network is not up yet they
    # fail instantly - a handful of services touching the path at boot spent
    # the default 5-in-10s in one second on 2026-09-28. The automount then
    # fails for good (mount-start-limit-hit), nothing retries it, and every
    # later access sees the bare local directory. Unlimited, the automount
    # stays armed and the first access after the server is back mounts it.
    systemd.units.${dataMountUnit} = lib.mkIf nfs {
      overrideStrategy = "asDropin";
      text = ''
        [Unit]
        StartLimitIntervalSec=0
      '';
    };

    # Containers that bind the media tree depend on the NFS mount. Wants
    # rather than Requires: a Requires on a mount that fails at boot leaves the
    # container dead with nothing to restart it, so the dependency is held by
    # the ExecStartPre guard instead, whose failure Restart= does retry. Only
    # for NFS storage - a local tree has no bare mountpoint to fall onto.
    systemd.services = lib.mkMerge [
      (lib.mkIf nfs (
        lib.mapAttrs'
          (
            _: container:
            lib.nameValuePair container.serviceName {
              wants = [ dataMountUnit ];
              after = [ dataMountUnit ];
              serviceConfig.ExecStartPre = lib.mkBefore [ "${waitForData}" ];
            }
          )
          (
            lib.filterAttrs (_: c: lib.any bindsData c.volumes) config.virtualisation.oci-containers.containers
          )
      ))

      # Create the arr-network before any containers start
      {
        podman-network-arr = {
          description = "Create podman network for media stack";
          after = [ "podman.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.podman}/bin/podman network create arr-network --ignore";
          };
        };
      }
    ];

    # Create directory structure with correct permissions
    # Config directory is always local; data directories only when storage is local
    systemd.tmpfiles.rules = [
      # Config directory (always local, even with NFS storage)
      "d ${cfg.configPath} 0775 root ${cfg.group} -"
    ]
    ++ lib.optionals (cfg.storage.type == "local" && !config.cg.service.nas-storage.enable) (
      # Data directories, only when this host stores media locally AND
      # nas-storage is not already managing them. Neither homelab currently
      # meets that: homelab01 is an NFS client and homelab02 runs nas-storage,
      # so on the present fleet this branch is unreachable. It is kept for a
      # single-box deployment -- but that is exactly why it must not carry its
      # own copy of the directory list, since nothing here would notice it
      # going stale.
      # setgid (2xxx) for group inheritance.
      [ "d ${cfg.dataPath} 2775 ${cfg.user} ${cfg.group} -" ]
      ++ map (dir: "d ${cfg.dataPath}/${dir} 2775 ${cfg.user} ${cfg.group} -") cfg.directories
    );
  };
}
