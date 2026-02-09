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
  ...
}:

let
  cfg = config.cg.service.media-stack;
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
          └── music/
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
        default = "/export/media";
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
    fileSystems.${cfg.dataPath} = lib.mkIf (cfg.storage.type == "nfs") {
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

    # Create directory structure with correct permissions
    # Config directory is always local; data directories only when storage is local
    systemd.tmpfiles.rules = [
      # Config directory (always local, even with NFS storage)
      "d ${cfg.configPath} 0775 root ${cfg.group} -"
    ]
    ++ lib.optionals (cfg.storage.type == "local" && !config.cg.service.nas-storage.enable) [
      # Data directories (only when using local storage AND nas-storage isn't managing them)
      # setgid (2xxx) for group inheritance
      "d ${cfg.dataPath} 2775 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataPath}/downloads 2775 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataPath}/downloads/complete 2775 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataPath}/downloads/incomplete 2775 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataPath}/movies 2775 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataPath}/tv 2775 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataPath}/music 2775 ${cfg.user} ${cfg.group} -"
    ];

    # Create the arr-network before any containers start
    systemd.services.podman-network-arr = {
      description = "Create podman network for media stack";
      after = [ "podman.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.podman}/bin/podman network create arr-network --ignore";
      };
    };
  };
}
