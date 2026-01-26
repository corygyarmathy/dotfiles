# NAS Storage Module - MergerFS Pool + NFS Export
#
# This module configures homelab02 as a NAS server:
# - Assumes data disks are already mounted by disko at /mnt/data/disk{1,2,...}
# - Pools them via MergerFS into /srv/media
# - Exports /srv/media via NFS for homelab01 to mount
#
# IMPORTANT: This module does NOT mount the data disks - that's handled by disko.
# It only sets up MergerFS pooling and NFS export.
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
    enable = lib.mkEnableOption "NAS storage with MergerFS and NFS";

    # Paths where disko mounts the data disks
    diskMountPoints = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [
        "/mnt/data/disk1"
        "/mnt/data/disk2"
      ];
      description = "Mount points of data disks (managed by disko)";
    };

    # MergerFS pool mount point
    poolPath = lib.mkOption {
      type = lib.types.path;
      default = "/srv/media";
      description = "Path where MergerFS pool is mounted";
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
    # Required packages
    # ========================================================================
    environment.systemPackages = with pkgs; [
      mergerfs
      mergerfs-tools
    ];

    # ========================================================================
    # MergerFS Pool Mount
    # ========================================================================
    # Options from: https://trapexit.github.io/mergerfs/latest/config/options/
    fileSystems.${cfg.poolPath} = {
      device = lib.concatStringsSep ":" cfg.diskMountPoints;
      fsType = "fuse.mergerfs";
      options = [
        # Create policy: existing path, most free space (enables hardlinks)
        # pfrd = path first, rand (default). epmfs = existing path, most free space
        "category.create=epmfs"
        
        # Search policy: first found (fast)
        "category.search=ff"
        
        # Minimum free space before considering a branch full
        "minfreespace=20G"
        
        # Move file to another branch if write fails with ENOSPC
        "moveonenospc=true"
        
        # Cache settings
        "cache.files=off"
        
        # Allow non-root users to access
        "allow_other"
        
        # Don't fail boot if pool can't mount
        "nofail"
        
        # Systemd ordering
        "x-systemd.after=mnt-data-disk1.mount"
        "x-systemd.after=mnt-data-disk2.mount"
      ];
    };

    # ========================================================================
    # Directory Structure Setup
    # ========================================================================
    systemd.services.nas-directory-setup = {
      description = "Create NAS directory structure on data disks";
      after = [ "srv-media.mount" ];
      wants = [ "srv-media.mount" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        ConditionPathIsMountPoint = cfg.poolPath;
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = let
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
      in ''
        # Create directory structure on each underlying disk
        for disk in ${lib.concatStringsSep " " cfg.diskMountPoints}; do
          if mountpoint -q "$disk"; then
            for dir in ${lib.concatStringsSep " " dirs}; do
              mkdir -p "$disk/$dir"
              chown ${uid}:${gid} "$disk/$dir"
              chmod 2775 "$disk/$dir"
            done
            echo "Created directories on $disk"
          else
            echo "Skipping $disk - not mounted"
          fi
        done
      '';
    };

    # ========================================================================
    # NFS Server
    # ========================================================================
    services.nfs.server = lib.mkIf cfg.nfs.enable {
      enable = true;
      exports = ''
        ${cfg.nfs.exportPath} ${cfg.nfs.allowedNetwork}(rw,sync,no_subtree_check,no_root_squash,crossmnt)
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
      allowedTCPPorts = [ 2049 111 ];
      allowedUDPPorts = [ 2049 111 ];
    };

    # ========================================================================
    # Media Group
    # ========================================================================
    users.groups.${cfg.group} = {
      gid = lib.mkDefault 1011;
    };
  };
}
