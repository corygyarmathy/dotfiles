# Suwayomi - Manga Source Reader and Downloader
# Runs Tachiyomi extensions server-side: browse manga sources, follow series,
# and download chapters to disk as CBZ for Grimmory and Kavita to serve.
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://homelab02:4567 (or https://suwayomi.gyarmathy.co)
# 2. Add an extension repository under Settings -> Browse -> Extension repos.
#    None ship here: the repositories carry the source list, and which sources
#    to run is an operator decision, the same way Shelfmark ships no sources.
# 3. Install extensions, follow series, and download chapters
# 4. Add /srv/media/suwayomi as a library in Grimmory (and Kavita if wanted)
#
# WHY A SEPARATE DIRECTORY RATHER THAN /srv/media/manga:
# The existing manga tree is 26 GB of hand-curated releases laid out the way
# Kavita expects. Suwayomi writes its own hierarchy, keyed by source and series,
# which is not that layout. Pointing it at the same directory would interleave
# two schemes in one library and make a scanner's guesses worse for both. A
# separate library costs one entry in Grimmory and keeps the curated tree
# exactly as it is. Set downloadPath to override if that turns out to be wrong.
#
# WHY THIS ONE IS NOT BEHIND THE VPN, WHEN SHELFMARK IS:
# Not an oversight, and arguably the weaker call of the two. Manga sources sit
# behind Cloudflare far more often than book sources, and shared VPN exit
# addresses draw challenges that a residential address does not, so tunnelling
# this trades working extensions for privacy on the same class of traffic.
# It also cannot join Gluetun's namespace as cheaply as Shelfmark did: this is
# the packaged NixOS service, not a container, so tunnelling means giving up
# the module and hand-rolling one. If the tradeoff should go the other way,
# the change is to run the container image inside the gluetun namespace and
# publish 4567 from qbittorrent.nix, exactly as shelfmark.nix does.
#
# WHY homelab02:
# Manga downloads are many small files, which NFS handles badly, and this host
# owns the pool. Grimmory reads the result locally; Kavita reads it over NFS
# from homelab01, which is a read path and fine.
#
# WHAT THIS DID NOT REPLACE:
# Mylar3 was retired alongside this, but Suwayomi is not its equivalent. Mylar3
# tracked Western comic series against ComicVine and grabbed issues from
# trackers; Suwayomi pulls manga from online sources. Comics are now a manual
# search, which is what was already happening in practice.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.suwayomi;
  stack = config.cg.service.media-stack;
in
{
  # Contributes to config.cg.publish, so it declares it - see
  # modules/nixos/publish.nix.
  imports = [ ../../nixos/publish.nix ];

  options.cg.service.suwayomi = {
    enable = lib.mkEnableOption "Suwayomi manga server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 4567;
      description = "Port for the Suwayomi web UI";
    };

    downloadPath = lib.mkOption {
      type = lib.types.str;
      default = "${stack.dataPath}/suwayomi";
      description = ''
        Where downloaded chapters are written. Kept out of the curated manga
        tree on purpose -- see the header. Add this as its own library in
        whichever reader is serving it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    cg.publish.suwayomi = {
      port = cfg.port;
      rateLimitProfile = "media"; # it is a reader as well as a downloader
    };

    assertions = [
      {
        assertion = stack.enable;
        message = "suwayomi requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    services.suwayomi-server = {
      enable = true;

      # Application state (database, extensions, thumbnails) stays in
      # /var/lib/suwayomi-server; only finished chapters go to the media pool.
      # Leaving dataDir at its default also keeps the module's StateDirectory,
      # which is what creates and owns that directory.
      user = "suwayomi";
      group = stack.group;

      openFirewall = true;

      settings.server = {
        ip = "0.0.0.0";
        port = cfg.port;

        # Both keys verified against server-reference.conf inside the packaged
        # jar. The settings option is freeform, so a misspelling here would be
        # accepted silently and chapters would land in dataDir instead.
        downloadsPath = cfg.downloadPath;
        downloadAsCbz = true;
      };
    };

    # The module creates the suwayomi user with this as its primary group, so
    # chapters land group-readable under the media tree's setgid directories.
    # It only creates the group itself when group == "suwayomi", so pointing it
    # at the existing media group does not collide.

    # Only where nas-storage is not managing the tree. tmpfiles runs before the
    # ZFS pool is mounted, so an unguarded rule here would create the directory
    # on the root filesystem and have the mount hide it -- downloads would then
    # land on the wrong disk with nothing obviously wrong. Where nas-storage is
    # enabled, nas-directory-setup creates this after the mount, and the
    # download path is in media-stack.directories so it does.
    systemd.tmpfiles.rules = lib.optionals (!config.cg.service.nas-storage.enable) [
      "d ${cfg.downloadPath} 2775 ${stack.user} ${stack.group} -"
    ];

    systemd.services.suwayomi-server = {
      # Writes into the media pool, which nas-directory-setup creates and which
      # is ordered only against zfs.target -- the race that broke grimmory.
      after = lib.optional config.cg.service.nas-storage.enable "nas-directory-setup.service";
      requires = lib.optional config.cg.service.nas-storage.enable "nas-directory-setup.service";
    };
  };
}
