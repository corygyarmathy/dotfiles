# Home Assistant
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.cg.service.home-assistant;
in
{
  options.cg.home-assistant.enable = lib.mkEnableOption "home-assistant service";

  config = lib.mkIf cfg.enable {
    services.home-assistant = {
      enable = true;
      openFirewall = true; # Opens port 8123

      # Extra components to include
      # Add integrations as you need them
      extraComponents = [
        # Core functionality
        "default_config"
        "met" # Weather integration

        # Common integrations - uncomment as needed
        "hue" # Philips Hue
        "cast" # Google Cast
        # "spotify"       # Spotify
        # "esphome"       # ESPHome devices
        "zha" # Zigbee Home Automation
        "zwave_js" # Z-Wave JS
        "mobile_app" # Home Assistant mobile app
        "google_assistant"
      ];

      # Extra Python packages for integrations that need them
      extraPackages =
        python3Packages: with python3Packages; [
          # Add Python dependencies for integrations here
          # gtts          # Google Text-to-Speech
          # numpy         # For some integrations
        ];

      # Basic configuration
      # Most configuration happens in the web UI and is stored in config files
      config = {
        homeassistant = {
          name = "Home";
          unit_system = "metric";
          time_zone = "Australia/Perth";
          # Set your location for weather, sun-based automations, etc.
          latitude = "!secret latitude";
          longitude = "!secret longitude";
          elevation = 0;
        };

        # Enable the default config bundle
        default_config = { };

        # HTTP configuration
        http = {
          server_port = 8123;
          # If you add a reverse proxy later:
          # use_x_forwarded_for = true;
          # trusted_proxies = [ "127.0.0.1" "::1" ];
        };
      };
    };

    # Create directory for Home Assistant secrets
    # You'll need to create /var/lib/hass/secrets.yaml manually with:
    # latitude: "-31.98"
    # longitude: "115.87"
    systemd.tmpfiles.rules = [
      "d /var/lib/hass 0750 hass hass -"
    ];
  };
}
