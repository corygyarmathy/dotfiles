# Home Assistant
#
# Provides:
# - Local control of the house's lights and plugs from one UI and the mobile app
# - Integrations for what is actually in the house: Philips Hue (via the Hue
#   Bridge), IKEA TRÅDFRI (via the TRÅDFRI gateway), TP-Link Kasa plugs, the
#   Samsung TV and Music Frame (Samsung TV, SmartThings, DLNA, Cast), the
#   UniFi network and Seeley MagIQtouch climate controllers
# - Integrations for devices Home Assistant discovers on the LAN and would
#   otherwise log an error for on every attempt: AirPlay devices (Apple TV),
#   Thread border routers and network printers (IPP)
# - Integrations for the homelab's own services: Jellyfin (playback-driven
#   lighting), ntfy (notifications), AdGuard Home, qBittorrent, Sonarr and
#   Radarr
# - Adaptive Lighting (a custom component) for colour temperature that
#   follows the day
# - MagIQtouch (a custom component, packages/ha-magiqtouch), which goes
#   through Seeley's cloud rather than the LAN
# - Its entities as Prometheus metrics at /api/prometheus, scraped by the
#   host's own Prometheus when it runs one
#
# Architecture:
# - Home Assistant listens on loopback only and is reached through Caddy at
#   https://home.<domain>, like every other published service.
# - Devices are configured in the UI, not here: pairing state (the Hue
#   bridge's app key, the TRÅDFRI gateway's PSK, Kasa credentials) lands in
#   /var/lib/hass/.storage, which is backed up with the rest of the state
#   directory.
# - Automations, scripts and scenes are also made in the UI, not here: they
#   name entities that only exist once devices are paired. The editors save
#   to automations.yaml, scripts.yaml and scenes.yaml in the state directory,
#   which configuration.yaml includes.
#
# Non-obvious implementation notes:
# - No core setting (name, location, time zone, units) is written to
#   configuration.yaml. Home Assistant treats the presence of any one of
#   them as "configured in YAML" and makes the whole General settings page
#   read-only, location included. Leaving them out lets onboarding set them,
#   which also keeps the home's coordinates out of this repository without
#   needing a secret. The upstream module would otherwise emit `time_zone`
#   from `time.timeZone`, so that one is nulled.
# - Behind Caddy, Home Assistant answers 400 to any request carrying
#   X-Forwarded-For unless `use_x_forwarded_for` is on and the proxy's
#   address is in `trusted_proxies`. Caddy dials `localhost`, which may
#   resolve to either loopback address, so both are trusted.
# - The HTTP settings (bind address, port, proxy trust) are not in
#   configuration.yaml either. Since 2026.11 Home Assistant keeps them in
#   .storage/http, edited under Settings → System → Network: an `http:`
#   block is imported once and then ignored with a repair warning, and on a
#   fresh state directory the import is only a trial that reverts to the
#   defaults (every interface, no proxy trust) unless confirmed in the UI
#   within five minutes. So the store itself is written from Nix before
#   every start; changes made on that page last until the next restart.
# - Discovery: Hue bridges and TRÅDFRI gateways announce themselves over
#   mDNS, so UDP 5353 is opened. Kasa discovery is a UDP broadcast whose
#   replies conntrack does not match to the request, so Kasa plugs are added
#   by IP - give them fixed DHCP leases. Nothing else listens beyond
#   loopback: all three integrations poll or hold connections outbound.
# - The UI editors only save when configuration.yaml includes their file,
#   and Home Assistant refuses to start when an included file is missing.
#   Its own first-run setup writes them, but only alongside a
#   configuration.yaml it writes itself, so tmpfiles creates them instead -
#   automations.yaml as `[]`, the content that first run would give it.
#
# Post-deploy setup:
#   1. Open https://home.<domain> and complete onboarding (owner account,
#      location, time zone, units). Then, with Advanced mode on in the user
#      profile, set both URLs under Settings → System → Network to
#      https://home.<domain>. Left unset, Home Assistant advertises
#      http://<LAN address>:8123 over mDNS, where nothing listens, and the
#      mobile app times out on it. They cannot go in configuration.yaml for
#      the same reason as the core settings below.
#   2. Hue: Settings → Devices & services → Add → Philips Hue, then press the
#      bridge's button when asked.
#   3. TRÅDFRI: Add → IKEA TRÅDFRI, giving the gateway's IP and the security
#      code printed on its underside.
#   4. Kasa: Add → TP-Link Smart Home, once per plug, by IP. Newer firmware
#      asks for the TP-Link account credentials the Kasa app uses.
#   5. Homelab services: Add → Jellyfin, ntfy, AdGuard Home, qBittorrent,
#      Sonarr, Radarr, each with that service's URL and an API key or login
#      made in its own UI. Adaptive Lighting: Add → Adaptive Lighting, then
#      pick its lights in the entry's options.
#   6. Samsung TV: Add → Samsung Smart TV, and accept the prompt on the TV.
#      Music Frame: Add → SmartThings (signs in to the Samsung account), or
#      DLNA Digital Media Renderer / Google Cast if it is discovered as one.
#   7. UniFi: Add → UniFi Network, with a local-only account made on the
#      console for Home Assistant.
#   8. MagIQtouch: Add → Seeley MagIQtouch, with the MagIQtouch app's login.
#   9. Mobile: install the Home Assistant app and point it at
#      https://home.<domain>. It works on the LAN only unless the host sets
#      `cg.publish.home-assistant.localOnly = false`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cg.service.home-assistant;

  # Home Assistant's HTTP store (`.storage/http`), in the shape its own
  # schema produces: every key present, defaults filled in. `stable` is what
  # it binds with; no `pending` means no trial config to revert, and
  # `yaml_migration_done` stops it looking for an `http:` block.
  httpSettings = {
    server_host = [
      "127.0.0.1"
      "::1"
    ];
    server_port = cfg.port;
    use_x_forwarded_for = true;
    # Caddy dials `localhost`, which may resolve to either loopback address.
    trusted_proxies = [
      "127.0.0.1/32"
      "::1/128"
    ];
    # No automatic bans, although a host may publish this to the internet.
    # Every request that skips a proxy arrives from loopback with no
    # X-Forwarded-For - Prometheus's scrape, chiefly - so one stale token
    # would ban 127.0.0.1 and lock all of them out until ip_bans.yaml is
    # edited by hand. Turn on TOTP for every account instead.
    login_attempts_threshold = -1;
    ip_ban_enabled = true;
    cors_allowed_origins = [ "https://cast.home-assistant.io" ];
    ssl_profile = "intermediate_v6";
    use_x_frame_options = true;
    created_at = "1970-01-01T00:00:00+00:00";
    error = null;
    error_message = null;
  };
  httpStore = pkgs.writeText "home-assistant-http-store.json" (
    builtins.toJSON {
      version = 3;
      minor_version = 1;
      key = "http";
      data = {
        stable = httpSettings;
        pending = null;
        yaml_migration_done = true;
      };
    }
  );
