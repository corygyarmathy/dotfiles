# qBittorrent - Torrent Download Client
# Handles torrent downloads for Sonarr and Radarr
# Optionally routes through Gluetun VPN for privacy
#
# SETUP AFTER DEPLOYMENT:
# 1. Access web UI at http://hostname:8080
# 2. Default credentials are in the container logs (first run)
# 3. Configure download paths:
#    - Default Save Path: /data/downloads/complete
#    - Keep incomplete torrents in: /data/downloads/incomplete
# 4. Enable "Create subfolder for multi-file torrents" for organization
#
# VPN MODE (vpn.enable = true):
# - All traffic routes through Gluetun (ProtonVPN WireGuard)
# - Port forwarding is automatically synced to qBittorrent
# - Web UI is exposed via Gluetun container
#
# SOPS SECRETS REQUIRED:
# - media-stack/qbittorrent/username
# - media-stack/qbittorrent/password
# - media-stack/vpn/wireguard-private-key (if VPN enabled)
#
# MIGRATION NOTES (homelab02 NAS):
# qBittorrent will MOVE to homelab02 (storage server).
# - Downloads happen directly on the NAS drives
# - Sonarr/Radarr on homelab01 will connect via network
# - Update download client URLs in Sonarr/Radarr to homelab02
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.qbittorrent;
  stack = config.cg.service.media-stack;
