# NAS Storage Module - MergerFS Pool + NFS Export
#
# This module configures homelab02 as a NAS server:
# - Pools individual data disks via MergerFS into /srv/media
# - Exports /srv/media via NFS for homelab01 to mount
# - Creates proper directory structure for media stack
#
# The MergerFS pool appears as a single 8TB volume while maintaining
# the ability to hardlink files (files on the same underlying disk).
#
# MERGERFS POLICIES:
# - create: epmfs (existing path, most free space)
#   When qBittorrent downloads to /srv/media/downloads/, MergerFS places
#   the file on whichever disk has the most free space.
#   When Sonarr moves the file to /srv/media/tv/, MergerFS sees the
#   source file exists on disk1, so it creates the destination on disk1
#   too - enabling a hardlink instead of a copy.
#
# - search: ff (first found) - fast lookups
# - rename: all (for cross-device move support within pool)
#
# NFS EXPORT:
# - Exports /srv/media to the local network
# - Uses NFSv4.2 for better performance
# - Only allows connections from 10.20.2.0/24
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

    # Underlying disk mount points (set by disko)
    diskPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [
        "/mnt/data/disk1"
        "/mnt/data/disk2"
      ];
      description = "Paths to individual data disk mounts";
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
    # MergerFS Pool
    # ========================================================================
    # Pools all data disks into a single unified view

    environment.systemPackages = [ pkgs.mergerfs ];

    # Create the pool mount point
    systemd.tmpfiles.rules = [
      "d ${cfg.poolPath} 2775 ${cfg.user} ${cfg.group} -"
    ];

    # MergerFS mount
    fileSystems.${cfg.poolPath} = {
      # Pool all disk paths together
      device = lib.concatStringsSep ":" cfg.diskPaths;
      fsType = "fuse.mergerfs";
      options = [
        # ---- Policies ----
        # create: epmfs = existing path, most free space
        # This is KEY for hardlinks: when moving a file, MergerFS sees
        # the source path exists on disk1, so it creates dest on disk1
        "category.create=epmfs"
        # search: first found (fast)
        "func.search=ff"
        # rename: all (allows cross-branch moves within pool)
        "func.rename=all"

        # ---- Performance ----
        # Cache settings for better performance
        "cache.files=partial"
        "cache.entry=3"
        "cache.negative_entry=1"
        "cache.attr=3"
        # Async reads for better throughput
        "async_read=true"
        # Use ino (inode) from underlying filesystem
        "inodecalc=path-hash"

        # ---- Behavior ----
        # Don't fail if a branch is temporarily unavailable
        "ignorepponrename=true"
        # Allow root to access the mount
        "allow_other"
        # Use default permissions
        "defaults"
        # Lazy unmount
        "x-systemd.mount-timeout=30"
        # Start after underlying mounts
        "x-systemd.requires=mnt-data-disk1.mount"
        "x-systemd.requires=mnt-data-disk2.mount"
        "x-systemd.after=mnt-data-disk1.mount"
        "x-systemd.after=mnt-data-disk2.mount"
        # Don't block boot
        "nofail"
      ];
    };

    # ========================================================================
    # Directory Structure
    # ========================================================================
    # Create on each underlying disk for proper MergerFS behavior
    # setgid (2xxx) ensures new files inherit the media group

    systemd.services.nas-directory-setup = {
      description = "Create NAS directory structure on data disks";
      after = [ "mnt-data-disk1.mount" "mnt-data-disk2.mount" ];
      wantedBy = [ "multi-user.target" ];
      before = [ "srv-media.mount" ];

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
        # Create directory structure on each disk
        # This ensures MergerFS can place files on any disk
        for disk in ${lib.concatStringsSep " " cfg.diskPaths}; do
          for dir in ${lib.concatStringsSep " " dirs}; do
            mkdir -p "$disk/$dir"
            chown ${uid}:${gid} "$disk/$dir"
            chmod 2775 "$disk/$dir"
          done
        done
      '';
    };

    # ========================================================================
    # NFS Server
    # ========================================================================
    services.nfs.server = lib.mkIf cfg.nfs.enable {
      enable = true;
      # NFSv4 only (more secure, better performance)
      exports = ''
        ${cfg.nfs.exportPath} ${cfg.nfs.allowedNetwork}(rw,sync,no_subtree_check,no_root_squash,crossmnt)
      '';
      # Disable NFSv3
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
        2049 # NFS
        111  # rpcbind (needed for NFS)
      ];
      allowedUDPPorts = [
        2049
        111
      ];
    };

    # ========================================================================
    # Media Group
    # ========================================================================
    # Ensure consistent GID across hosts for NFS
    users.groups.${cfg.group} = {
      gid = lib.mkDefault 1011;
    };
  };
}
