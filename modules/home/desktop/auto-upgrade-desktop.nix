# modules/home/desktop/auto-upgrade-desktop.nix
#
# Desktop-specific auto-upgrade features:
# - Session detection (don't auto-reboot if logged in)
# - Interactive notifications via dunst
# - Waybar integration for status display
# - Manual update check/apply triggers
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.home.auto-upgrade-desktop;
  stateDir = "/var/lib/nixos-auto-upgrade";

  # Script to get current upgrade status
  getStatusScript = pkgs.writeShellScriptBin "nixos-upgrade-status" ''
    STATE_DIR="${stateDir}"
    
    if [[ ! -d "$STATE_DIR" ]]; then
      echo "unknown"
      exit 0
    fi
    
    STATUS_FILE="$STATE_DIR/status"
    REBOOT_FILE="$STATE_DIR/reboot-pending"
    
    if [[ -f "$REBOOT_FILE" ]] && [[ "$(cat "$REBOOT_FILE")" == "yes" ]]; then
      echo "reboot-pending"
    elif [[ -f "$STATUS_FILE" ]]; then
      cat "$STATUS_FILE"
    else
      echo "idle"
    fi
  '';

  # Script to get reboot summary
  getSummaryScript = pkgs.writeShellScriptBin "nixos-upgrade-summary" ''
    SUMMARY_FILE="${stateDir}/reboot-summary"
    
    if [[ -f "$SUMMARY_FILE" ]]; then
      cat "$SUMMARY_FILE"
    else
      echo "System updates applied. Reboot recommended."
    fi
  '';

  # Script to check if graphical session is active
  isSessionActiveScript = pkgs.writeShellScriptBin "nixos-upgrade-session-active" ''
    # Check if any graphical session is running
    # This checks for Hyprland, but could be extended for other compositors
    
    if pgrep -x "Hyprland" > /dev/null 2>&1; then
      echo "active"
      exit 0
    fi
    
    if pgrep -x "gnome-shell" > /dev/null 2>&1; then
      echo "active"
      exit 0
    fi
    
    if pgrep -x "kwin_wayland" > /dev/null 2>&1; then
      echo "active"
      exit 0
    fi
    
    # Check for any wayland or X sessions
    if [[ -n "$(loginctl list-sessions --no-legend 2>/dev/null | grep -E '(wayland|x11)')" ]]; then
      echo "active"
      exit 0
    fi
    
    echo "inactive"
  '';

  # Script to show reboot prompt via dunst
  showRebootPromptScript = pkgs.writeShellScriptBin "nixos-upgrade-reboot-prompt" ''
    SUMMARY=$(${getSummaryScript}/bin/nixos-upgrade-summary)
    
    # Create action-enabled notification using dunstify
    ACTION=$(${pkgs.dunst}/bin/dunstify \
      -u critical \
      -a "NixOS Upgrade" \
      -i system-reboot \
      -h string:x-dunst-stack-tag:nixos-reboot \
      -A "reboot,Reboot Now" \
      -A "later,Later" \
      --timeout=0 \
      "System Upgrade Complete" \
      "$SUMMARY - Middle-click for actions")
    
    case "$ACTION" in
      "reboot")
        systemctl reboot
        ;;
      "later"|"")
        # User clicked later or dismissed - do nothing
        # Waybar indicator will remain as reminder
        ;;
    esac
  '';

  # Script to trigger manual update check
  # Uses a systemd service that runs as root, triggered via dbus
  checkUpdatesScript = pkgs.writeShellScriptBin "nixos-upgrade-check" ''
    # Show checking notification (use dunstify for better dunst integration)
    ${pkgs.dunst}/bin/dunstify \
      -u low \
      -a "NixOS Upgrade" \
      -i system-software-update \
      -h string:x-dunst-stack-tag:nixos-upgrade \
      "Checking for Updates..." \
      "Please wait..."
    
    # Trigger the check service and wait for it
    if ! systemctl start --wait nixos-check-updates.service 2>/dev/null; then
      # Fallback: try pkexec if systemd approach fails
      RESULT=$(${pkgs.polkit}/bin/pkexec /etc/nixos-auto-upgrade/check-updates.sh 2>&1) || {
        ${pkgs.dunst}/bin/dunstify \
          -u normal \
          -a "NixOS Upgrade" \
          -i dialog-error \
          -h string:x-dunst-stack-tag:nixos-upgrade \
          "Update Check Failed" \
          "Could not check for updates. Try: sudo systemctl start nixos-check-updates"
        exit 1
      }
    fi
    
    # Read result from state file
    RESULT=$(cat /var/lib/nixos-auto-upgrade/check-result 2>/dev/null || echo "CHECK-RESULT:error")
    
    if echo "$RESULT" | grep -q "CHECK-RESULT:no-updates"; then
      ${pkgs.dunst}/bin/dunstify \
        -u low \
        -a "NixOS Upgrade" \
        -i emblem-ok-symbolic \
        -h string:x-dunst-stack-tag:nixos-upgrade \
        "System Up to Date" \
        "No updates available."
    elif echo "$RESULT" | grep -q "CHECK-RESULT:updates-available"; then
      SUMMARY=$(echo "$RESULT" | grep "CHECK-SUMMARY:" | sed 's/.*CHECK-SUMMARY:\(.*\)---/\1/')
      
      # Use dunstify with actions - user can middle-click or use context menu
      ACTION=$(${pkgs.dunst}/bin/dunstify \
        -u normal \
        -a "NixOS Upgrade" \
        -i software-update-available \
        -h string:x-dunst-stack-tag:nixos-upgrade \
        -A "apply,Apply Updates" \
        -A "dismiss,Later" \
        --timeout=0 \
        "Updates Available" \
        "''${SUMMARY:-Updates are available}. Middle-click or press context key for actions.")
      
      if [[ "$ACTION" == "apply" ]]; then
        ${pkgs.dunst}/bin/dunstify \
          -u low \
          -a "NixOS Upgrade" \
          -i system-software-update \
          -h string:x-dunst-stack-tag:nixos-upgrade \
          "Applying Updates..." \
          "This may take several minutes."
        
        # Trigger the upgrade service
        systemctl start nixos-auto-upgrade.service 2>/dev/null || \
          ${pkgs.polkit}/bin/pkexec systemctl start nixos-auto-upgrade.service
      fi
    else
      ${pkgs.dunst}/bin/dunstify \
        -u normal \
        -a "NixOS Upgrade" \
        -i dialog-warning \
        -h string:x-dunst-stack-tag:nixos-upgrade \
        "Update Check" \
        "Could not determine update status. Check: journalctl -u nixos-check-updates"
    fi
  '';

  # Waybar-compatible script for status
  waybarStatusScript = pkgs.writeShellScriptBin "nixos-upgrade-waybar" ''
    STATE_DIR="${stateDir}"
    STATUS="idle"
    
    if [[ -f "$STATE_DIR/status" ]]; then
      STATUS=$(cat "$STATE_DIR/status")
    fi
    
    REBOOT_PENDING="no"
    if [[ -f "$STATE_DIR/reboot-pending" ]]; then
      REBOOT_PENDING=$(cat "$STATE_DIR/reboot-pending")
    fi
    
    # Check for check-result status
    CHECK_RESULT=""
    CHECK_SUMMARY=""
    if [[ -f "$STATE_DIR/check-result" ]]; then
      CHECK_RESULT=$(grep "CHECK-RESULT:" "$STATE_DIR/check-result" | sed 's/CHECK-RESULT://')
      CHECK_SUMMARY=$(grep "CHECK-SUMMARY:" "$STATE_DIR/check-result" | sed 's/CHECK-SUMMARY:\(.*\)---/\1/')
    fi
    
    # Output JSON for waybar
    if [[ "$STATUS" == "running" ]]; then
      echo '{"text": "⟳", "tooltip": "System upgrade in progress...", "class": "updating"}'
    elif [[ "$REBOOT_PENDING" == "yes" ]]; then
      SUMMARY=$(cat "$STATE_DIR/reboot-summary" 2>/dev/null | head -1 || echo "Updates installed")
      # Escape quotes in summary for JSON
      SUMMARY=$(echo "$SUMMARY" | sed 's/"/\\"/g')
      echo "{\"text\": \"⚠\", \"tooltip\": \"Reboot required: $SUMMARY\", \"class\": \"reboot-needed\"}"
    elif [[ "$CHECK_RESULT" == "updates-available" ]]; then
      # Updates available - show even if build failed (upstream issue)
      SUMMARY_ESC=$(echo "$CHECK_SUMMARY" | sed 's/"/\\"/g')
      if [[ "$STATUS" == "failed" ]]; then
        echo "{\"text\": \"↓!\", \"tooltip\": \"Updates available (build issues upstream): $SUMMARY_ESC\", \"class\": \"updates-available-issues\"}"
      else
        echo "{\"text\": \"↓\", \"tooltip\": \"Updates available: $SUMMARY_ESC\", \"class\": \"updates-available\"}"
      fi
    elif [[ "$CHECK_RESULT" == "no-updates" ]]; then
      echo '{"text": "✓", "tooltip": "System up to date (click to check for updates)", "class": "up-to-date"}'
    elif [[ "$STATUS" == "failed" ]] || [[ "$CHECK_RESULT" == "error" ]]; then
      echo '{"text": "✗", "tooltip": "Last operation failed - check logs", "class": "failed"}'
    else
      echo '{"text": "✓", "tooltip": "System up to date (click to check for updates)", "class": "up-to-date"}'
    fi
  '';

  # Script for waybar click action
  waybarClickScript = pkgs.writeShellScriptBin "nixos-upgrade-waybar-click" ''
    STATE_DIR="${stateDir}"
    
    REBOOT_PENDING="no"
    if [[ -f "$STATE_DIR/reboot-pending" ]]; then
      REBOOT_PENDING=$(cat "$STATE_DIR/reboot-pending")
    fi
    
    STATUS="idle"
    if [[ -f "$STATE_DIR/status" ]]; then
      STATUS=$(cat "$STATE_DIR/status")
    fi
    
    # Get check result for summary
    CHECK_SUMMARY=""
    if [[ -f "$STATE_DIR/check-result" ]]; then
      CHECK_SUMMARY=$(grep "CHECK-SUMMARY:" "$STATE_DIR/check-result" | sed 's/CHECK-SUMMARY:\(.*\)---/\1/')
    fi
    
    if [[ "$REBOOT_PENDING" == "yes" ]]; then
      # Show reboot prompt
      ${showRebootPromptScript}/bin/nixos-upgrade-reboot-prompt
    elif [[ "$STATUS" == "updates-available" ]]; then
      # Updates are available - prompt to install using dunstify
      ACTION=$(${pkgs.dunst}/bin/dunstify \
        -u normal \
        -a "NixOS Upgrade" \
        -i software-update-available \
        -h string:x-dunst-stack-tag:nixos-upgrade-prompt \
        -A "apply,Apply Updates" \
        -A "check,Re-check" \
        -A "dismiss,Later" \
        --timeout=0 \
        "Updates Available" \
        "''${CHECK_SUMMARY:-Updates ready to install}. Middle-click for actions.")
      
      case "$ACTION" in
        apply)
          ${pkgs.dunst}/bin/dunstify \
            -u low \
            -a "NixOS Upgrade" \
            -i system-software-update \
            -h string:x-dunst-stack-tag:nixos-upgrade \
            "Applying Updates..." \
            "This may take several minutes. You'll be notified when complete."
          
          # Trigger the upgrade service
          systemctl start nixos-auto-upgrade.service 2>/dev/null || \
            ${pkgs.polkit}/bin/pkexec systemctl start nixos-auto-upgrade.service
          ;;
        check)
          # Re-check for updates
          ${checkUpdatesScript}/bin/nixos-upgrade-check
          ;;
        *)
          # Dismissed or closed - do nothing
          ;;
      esac
    else
      # No updates pending - check for updates
      ${checkUpdatesScript}/bin/nixos-upgrade-check
    fi
  '';

