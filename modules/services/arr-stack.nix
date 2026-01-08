# *arr Stack - Media automation containers
# Sonarr, Radarr, Prowlarr, Bazarr, Jellyseerr
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.arr-stack;

  # Common environment for Linuxserver.io containers
  linuxserverEnv = {
    PUID = "1000"; # Match your user's UID
    PGID = "994"; # Match your media group's GID (check with `getent group media`)
    TZ = "Australia/Perth";
  };

  # Media paths
  mediaPath = "/srv/media";
  configPath = "/srv/arr";
in
{
  options.cg.arr-stack.enable = lib.mkEnableOption "arr-stack services";

  config = lib.mkIf cfg.enable {
    # Create config directories
    systemd.tmpfiles.rules = [
      "d ${configPath} 0755 root root -"
      "d ${configPath}/prowlarr 0755 root root -"
      "d ${configPath}/sonarr 0755 root root -"
      "d ${configPath}/radarr 0755 root root -"
      "d ${configPath}/bazarr 0755 root root -"
      "d ${configPath}/jellyseerr 0755 root root -"
      "d ${configPath}/qbittorrent 0755 root root -"
    ];

    # Container definitions
    virtualisation.oci-containers.containers = {
      # Prowlarr - Indexer manager
      prowlarr = {
        image = "lscr.io/linuxserver/prowlarr:latest";
        environment = linuxserverEnv;
        volumes = [
          "${configPath}/prowlarr:/config"
        ];
        ports = [ "9696:9696" ];
        extraOptions = [ "--pull=newer" ];
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
        extraOptions = [ "--pull=newer" ];
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
        extraOptions = [ "--pull=newer" ];
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
        extraOptions = [ "--pull=newer" ];
      };

      # Jellyseerr - Request management (Overseerr fork for Jellyfin)
      jellyseerr = {
        image = "fallenbagel/jellyseerr:latest";
        environment = {
          TZ = "Australia/Perth";
          LOG_LEVEL = "info";
        };
        volumes = [
          "${configPath}/jellyseerr:/app/config"
        ];
        ports = [ "5055:5055" ];
        extraOptions = [ "--pull=newer" ];
      };

      # qBittorrent - Download client
      # Note: Configure the download paths in qBittorrent to match the volume mounts
      qbittorrent = {
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
        extraOptions = [ "--pull=newer" ];
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
        8080 # qBittorrent
        6881 # BitTorrent
      ];
      allowedUDPPorts = [
        6881 # BitTorrent
      ];
    };
  };
}
