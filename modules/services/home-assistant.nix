# Home Assistant
#
# Provides:
# - Local control of the house's lights and plugs from one UI and the mobile app
# - Integrations for what is actually in the house: Philips Hue (via the Hue
#   Bridge), IKEA TRÅDFRI (via the TRÅDFRI gateway) and TP-Link Kasa plugs
#
# Architecture:
# - Home Assistant listens on loopback only and is reached through Caddy at
#   https://home.<domain>, like every other published service.
# - Devices are configured in the UI, not here: pairing state (the Hue
#   bridge's app key, the TRÅDFRI gateway's PSK, Kasa credentials) lands in
#   /var/lib/hass/.storage, which is backed up with the rest of the state
#   directory.
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
# - Discovery: Hue bridges and TRÅDFRI gateways announce themselves over
#   mDNS, so UDP 5353 is opened. Kasa discovery is a UDP broadcast whose
#   replies conntrack does not match to the request, so Kasa plugs are added
#   by IP - give them fixed DHCP leases. Nothing else listens beyond
#   loopback: all three integrations poll or hold connections outbound.
#
# Post-deploy setup:
#   1. Open https://home.<domain> and complete onboarding (owner account,
#      location, time zone, units).
#   2. Hue: Settings → Devices & services → Add → Philips Hue, then press the
#      bridge's button when asked.
#   3. TRÅDFRI: Add → IKEA TRÅDFRI, giving the gateway's IP and the security
#      code printed on its underside.
#   4. Kasa: Add → TP-Link Smart Home, once per plug, by IP. Newer firmware
#      asks for the TP-Link account credentials the Kasa app uses.
#   5. Mobile: install the Home Assistant app and point it at
#      https://home.<domain>. It works on the LAN only unless the host sets
#      `cg.publish.home-assistant.localOnly = false`.
{
  config,
  lib,
  ...
}:

let
  cfg = config.cg.service.home-assistant;
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
  };

  config = lib.mkIf cfg.enable {
    cg.publish.home-assistant = {
      subdomain = "home";
      port = cfg.port;
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
      ];

      config = {
        default_config = { };

        # See the header: any key here locks the General settings page. The
        # upstream module defaults `time_zone` from `time.timeZone`; null is
        # what it drops from the rendered file.
        homeassistant.time_zone = lib.mkForce null;

        http = {
          server_host = [
            "127.0.0.1"
            "::1"
          ];
          server_port = cfg.port;
          use_x_forwarded_for = true;
          trusted_proxies = [
            "127.0.0.1"
            "::1"
          ];
        };
      };
    };

    # mDNS, for discovering the Hue bridge and the TRÅDFRI gateway.
    networking.firewall.allowedUDPPorts = [ 5353 ];
  };
}