in
{
  options.cg.home.auto-upgrade-desktop = {
    enable = lib.mkEnableOption "Desktop auto-upgrade features (notifications, waybar)";

    waybar = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable waybar integration";
      };

      position = lib.mkOption {
        type = lib.types.enum [ "left" "center" "right" ];
        default = "right";
        description = "Which waybar module section to add the update indicator to";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      getStatusScript
      getSummaryScript
      isSessionActiveScript
      showRebootPromptScript
      checkUpdatesScript
      waybarStatusScript
      waybarClickScript
      pkgs.polkit  # For pkexec
      pkgs.dunst   # For dunstify with action support
    ];

    # Waybar custom module configuration
    # Note: This creates a config snippet that should be merged with your waybar config
    xdg.configFile."waybar/nixos-upgrade.json" = lib.mkIf cfg.waybar.enable {
      text = builtins.toJSON {
        "custom/nixos-upgrade" = {
          exec = "${waybarStatusScript}/bin/nixos-upgrade-waybar";
          return-type = "json";
          interval = 30;
          on-click = "${waybarClickScript}/bin/nixos-upgrade-waybar-click";
          tooltip = true;
        };
      };
    };

    # CSS for waybar module
    xdg.configFile."waybar/nixos-upgrade.css".text = ''
      #custom-nixos-upgrade {
        padding: 0 10px;
        margin: 3px 0px;
        margin-top: 15px;
        border: 2px solid @pine;
        background: @base;
        opacity: 0.9;
      }

      #custom-nixos-upgrade.up-to-date {
        color: @foam;
      }

      #custom-nixos-upgrade.updates-available {
        color: @gold;
      }

      #custom-nixos-upgrade.updates-available-issues {
        color: @gold;
        background: @highlightMed;
      }

      #custom-nixos-upgrade.updating {
        color: @gold;
        animation: blink 1s linear infinite;
      }

      #custom-nixos-upgrade.reboot-needed {
        color: @love;
      }

      #custom-nixos-upgrade.failed {
        color: @love;
        background: @highlightMed;
      }

      @keyframes blink {
        50% { opacity: 0.5; }
      }
    '';

    # Systemd user service to show notification when upgrade completes
    systemd.user.services.nixos-upgrade-notify = {
      Unit = {
        Description = "Notify user of NixOS upgrade completion";
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "upgrade-notify-check" ''
          # Check if there's a pending reboot notification
          if [[ -f "${stateDir}/reboot-pending" ]] && [[ "$(cat ${stateDir}/reboot-pending)" == "yes" ]]; then
            ${showRebootPromptScript}/bin/nixos-upgrade-reboot-prompt
          fi
        ''}";
      };
    };

    # Path unit to trigger notification when upgrade status changes
    systemd.user.paths.nixos-upgrade-notify = {
      Unit = {
        Description = "Watch for NixOS upgrade status changes";
      };

      Path = {
        PathModified = "${stateDir}/reboot-pending";
        Unit = "nixos-upgrade-notify.service";
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
