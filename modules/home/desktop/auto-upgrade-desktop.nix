# modules/home/desktop/auto-upgrade-desktop.nix
#
# Desktop-specific auto-upgrade features for home-manager.
#
# Features:
# - Waybar integration showing update status
# - Click handlers for applying updates
# - Desktop notifications for completion/errors
#
# Requires: cg.auto-upgrade to be enabled in the NixOS config
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.auto-upgrade-desktop;
  stateDir = "/var/lib/nixos-auto-upgrade";

  # Import the upgrade scripts package
  upgradeScripts = pkgs.callPackage ../../../packages/nixos-upgrade-scripts { };

in
{
  options.cg.home.auto-upgrade-desktop = {
    enable = lib.mkEnableOption "Desktop auto-upgrade features (waybar, notifications)";

    waybar = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable waybar integration";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Install the upgrade scripts for user access
    home.packages = [
      upgradeScripts
      pkgs.libnotify # For notifications
    ];

    # Waybar CSS
    xdg.configFile."waybar/nixos-upgrade.css" = lib.mkForce {
      source = ../../../configs/waybar/nixos-upgrade.css;
    };

    # =========================================================================
    # Systemd User Services
    # =========================================================================

    # Watch for state changes and show notifications
    systemd.user.services.nixos-upgrade-watch = {
      Unit = {
        Description = "Watch for NixOS upgrade state changes";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "upgrade-state-notify" ''
          set -euo pipefail

          STATE_FILE="${stateDir}/state.json"

          if [[ ! -f "$STATE_FILE" ]]; then
            exit 0
          fi

          STATUS=$(${pkgs.jq}/bin/jq -r '.status' "$STATE_FILE" 2>/dev/null || echo "unknown")
          ERROR=$(${pkgs.jq}/bin/jq -r '.error_message // empty' "$STATE_FILE" 2>/dev/null || echo "")
          HAS_UPDATES=$(${pkgs.jq}/bin/jq -r '(.pending_nix != null and .pending_nix.count > 0) or (.pending_firmware != null and .pending_firmware.count > 0)' "$STATE_FILE" 2>/dev/null || echo "false")
          REQUIRES_REBOOT=$(${pkgs.jq}/bin/jq -r '(.pending_nix != null and .pending_nix.requires_reboot) or (.pending_firmware != null and .pending_firmware.requires_reboot)' "$STATE_FILE" 2>/dev/null || echo "false")
          BUILD_COMPLETE=$(${pkgs.jq}/bin/jq -r '.build_complete' "$STATE_FILE" 2>/dev/null || echo "false")

          # Show notification based on state
          case "$STATUS" in
            error)
              ${pkgs.libnotify}/bin/notify-send \
                --urgency=normal \
                --icon=dialog-error \
                --app-name="NixOS Upgrade" \
                "Update Error" \
                "''${ERROR:-An error occurred during update}"
              ;;
            idle)
              if [[ "$HAS_UPDATES" == "true" ]]; then
                SUMMARY=$(${pkgs.jq}/bin/jq -r '
                  (if .pending_nix and .pending_nix.count > 0 then .pending_nix.summary else "" end) +
                  (if .pending_firmware and .pending_firmware.count > 0 then
                    (if .pending_nix and .pending_nix.count > 0 then ", " else "" end) +
                    (.pending_firmware.count | tostring) + " firmware"
                  else "" end)
                ' "$STATE_FILE" 2>/dev/null || echo "Updates available")

                if [[ "$BUILD_COMPLETE" == "true" ]]; then
                  ${pkgs.libnotify}/bin/notify-send \
                    --urgency=normal \
                    --icon=software-update-available \
                    --app-name="NixOS Upgrade" \
                    "Updates Ready" \
                    "$SUMMARY - click waybar module to apply"
                fi
              fi
              ;;
          esac
        ''}";
      };
    };

    # Path unit to trigger notifications on state change
    systemd.user.paths.nixos-upgrade-watch = {
      Unit = {
        Description = "Watch for NixOS upgrade status changes";
      };

      Path = {
        PathModified = "${stateDir}/state.json";
        Unit = "nixos-upgrade-watch.service";
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };

    # Service to show completion notification after apply
    systemd.user.services.nixos-upgrade-completion = {
      Unit = {
        Description = "Show NixOS upgrade completion notification";
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "upgrade-completion-notify" ''
          set -euo pipefail

          STATE_FILE="${stateDir}/state.json"

          if [[ ! -f "$STATE_FILE" ]]; then
            exit 0
          fi

          STATUS=$(${pkgs.jq}/bin/jq -r '.status' "$STATE_FILE" 2>/dev/null || echo "unknown")
          LAST_APPLY=$(${pkgs.jq}/bin/jq -r '.last_apply // empty' "$STATE_FILE" 2>/dev/null || echo "")

          # Check if reboot is needed by comparing kernels
          BOOTED_KERNEL=$(readlink /run/booted-system/kernel 2>/dev/null || echo "")
          CURRENT_KERNEL=$(readlink /run/current-system/kernel 2>/dev/null || echo "")

          if [[ -n "$BOOTED_KERNEL" ]] && [[ -n "$CURRENT_KERNEL" ]] && [[ "$BOOTED_KERNEL" != "$CURRENT_KERNEL" ]]; then
            ${pkgs.libnotify}/bin/notify-send \
              --urgency=critical \
              --icon=system-reboot \
              --app-name="NixOS Upgrade" \
              "Reboot Required" \
              "Kernel was updated. Click the waybar module to reboot."
          elif [[ "$STATUS" == "idle" ]] && [[ -n "$LAST_APPLY" ]]; then
            ${pkgs.libnotify}/bin/notify-send \
              --urgency=low \
              --icon=emblem-ok-symbolic \
              --app-name="NixOS Upgrade" \
              "Update Complete" \
              "System has been updated successfully."
          fi
        ''}";
      };
    };
  };
}