in
{
  imports = [ ../nixos/publish.nix ];

  options.cg.service.home-assistant = {
    enable = lib.mkEnableOption "Home Assistant";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8123;
      description = "Port Home Assistant listens on (loopback only).";
    };

    prometheusTokenSecret = lib.mkOption {
      type = lib.types.str;
      default = "prometheus/ha-token";
      description = ''
        Sops secret holding the long-lived Home Assistant access token the
        host's Prometheus scrapes /api/prometheus with. Only declared when
        the host runs Prometheus.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        cg.publish.home-assistant = {
          subdomain = "home";
          port = cfg.port;
          # The default `admin` profile (300 requests per 10 minutes) is used
          # up by one frontend load, which fetches hundreds of chunks, plus
          # the API polling from the app and dashboards. Only LAN clients
          # reach Caddy anyway, because the tunnel connects straight to the
          # origin, so the limiter would only ever throttle the house.
          rateLimitProfile = "none";
        };

        services.home-assistant = {
          enable = true;

          extraComponents = [
            # Onboarding has to be available on a fresh state directory, and the
            # forecast it offers to set up during it needs `met`.
            "met"
            "mobile_app"

            "hue"
            "tradfri"
            "tplink"

            "cast"
            "dlna_dmr"
            "samsungtv"
            "smartthings"
            "unifi"
            "unifi_discovery"

            "apple_tv"
            "ipp"
            "thread"

            "adguard"
            "jellyfin"
            "ntfy"
            "prometheus"
            "qbittorrent"
            "radarr"
            "sonarr"
          ];

          customComponents = [
            pkgs.home-assistant-custom-components.adaptive_lighting
            pkgs.ha-magiqtouch
          ];

          config = {
            default_config = { };

            # Where the UI editors save; see the header.
            automation = "!include automations.yaml";
            script = "!include scripts.yaml";
            scene = "!include scenes.yaml";

            # YAML-only integration. The endpoint requires a long-lived access
            # token, like the rest of the API.
            prometheus = { };

            # See the header: any key here locks the General settings page. The
            # upstream module defaults `time_zone` from `time.timeZone`; null is
            # what it drops from the rendered file.
            homeassistant.time_zone = lib.mkForce null;
          };
        };

        # `f` only writes when the file is missing, so the editors' saves stay.
        systemd.tmpfiles.settings."10-home-assistant" =
          let
            editorFile = argument: {
              f = {
                user = "hass";
                group = "hass";
                mode = "0644";
                inherit argument;
              };
            };
            dir = config.services.home-assistant.configDir;
          in
          {
            "${dir}/automations.yaml" = editorFile "[]";
            "${dir}/scripts.yaml" = editorFile "";
            "${dir}/scenes.yaml" = editorFile "";
          };

        # See the header: the HTTP settings live in Home Assistant's own store,
        # rewritten from Nix on every start.
        systemd.services.home-assistant.preStart = lib.mkAfter ''
          install -D -m 600 ${httpStore} "${config.services.home-assistant.configDir}/.storage/http"
        '';

        # mDNS, for discovering the Hue bridge and the TRÅDFRI gateway.
        networking.firewall.allowedUDPPorts = [ 5353 ];
      }

      # Scraped by the host's own Prometheus over loopback, since that is all
      # Home Assistant listens on; a peer's Prometheus could not reach it.
      (lib.mkIf config.services.prometheus.enable {
        sops.secrets.${cfg.prometheusTokenSecret}.owner = "prometheus";

        services.prometheus.scrapeConfigs = [
          {
            job_name = "home-assistant";
            metrics_path = "/api/prometheus";
            authorization.credentials_file = config.sops.secrets.${cfg.prometheusTokenSecret}.path;
            static_configs = [
              {
                targets = [ "127.0.0.1:${toString cfg.port}" ];
                labels.instance = config.networking.hostName;
              }
            ];
          }
        ];
      })
    ]
  );
}
