# Shelfmark - Book & Audiobook Search and Request Hub
# One interface to search configured sources (web, torrent, usenet, IRC), pick
# the release you actually want, and watch a unified download queue. Metadata
# comes from Hardcover, Open Library or Google Books.
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://homelab02:8084 (or https://shelfmark.gyarmathy.co)
# 2. Create an account on first launch
# 3. Configure sources under Settings. Nothing is enabled by default -- this
#    module deliberately ships no source list; which ones to run is a decision
#    for the operator, not for the Nix config.
# 4. Add qBittorrent as a download client at http://localhost:8080
# 5. Point it at Prowlarr by address: http://10.20.2.85:9696
# 6. Leave the download destination at /books, which is the BookDrop folder
#
# THOSE TWO ADDRESSES LOOK INCONSISTENT AND ARE NOT:
# qBittorrent shares this container's network namespace, so it is genuinely on
# localhost -- and it must be addressed that way, because WebUI
# HostHeaderValidation rejects a Host header that is not one of its own names.
# Giving it the LAN address returns 401 before the request reaches
# authentication, so nothing appears in qBittorrent's failure log and the
# client reports it as a wrong password.
#
# Prowlarr is on another machine and has to be reached by address for the
# opposite reason: Gluetun's resolver serves this namespace and cannot see the
# internal DNS zone, so prowlarr.gyarmathy.co does not resolve here at all.
# Same symptom class, opposite fixes.
#
# WHAT THIS REPLACED, AND WHAT WAS DROPPED WITH IT:
# LazyLibrarian did two jobs: search/grab, and monitor an author for future
# releases. Shelfmark does the first and has no equivalent of the second, so
# retiring LazyLibrarian gave up author monitoring deliberately -- it was not
# being used. Nothing in the stack does it now. If that changes, it wants a
# separate tool rather than an option here.
#
# NETWORK -- SHARES THE GLUETUN NAMESPACE:
# Shelfmark makes direct HTTP requests to book sources, which would otherwise
# egress on the home IP while qBittorrent's traffic is tunnelled. Rather than a
# second Gluetun, it joins the existing one the same way cross-seed does
# (--network=container:gluetun), so:
# - all of its egress is tunnelled and dies with the tunnel
# - qBittorrent is reachable at localhost:8080, not a container hostname
# - its web UI must be published on the *gluetun* container, since Shelfmark
#   has no network namespace of its own. That happens in qbittorrent.nix, next
#   to the identical arrangement for cross-seed.
# Falls back to arr-network when the VPN is off, matching cross-seed.
#
# WHY THIS RUNS ON homelab02:
# Grimmory's BookDrop watcher uses inotify, which does not fire for writes made
# by a remote NFS client. Shelfmark has to write into /srv/media/bookdrop on the
# machine that hosts it, or imports would only ever happen on Grimmory's next
# full scan. homelab02 also holds qBittorrent and the downloads tree.
#
# DOWNLOAD PATH MUST MATCH qBITTORRENT EXACTLY:
# For torrent grabs, Shelfmark hands a path to qBittorrent and then looks for
# the result at that same path. Both containers therefore mount the downloads
# tree at /data/downloads. Changing one without the other silently breaks
# torrent imports while direct downloads keep working.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.shelfmark;
  stack = config.cg.service.media-stack;
  qbt = config.cg.service.qbittorrent;
in
{
  options.cg.service.shelfmark = {
    enable = lib.mkEnableOption "Shelfmark book search and request hub";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8084;
      description = ''
        Host port for the Shelfmark web UI. Published on the Gluetun container
        when the VPN is enabled, because Shelfmark shares its namespace.
      '';
    };

    ingestPath = lib.mkOption {
      type = lib.types.str;
      default = "${stack.dataPath}/bookdrop";
      description = ''
        Where finished downloads land. Defaults to Grimmory's BookDrop folder,
        so anything Shelfmark fetches is imported without a manual scan.
      '';
    };

    searchMode = lib.mkOption {
      type = lib.types.enum [
        "universal"
        "direct"
      ];
      default = "universal";
      description = ''
        universal searches metadata providers and aggregates releases across
        sources; direct queries the configured sources only. Upstream
        recommends universal, and audiobook support depends on it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = stack.enable;
        message = "shelfmark requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
      {
        # Sharing a namespace with a container that does not exist yields a
        # container that cannot start, with an error that does not say why.
        assertion = !qbt.vpn.enable || qbt.enable;
        message = "shelfmark: qbittorrent.vpn is enabled but qbittorrent is not, so there is no gluetun container to share a namespace with";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/shelfmark 0775 ${stack.user} ${stack.group} -"
    ];

    virtualisation.oci-containers.containers.shelfmark = {
      image = "ghcr.io/calibrain/shelfmark:latest";
      environment = {
        PUID = toString config.users.users.${stack.user}.uid;
        PGID = toString config.users.groups.${stack.group}.gid;
        TZ = config.time.timeZone;
        FLASK_PORT = toString cfg.port;
        INGEST_DIR = "/books";
        SEARCH_MODE = cfg.searchMode;
        # Shelfmark can manage its own WireGuard tunnel. It must not here: it
        # is already inside Gluetun's namespace, and a second kill-switch
        # installing its own iptables rules in that namespace would fight the
        # one Gluetun put there.
        USING_WIREGUARD = "false";
        USING_TOR = "false";
      };
      volumes = [
        "${stack.configPath}/shelfmark:/config"
        "${cfg.ingestPath}:/books"
        # Identical to qBittorrent's mapping -- see the header.
        "${stack.dataPath}/downloads:/data/downloads"
      ];
      # Published on gluetun instead when sharing its namespace, since a
      # container without its own namespace cannot publish anything.
      ports = lib.optionals (!qbt.vpn.enable) [ "${toString cfg.port}:${toString cfg.port}" ];
      dependsOn = lib.optionals qbt.vpn.enable [ "gluetun" ];
      extraOptions = [
        "--pull=newer"
      ]
      ++ (if qbt.vpn.enable then [ "--network=container:gluetun" ] else [ "--network=arr-network" ]);
    };

    systemd.services.podman-shelfmark = {
      after = [
        "podman-network-arr.service"
      ]
      # Writes into the BookDrop folder, which nas-directory-setup creates and
      # which is ordered only against zfs.target -- the same race that broke
      # podman-grimmory before it required this.
      ++ lib.optional config.cg.service.nas-storage.enable "nas-directory-setup.service";
      requires = [
        "podman-network-arr.service"
      ]
      ++ lib.optional config.cg.service.nas-storage.enable "nas-directory-setup.service";
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
