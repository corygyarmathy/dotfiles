# Wireless network configuration with sops-managed credentials
#
# This module configures wifi networks using NetworkManager and sops secrets.
# Each network password is stored in sops and written to a file that
# NetworkManager reads.
#
# Usage:
# 1. Add wifi passwords to this host's secrets file (secrets/<hostname>.yaml -
#    a PSK is as host-specific as a secret gets; see secrets/README.md):
#    wifi:
#        MyHomeNetwork: "my_password"
#        WorkWifi: "work_password"
#
# 2. Enable in your host config:
#    cg.wireless = {
#      enable = true;
#      networks = [ "MyHomeNetwork" "WorkWifi" ];
#    };

{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.wireless;
in
{
  options.cg.wireless = {
    enable = lib.mkEnableOption "Wireless network management with sops secrets";

    networks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "HomeWifi"
        "WorkNetwork"
      ];
      description = ''
        List of network SSIDs to configure. Each SSID must have a corresponding
        secret at wifi/<ssid> in your sops secrets file.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Define sops secrets for each network
    sops.secrets = lib.listToAttrs (
      map (ssid: {
        name = "wifi/${ssid}";
        value = {
          # NetworkManager runs as root
          owner = "root";
          group = "root";
          mode = "0400";
          # Restart the wifi setup service when secrets change
          restartUnits = [ "setup-wifi-connections.service" ];
        };
      }) cfg.networks
    );

    # Ensure NetworkManager is enabled (you likely already have this)
    networking.networkmanager.enable = lib.mkDefault true;

    # Create a systemd service that generates NetworkManager connection files
    # from the sops secrets after they're decrypted
    systemd.services.setup-wifi-connections = {
      description = "Setup WiFi connections from sops secrets";
      wantedBy = [ "multi-user.target" ];
      after = [
        "NetworkManager.service"
        "network.target"
      ];
      wants = [ "NetworkManager.service" ];

      # Only run if the secrets directory exists (meaning sops has decrypted)
      unitConfig = {
        ConditionPathExists = "/run/secrets/wifi";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # Restart on rebuild when network list changes
      # This creates a unique hash based on the network names
      restartTriggers = [
        (builtins.hashString "sha256" (builtins.toJSON cfg.networks))
      ];

      script = lib.concatMapStringsSep "\n" (ssid: ''
        # Read password from sops secret
        if [ ! -f "${config.sops.secrets."wifi/${ssid}".path}" ]; then
          echo "Secret file for ${ssid} not found, skipping"
          exit 0
        fi

        PSK=$(cat ${config.sops.secrets."wifi/${ssid}".path})

        # Check if connection already exists
        if ${pkgs.networkmanager}/bin/nmcli connection show "${ssid}" &>/dev/null; then
          echo "Updating existing connection: ${ssid}"
          # Update existing connection
          ${pkgs.networkmanager}/bin/nmcli connection modify "${ssid}" \
            wifi-sec.psk "$PSK"
        else
          echo "Creating new connection: ${ssid}"
          # Create new connection
          ${pkgs.networkmanager}/bin/nmcli connection add \
            type wifi \
            con-name "${ssid}" \
            ssid "${ssid}" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$PSK"
        fi
      '') cfg.networks;
    };
  };
}
