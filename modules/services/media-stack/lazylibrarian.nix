# LazyLibrarian - Ebook & Audiobook Automation
# Monitors authors and automatically downloads new ebooks via torrent/usenet
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:5299
# 2. Configure metadata providers in Config > Importing:
#    - Goodreads, LibraryThing, Hardcover, OpenLibrary, or Google Books
# 3. Add download client (qBittorrent at http://qbittorrent:8080 or http://gluetun:8080 if VPN)
# 4. Set eBook Library Folder to: /data/books
# 5. Set Download Directories to: /data/downloads/complete
# 6. Add authors to monitor and set books as 'wanted'
#
# HARDLINKS:
# This container mounts the entire dataPath as /data, enabling hardlinks
# between /data/downloads and /data/books (same filesystem inside container).
#
# KAVITA INTEGRATION:
# LazyLibrarian downloads and organises books into /data/books which Kavita
# monitors as a library. After LazyLibrarian processes a download, Kavita's
# scheduled (or manual) scan will pick up the new files.
#
# MIGRATION NOTES (homelab02 NAS):
# LazyLibrarian stays on homelab01. When NFS is enabled:
# - /data will point to NFS mount automatically
# - Download client URL changes to homelab02's qBittorrent
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.lazylibrarian;
  stack = config.cg.service.media-stack;
in
{
  options.cg.service.lazylibrarian = {
    enable = lib.mkEnableOption "LazyLibrarian ebook automation";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5299;
      description = "Port for LazyLibrarian web UI";
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "lazylibrarian requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Create config directory
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/lazylibrarian 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definition
    virtualisation.oci-containers.containers.lazylibrarian = {
      image = "lscr.io/linuxserver/lazylibrarian:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
        UMASK = "002"; # produces 775 dirs / 664 files
        DOCKER_MODS = "linuxserver/mods:lazylibrarian-ffmpeg|linuxserver/mods:universal-calibre";
      };
      volumes = [
        "${stack.configPath}/lazylibrarian:/config"
        "${stack.dataPath}:/data"
      ];
      ports = [ "${toString cfg.port}:5299" ];
      extraOptions = [
        "--pull=newer"
        "--network=arr-network"
      ];
    };

    # Ensure network exists before starting
    systemd.services.podman-lazylibrarian = {
      after = [ "podman-network-arr.service" ];
      requires = [ "podman-network-arr.service" ];
    };

    # Firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