in
{
  # Reads config.cg.fleet, so it declares it - see modules/nixos/fleet.nix.
  imports = [ ../../nixos/fleet.nix ];

  options.cg.service.qbittorrent = {
    enable = lib.mkEnableOption "qBittorrent torrent client";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for qBittorrent web UI";
    };

    vpn = {
      enable = lib.mkEnableOption "VPN for torrent traffic via Gluetun";

      serverCountry = lib.mkOption {
        type = lib.types.str;
        default = "Australia";
        description = "ProtonVPN server country";
      };

      provider = lib.mkOption {
        type = lib.types.str;
        default = "protonvpn";
        description = "VPN service provider for Gluetun";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Require media-stack infrastructure
    assertions = [
      {
        assertion = stack.enable;
        message = "qbittorrent requires media-stack to be enabled (cg.service.media-stack.enable = true)";
      }
    ];

    # Sops secrets
    sops.secrets = {
      "media-stack/qbittorrent/username" = { };
      "media-stack/qbittorrent/password" = { };
      "media-stack/vpn/http-api-key" = { };
    }
    // lib.optionalAttrs cfg.vpn.enable {
      "media-stack/vpn/wireguard-private-key" = { };
    };

    # Create config directories
    systemd.tmpfiles.rules = [
      "d ${stack.configPath}/qbittorrent 0775 ${stack.user} ${stack.group} -"
    ]
    ++ lib.optionals cfg.vpn.enable [
      "d ${stack.configPath}/gluetun 0775 ${stack.user} ${stack.group} -"
    ];

    # Container definitions
    virtualisation.oci-containers.containers = {
      # Gluetun VPN container (when VPN enabled)
      gluetun = lib.mkIf cfg.vpn.enable {
        image = "qmcgaw/gluetun:latest";
        environment = {
          VPN_SERVICE_PROVIDER = cfg.vpn.provider;
          VPN_TYPE = "wireguard";
          SERVER_COUNTRIES = cfg.vpn.serverCountry;
          VPN_PORT_FORWARDING = "on";
          FIREWALL_OUTBOUND_SUBNETS = "10.89.0.0/24,${config.cg.fleet.lan.cidr}";
          TZ = config.time.timeZone;
        };
        environmentFiles = [
          config.sops.secrets."media-stack/vpn/wireguard-private-key".path
          config.sops.secrets."media-stack/vpn/http-api-key".path
        ];
        volumes = [
          "${stack.configPath}/gluetun:/gluetun"
        ];
        ports = [
          "${toString cfg.port}:8080"
          "8000:8000"
        ]
        ++ lib.optionals config.cg.service.cross-seed.enable [
          "${toString config.cg.service.cross-seed.port}:2468"
        ]
        # Shelfmark shares this namespace too, so its UI is published here for
        # the same reason cross-seed's is.
        ++ lib.optionals config.cg.service.shelfmark.enable [
          "${toString config.cg.service.shelfmark.port}:${toString config.cg.service.shelfmark.port}"
        ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun:/dev/net/tun"
        ];
      };

      # qBittorrent (VPN mode - routes through Gluetun)
      qbittorrent = lib.mkIf cfg.vpn.enable {
        image = "lscr.io/linuxserver/qbittorrent:latest";
        environment = {
          PUID = toString config.users.users.${stack.user}.uid;
          PGID = toString config.users.groups.${stack.group}.gid;
          TZ = config.time.timeZone;
          WEBUI_PORT = "8080";
        };
        volumes = [
          "${stack.configPath}/qbittorrent:/config"
          "${stack.dataPath}/downloads:/data/downloads"
        ];
        dependsOn = [ "gluetun" ];
        extraOptions = [
          "--pull=newer"
          "--network=container:gluetun"
        ];
      };

      # qBittorrent (direct mode - no VPN)
      qbittorrent-direct = lib.mkIf (!cfg.vpn.enable) {
        image = "lscr.io/linuxserver/qbittorrent:latest";
        environment = {
          PUID = toString config.users.users.${stack.user}.uid;
          PGID = toString config.users.groups.${stack.group}.gid;
          TZ = config.time.timeZone;
          WEBUI_PORT = "8080";
        };
        volumes = [
          "${stack.configPath}/qbittorrent:/config"
          "${stack.dataPath}/downloads:/data/downloads"
        ];
        ports = [
          "${toString cfg.port}:8080"
          "6881:6881"
          "6881:6881/udp"
        ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };
    };

    # Service dependencies
    systemd.services = {
      podman-gluetun = lib.mkIf cfg.vpn.enable {
        after = [ "podman-network-arr.service" ];
        requires = [ "podman-network-arr.service" ];
        serviceConfig = {
          LoadCredential = [
            "gluetun-api-key:${config.sops.secrets."media-stack/vpn/http-api-key".path}"
          ];
        };
        preStart = ''
          mkdir -p ${stack.configPath}/gluetun/auth
          API_KEY=$(cat "$CREDENTIALS_DIRECTORY/gluetun-api-key" | sed 's/^HTTP_CONTROL_SERVER_API_KEY=//')
          printf '[[roles]]\nname = "vpn-port-sync"\nauth = "apikey"\napikey = "%s"\nroutes = ["GET /v1/portforward", "GET /v1/vpn/status"]\n' "$API_KEY" \
            > ${stack.configPath}/gluetun/auth/config.toml
          chmod 600 ${stack.configPath}/gluetun/auth/config.toml
        '';
      };

      podman-qbittorrent-direct = lib.mkIf (!cfg.vpn.enable) {
        after = [ "podman-network-arr.service" ];
        requires = [ "podman-network-arr.service" ];
      };

      podman-qbittorrent = lib.mkIf cfg.vpn.enable {
        # Clear stuck lockfile, preventing crashing loop
        preStart = ''
          rm -f ${stack.configPath}/qbittorrent/qBittorrent/lockfile
        '';
      };

      # VPN port forwarding sync service
      # NOTE: This script runs on the HOST, not inside a container.
      # It communicates with Gluetun and qBittorrent via their host-mapped ports.
      # Since Gluetun exposes both services to localhost (8000 for Gluetun API,
      # cfg.port for qBittorrent WebUI), localhost is the correct address here.
      vpn-port-sync = lib.mkIf cfg.vpn.enable {
        description = "Sync VPN forwarded port to qBittorrent";
        after = [
          "podman-gluetun.service"
          "podman-qbittorrent.service"
        ];
        requires = [ "podman-gluetun.service" ];

        path = [
          pkgs.curl
          pkgs.jq
        ];

        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "qbt-user:${config.sops.secrets."media-stack/qbittorrent/username".path}"
            "qbt-pass:${config.sops.secrets."media-stack/qbittorrent/password".path}"
            "gluetun-api-key:${config.sops.secrets."media-stack/vpn/http-api-key".path}"
          ];
        };

        script = ''
          QB_USER=$(cat "$CREDENTIALS_DIRECTORY/qbt-user")
          QB_PASS=$(cat "$CREDENTIALS_DIRECTORY/qbt-pass")
          API_KEY=$(cat "$CREDENTIALS_DIRECTORY/gluetun-api-key" | sed 's/^HTTP_CONTROL_SERVER_API_KEY=//')

          FORWARDED_PORT=$(curl -sf -H "X-API-Key: $API_KEY" \
            "http://localhost:8000/v1/portforward" 2>/dev/null \
            | jq -r '.port // empty')

          if [ -z "$FORWARDED_PORT" ] || [ "$FORWARDED_PORT" = "0" ]; then
            echo "Could not get forwarded port from Gluetun (got: ''${FORWARDED_PORT:-empty})"
            exit 1
          fi

          # qBittorrent >=5.2.0 returns 204 on login (not 200) and renamed
          # the session cookie from SID to QBT_SID_<port>. Using a cookie jar
          # file handles both the old and new cookie names transparently.
          COOKIE_JAR=$(mktemp)
          trap 'rm -f "$COOKIE_JAR"' EXIT

          HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
            -c "$COOKIE_JAR" \
            "http://localhost:${toString cfg.port}/api/v2/auth/login" \
            --data-urlencode "username=$QB_USER" \
            --data-urlencode "password=$QB_PASS")

          if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
            echo "Failed to authenticate with qBittorrent (HTTP $HTTP_CODE)"
            exit 1
          fi

          CURRENT_PORT=$(curl -sf "http://localhost:${toString cfg.port}/api/v2/app/preferences" \
            -b "$COOKIE_JAR" 2>/dev/null \
            | jq -r '.listen_port // empty')

          if [ "$CURRENT_PORT" = "$FORWARDED_PORT" ]; then
            echo "Port already correct ($FORWARDED_PORT), nothing to do"
            exit 0
          fi

          echo "Updating qBittorrent listen port: $CURRENT_PORT -> $FORWARDED_PORT"
          curl -sf "http://localhost:${toString cfg.port}/api/v2/app/setPreferences" \
            -b "$COOKIE_JAR" \
            --data-urlencode "json={\"listen_port\": $FORWARDED_PORT}"

          echo "Done"
        '';
      };
    };

    # Timers for established services
    systemd.timers = {
      vpn-port-sync = lib.mkIf cfg.vpn.enable {
        description = "Timer for VPN port sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "5min";
          Unit = "vpn-port-sync.service";
        };
      };
    };

    # Firewall
    networking.firewall = {
      allowedTCPPorts = [ cfg.port ] ++ lib.optionals (!cfg.vpn.enable) [ 6881 ];
      allowedUDPPorts = lib.optionals (!cfg.vpn.enable) [ 6881 ];
    };
  };
}
