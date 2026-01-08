# *arr Stack - Media automation containers
# Sonarr, Radarr, Prowlarr, Bazarr, Jellyseerr, FlareSolverr
# qBittorrent runs through Gluetun VPN (ProtonVPN)
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.arr-stack;

  # Common environment for Linuxserver.io containers
  # These are set dynamically based on actual system IDs
  linuxserverEnv = {
    PUID = toString config.users.users.coryg.uid;
    PGID = toString config.users.groups.media.gid;
    TZ = config.time.timeZone;
  };

  # Media paths
  mediaPath = "/srv/media";
  configPath = "/srv/arr";
in
{
  options.cg.service.arr-stack = {
    enable = lib.mkEnableOption "arr-stack services";

    vpn = {
      enable = lib.mkEnableOption "VPN for torrent traffic via Gluetun";

      # Server country for ProtonVPN
      serverCountry = lib.mkOption {
        type = lib.types.str;
        default = "Australia";
        description = "ProtonVPN server country";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure podman is the backend
    virtualisation.oci-containers.backend = "podman";

    # Sops secret for WireGuard private key
    sops.secrets."vpn/wireguard-private-key" = lib.mkIf cfg.vpn.enable {
      # This will be available at config.sops.secrets."vpn/wireguard-private-key".path
    };

    # Create config directories with correct ownership
    # The containers run as PUID:PGID, so they need write access
    systemd.tmpfiles.rules = [
      "d ${configPath} 0775 root media -"
      "d ${configPath}/prowlarr 0775 coryg media -"
      "d ${configPath}/sonarr 0775 coryg media -"
      "d ${configPath}/radarr 0775 coryg media -"
      "d ${configPath}/bazarr 0775 coryg media -"
      "d ${configPath}/jellyseerr 0775 coryg media -"
      "d ${configPath}/qbittorrent 0775 coryg media -"
      "d ${configPath}/flaresolverr 0775 coryg media -"
      "d ${configPath}/gluetun 0775 coryg media -"
    ];

    # Create the arr-network before containers start
    systemd.services.podman-network-arr = {
      description = "Create podman network for arr stack";
      after = [ "podman.service" ];
      wantedBy = [ "multi-user.target" ];
      before = [
        "podman-prowlarr.service"
        "podman-sonarr.service"
        "podman-radarr.service"
        "podman-bazarr.service"
        "podman-jellyseerr.service"
        "podman-flaresolverr.service"
      ]
      ++ lib.optionals cfg.vpn.enable [
        "podman-gluetun.service"
      ]
      ++ lib.optionals (!cfg.vpn.enable) [
        "podman-qbittorrent.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.podman}/bin/podman network create arr-network --ignore";
      };
    };

    # Container definitions
    virtualisation.oci-containers.containers = {
      # FlareSolverr - Cloudflare bypass proxy for Prowlarr
      flaresolverr = {
        image = "ghcr.io/flaresolverr/flaresolverr:latest";
        environment = {
          LOG_LEVEL = "info";
          LOG_HTML = "false";
          CAPTCHA_SOLVER = "none";
          TZ = config.time.timeZone;
        };
        ports = [ "8191:8191" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };

      # Prowlarr - Indexer manager
      prowlarr = {
        image = "lscr.io/linuxserver/prowlarr:latest";
        environment = linuxserverEnv;
        volumes = [
          "${configPath}/prowlarr:/config"
        ];
        ports = [ "9696:9696" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };

      # Sonarr - TV show management
      sonarr = {
        image = "lscr.io/linuxserver/sonarr:latest";
        environment = linuxserverEnv;
        volumes = [
          "${configPath}/sonarr:/config"
          "${mediaPath}/tv:/tv"
          "${mediaPath}/downloads:/downloads"
        ];
        ports = [ "8989:8989" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };

      # Radarr - Movie management
      radarr = {
        image = "lscr.io/linuxserver/radarr:latest";
        environment = linuxserverEnv;
        volumes = [
          "${configPath}/radarr:/config"
          "${mediaPath}/movies:/movies"
          "${mediaPath}/downloads:/downloads"
        ];
        ports = [ "7878:7878" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };

      # Bazarr - Subtitle management
      bazarr = {
        image = "lscr.io/linuxserver/bazarr:latest";
        environment = linuxserverEnv;
        volumes = [
          "${configPath}/bazarr:/config"
          "${mediaPath}/movies:/movies"
          "${mediaPath}/tv:/tv"
        ];
        ports = [ "6767:6767" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };

      # Jellyseerr - Request management (Overseerr fork for Jellyfin)
      # Note: Use host IP to connect to Jellyfin, not container name
      jellyseerr = {
        image = "fallenbagel/jellyseerr:latest";
        environment = {
          TZ = config.time.timeZone;
          LOG_LEVEL = "info";
        };
        volumes = [
          "${configPath}/jellyseerr:/app/config"
        ];
        ports = [ "5055:5055" ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
          # Allow container to reach host services (like Jellyfin)
          "--add-host=host.containers.internal:host-gateway"
        ];
      };

      # ========================================================================
      # VPN-protected containers (when vpn.enable = true)
      # ========================================================================

      # Gluetun - VPN container that qBittorrent routes through
      gluetun = lib.mkIf cfg.vpn.enable {
        image = "qmcgaw/gluetun:latest";
        environment = {
          VPN_SERVICE_PROVIDER = "protonvpn";
          VPN_TYPE = "wireguard";
          # Private key is passed via environmentFiles below
          SERVER_COUNTRIES = cfg.vpn.serverCountry;
          # Enable port forwarding for better torrent connectivity
          VPN_PORT_FORWARDING = "on";
          # Firewall settings
          FIREWALL_OUTBOUND_SUBNETS = "10.89.0.0/24"; # Allow arr-network access
          TZ = config.time.timeZone;
        };
        # Load the WireGuard private key from sops secret
        environmentFiles = [
          config.sops.secrets."vpn/wireguard-private-key".path
        ];
        volumes = [
          "${configPath}/gluetun:/gluetun"
        ];
        # Ports are exposed on gluetun since qbittorrent uses its network
        ports = [
          "8080:8080" # qBittorrent Web UI
          # BitTorrent ports are handled by VPN port forwarding
        ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun:/dev/net/tun"
        ];
      };

      # qBittorrent - Download client (VPN mode - routes through Gluetun)
      qbittorrent = lib.mkIf cfg.vpn.enable {
        image = "lscr.io/linuxserver/qbittorrent:latest";
        environment = linuxserverEnv // {
          WEBUI_PORT = "8080";
        };
        volumes = [
          "${configPath}/qbittorrent:/config"
          "${mediaPath}/downloads:/downloads"
        ];
        # No ports - they're exposed via gluetun
        dependsOn = [ "gluetun" ];
        extraOptions = [
          "--pull=newer"
          # Use gluetun's network stack instead of arr-network
          "--network=container:gluetun"
        ];
      };

      # ========================================================================
      # Non-VPN qBittorrent (when vpn.enable = false)
      # ========================================================================

      qbittorrent-direct = lib.mkIf (!cfg.vpn.enable) {
        image = "lscr.io/linuxserver/qbittorrent:latest";
        environment = linuxserverEnv // {
          WEBUI_PORT = "8080";
        };
        volumes = [
          "${configPath}/qbittorrent:/config"
          "${mediaPath}/downloads:/downloads"
        ];
        ports = [
          "8080:8080" # Web UI
          "6881:6881" # BitTorrent TCP
          "6881:6881/udp" # BitTorrent UDP
        ];
        extraOptions = [
          "--pull=newer"
          "--network=arr-network"
        ];
      };
    };

    # Firewall rules for arr stack
    networking.firewall = {
      allowedTCPPorts = [
        9696 # Prowlarr
        8989 # Sonarr
        7878 # Radarr
        6767 # Bazarr
        5055 # Jellyseerr
        8080 # qBittorrent (via gluetun or direct)
        8191 # FlareSolverr
      ]
      ++ lib.optionals (!cfg.vpn.enable) [
        6881 # BitTorrent (only when not using VPN)
      ];
      allowedUDPPorts = lib.optionals (!cfg.vpn.enable) [
        6881 # BitTorrent (only when not using VPN)
      ];
    };
  };
}
