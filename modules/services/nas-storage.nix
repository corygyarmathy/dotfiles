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
        example = "10.20.2.85/32";
        description = ''
          Host or network allowed to mount the export. Prefer the narrowest
          value that works — ideally the single NFS client's IP (e.g.
          "10.20.2.85/32") rather than a whole subnet, since the export grants
          read-write access to all media.
        '';
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
      after = [ "zfs.target" ];
      requires = [ "zfs.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        RequiresMountsFor = cfg.poolPath; # blocks until path is actually mounted
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
            "livetv"
            "books"
            "comics"
            "manga"
            "doujin"
            "lightnovels"
            "audiobooks"
            "podcasts"
            "whisparr"
          ];
        in
        ''
          # Wait for ZFS to fully settle
          sleep 2

          # Ensure the pool root is group-traversable
          # ZFS defaults to 0700 on the mountpoint which blocks
          # non-owner group members (e.g. kavita) from traversing
          chown ${uid}:${gid} "${cfg.poolPath}"
          chmod 2775 "${cfg.poolPath}"

          for dir in ${lib.concatStringsSep " " dirs}; do
            mkdir -p "${cfg.poolPath}/$dir"
            chown ${uid}:${gid} "${cfg.poolPath}/$dir"
            chmod 2775 "${cfg.poolPath}/$dir"
          done

          # Set BOTH access ACL (grants access to this directory)
          # and default ACL (inherited by new children)
          ${pkgs.acl}/bin/setfacl -m g::rwX "${cfg.poolPath}"
          ${pkgs.acl}/bin/setfacl -d -m g::rwX "${cfg.poolPath}"
          for dir in ${lib.concatStringsSep " " dirs}; do
            ${pkgs.acl}/bin/setfacl -m g::rwX "${cfg.poolPath}/$dir"
            ${pkgs.acl}/bin/setfacl -d -m g::rwX "${cfg.poolPath}/$dir"
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
      #
      # root_squash (the default; kept explicit here): a remote root user is
      # mapped to the anonymous user instead of local root. The media clients
      # run their containers as the media PUID/PGID, not root, so they are
      # unaffected — but this prevents a compromised or misbehaving root process
      # on a client from deleting the whole library over NFS.
      exports = ''
        ${cfg.nfs.exportPath} ${cfg.nfs.allowedNetwork}(rw,sync,no_subtree_check,root_squash,fsid=1)
      '';
    };

    # NFSv4 only — v3 is disabled. Lives under services.nfs.settings rather
    # than services.nfs.server.extraNfsdConfig, which is deprecated.
    services.nfs.settings = lib.mkIf cfg.nfs.enable {
      nfsd = {
        vers3 = "n";
        vers4 = "y";
        "vers4.1" = "y";
        "vers4.2" = "y";
      };
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
