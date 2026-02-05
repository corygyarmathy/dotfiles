# NAS Storage Module - ZFS Pool + NFS Export
#
# This module configures homelab02 as a NAS server:
# - Assumes ZFS pool is already created and mounted at poolPath
# - Exports poolPath via NFS for homelab01 to mount
#
# IMPORTANT: This module does NOT manage the ZFS pool - that's handled by
# boot.zfs.extraPools in the host configuration.
# It only sets up directory structure and NFS export.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cg.service.nas-storage;
in
{
  options.cg.service.nas-storage = {
    enable = lib.mkEnableOption "NAS storage with ZFS and NFS";

    # ZFS pool mount point (managed by ZFS, not this module)
    poolPath = lib.mkOption {
      type = lib.types.path;
      default = "/srv/media";
      description = "Path where ZFS pool is mounted";
    };

    # NFS configuration
    nfs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NFS export of the media pool";
      };

      allowedNetwork = lib.mkOption {
        type = lib.types.str;
        default = "10.20.2.0/24";
        description = "Network CIDR allowed to mount NFS";
      };

      exportPath = lib.mkOption {
        type = lib.types.str;
        default = "/srv/media";
        description = "Path to export via NFS (usually same as poolPath)";
      };
    };

    # User/group for file ownership
    user = lib.mkOption {
      type = lib.types.str;
      default = "coryg";
      description = "User for file ownership";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group for file ownership";
    };
  };

  config = lib.mkIf cfg.enable {
    # ========================================================================
    # Directory Structure Setup
    # ========================================================================
    systemd.services.nas-directory-setup = {
      description = "Create NAS directory structure on ZFS pool";
      after = [ "zfs-mount.target" ];
      wants = [ "zfs-mount.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        ConditionPathIsMountPoint = cfg.poolPath;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script =
        let
          uid = toString config.users.users.${cfg.user}.uid;
          gid = toString config.users.groups.${cfg.group}.gid;
          dirs = [
            "downloads"
            "downloads/complete"
            "downloads/incomplete"
            "downloads/cross-seed"
            "movies"
            "tv"
            "music"
          ];
        in
        ''
          for dir in ${lib.concatStringsSep " " dirs}; do
            mkdir -p "${cfg.poolPath}/$dir"
            chown ${uid}:${gid} "${cfg.poolPath}/$dir"
            chmod 2775 "${cfg.poolPath}/$dir"
          done
          echo "Created directory structure on ${cfg.poolPath}"
        '';
    };

    # ========================================================================
    # NFS Server
    # ========================================================================
    services.nfs.server = lib.mkIf cfg.nfs.enable {
      enable = true;
      # fsid=1 is required for FUSE filesystems like MergerFS
      # Using non-zero allows clients to mount with the full path
      exports = ''
        ${cfg.nfs.exportPath} ${cfg.nfs.allowedNetwork}(rw,sync,no_subtree_check,no_root_squash,fsid=1)
      '';
      extraNfsdConfig = ''
        vers3=n
        vers4=y
        vers4.1=y
        vers4.2=y
      '';
    };

    # ========================================================================
    # Firewall
    # ========================================================================
    networking.firewall = lib.mkIf cfg.nfs.enable {
      allowedTCPPorts = [
        2049
        111
      ];
      allowedUDPPorts = [
        2049
        111
      ];
    };

    # ========================================================================
    # Media Group
    # ========================================================================
    users.groups.${cfg.group} = {
      gid = lib.mkDefault 1011;
    };
  };
}
