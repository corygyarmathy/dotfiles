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
          SERVER_ENDPOINT_IP = "103.108.231.162";
          VPN_PORT_FORWARDING = "on";
          FIREWALL_OUTBOUND_SUBNETS = "10.89.0.0/24,10.20.2.0/24";
          TZ = config.time.timeZone;
        };
        environmentFiles = [
          config.sops.secrets."media-stack/vpn/wireguard-private-key".path
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
      };

      podman-qbittorrent-direct = lib.mkIf (!cfg.vpn.enable) {
        after = [ "podman-network-arr.service" ];
        requires = [ "podman-network-arr.service" ];
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
        wantedBy = [ "multi-user.target" ];

        path = [
          pkgs.curl
          pkgs.jq
        ];

        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = "60";
          LoadCredential = [
            "qbt-user:${config.sops.secrets."media-stack/qbittorrent/username".path}"
            "qbt-pass:${config.sops.secrets."media-stack/qbittorrent/password".path}"
          ];
        };

        script = ''
          sleep 30

          QB_USER=$(cat "$CREDENTIALS_DIRECTORY/qbt-user")
          QB_PASS=$(cat "$CREDENTIALS_DIRECTORY/qbt-pass")

          LAST_PORT=""

          while true; do
            PORT=$(curl -sf "http://localhost:8000/v1/portforward" 2>/dev/null | jq -r '.port // empty')
            
            if [ -n "$PORT" ] && [ "$PORT" != "0" ] && [ "$PORT" != "$LAST_PORT" ]; then
              echo "Port changed: $LAST_PORT -> $PORT"
              
              COOKIE=$(curl -sf -c - "http://localhost:${toString cfg.port}/api/v2/auth/login" \
                --data-urlencode "username=$QB_USER" \
                --data-urlencode "password=$QB_PASS" 2>/dev/null | grep -oP 'SID\s+\K\S+')
              
              if [ -n "$COOKIE" ]; then
                curl -sf "http://localhost:${toString cfg.port}/api/v2/app/setPreferences" \
                  --cookie "SID=$COOKIE" \
                  --data-urlencode "json={\"listen_port\": $PORT}"
                
                echo "Updated qBittorrent to port $PORT"
                LAST_PORT="$PORT"
              else
                echo "Failed to authenticate with qBittorrent"
              fi
            fi
            
            sleep 300
          done
        '';
      };
    };

    # Firewall
    networking.firewall = {
      allowedTCPPorts = [ cfg.port ] ++ lib.optionals (!cfg.vpn.enable) [ 6881 ];
      allowedUDPPorts = lib.optionals (!cfg.vpn.enable) [ 6881 ];
    };
  };
}
