# NAS Storage Module - MergerFS Pool + NFS Export
#
# This module configures homelab02 as a NAS server:
# - Mounts individual data disks to /mnt/data/disk{1,2,...}
# - Pools them via MergerFS into /srv/media
# - Exports /srv/media via NFS for homelab01 to mount
#
# IMPORTANT: This module does NOT partition or format disks.
# You must manually partition and format the disks first:
#
#   # For each disk:
#   sudo parted /dev/disk/by-id/ata-XXXXX mklabel gpt
#   sudo parted /dev/disk/by-id/ata-XXXXX mkpart primary ext4 0% 100%
#   sudo mkfs.ext4 -L data1 /dev/disk/by-id/ata-XXXXX-part1
#
# The module uses `nofail` so the system will boot even if disks
# are missing - services that depend on storage will fail gracefully.
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

    # Define each data disk explicitly
    dataDisks = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          device = lib.mkOption {
            type = lib.types.str;
            description = "Device path (use /dev/disk/by-id/... for reliability)";
            example = "/dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ES3V-part1";
          };
          mountPoint = lib.mkOption {
            type = lib.types.path;
            description = "Where to mount this disk";
            example = "/mnt/data/disk1";
          };
        };
      });
      default = [];
      example = [
        { device = "/dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ES3V-part1"; mountPoint = "/mnt/data/disk1"; }
        { device = "/dev/disk/by-id/ata-ST4000VN006-3CW104_WW68ETEH-part1"; mountPoint = "/mnt/data/disk2"; }
      ];
      description = "List of data disks to mount and pool";
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
      nfs-utils
    ];

    # ========================================================================
    # Create mount point directories
    # ========================================================================
    systemd.tmpfiles.rules = [
      "d ${cfg.poolPath} 2775 ${cfg.user} ${cfg.group} -"
    ] ++ (map (disk: "d ${disk.mountPoint} 0755 root root -") cfg.dataDisks);

    # ========================================================================
    # Mount individual data disks
    # ========================================================================
    # Using nofail so system boots even if disks are missing
    fileSystems = lib.listToAttrs (map (disk: {
      name = disk.mountPoint;
      value = {
        device = disk.device;
        fsType = "ext4";
        options = [
          "defaults"
          "noatime"
          "nofail"  # Don't fail boot if disk is missing
          "x-systemd.device-timeout=5s"  # Don't wait forever
        ];
      };
    }) cfg.dataDisks);

    # ========================================================================
    # MergerFS Pool
    # ========================================================================
    # Only mount if we have data disks configured
    systemd.mounts = lib.mkIf (cfg.dataDisks != []) [{
      what = lib.concatMapStringsSep ":" (d: d.mountPoint) cfg.dataDisks;
      where = cfg.poolPath;
      type = "fuse.mergerfs";
      options = lib.concatStringsSep "," [
        # Policies
        "category.create=epmfs"  # existing path, most free space (enables hardlinks)
        "func.search=ff"         # first found (fast)
        "func.rename=all"        # allows cross-branch moves

        # Performance
        "cache.files=partial"
        "cache.entry=3"
        "cache.negative_entry=1"
        "cache.attr=3"
        "async_read=true"
        "inodecalc=path-hash"

        # Behavior
        "ignorepponrename=true"
        "allow_other"
        "defaults"
        "nofail"  # Don't fail boot if pool can't mount
        "x-systemd.requires=${lib.concatMapStringsSep " " (d: "${lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" d.mountPoint)}.mount") cfg.dataDisks}"
      ];
      wantedBy = [ "multi-user.target" ];
      after = map (d: "${lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" d.mountPoint)}.mount") cfg.dataDisks;
    }];

    # ========================================================================
    # Directory Structure Setup
    # ========================================================================
    # Create directory structure on each disk after they're mounted
    systemd.services.nas-directory-setup = {
      description = "Create NAS directory structure on data disks";
      after = [ "srv-media.mount" ];
      wants = [ "srv-media.mount" ];
      wantedBy = [ "multi-user.target" ];

      # Only run if the pool is actually mounted
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
        diskPaths = map (d: d.mountPoint) cfg.dataDisks;
      in ''
        # Create directory structure on each underlying disk
        # This ensures MergerFS can place files on any disk
        for disk in ${lib.concatStringsSep " " diskPaths}; do
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
