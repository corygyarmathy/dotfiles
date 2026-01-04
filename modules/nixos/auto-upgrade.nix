# modules/nixos/auto-upgrade.nix
#
# Unified auto-upgrade module for NixOS.
#
# Features:
# - Automatic flake updates and system rebuilds
# - Firmware updates via fwupd
# - Low-priority background builds
# - Server mode (auto-reboot) vs Desktop mode (notification-based)
# - Git commit integration with detailed changelogs
#
# For desktop-specific features (waybar, notifications), see:
# modules/home/desktop/auto-upgrade-desktop.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.auto-upgrade;
  stateDir = "/var/lib/nixos-auto-upgrade";

  # Import the upgrade scripts package
  upgradeScripts = pkgs.callPackage ../../packages/nixos-upgrade-scripts { };

in
{
  options.cg.auto-upgrade = {
    enable = lib.mkEnableOption "Automatic system upgrades";

    mode = lib.mkOption {
      type = lib.types.enum [
        "desktop"
        "server"
      ];
      default = "desktop";
      description = ''
        Operating mode:
        - desktop: Never auto-reboot, rely on user interaction via waybar/notifications
        - server: Auto-reboot during maintenance window if kernel/firmware updated
      '';
    };

    flake = lib.mkOption {
      type = lib.types.str;
      default = "/home/coryg/git/dotfiles";
      description = "Path to flake directory";
    };

    schedule = {
      check = lib.mkOption {
        type = lib.types.str;
        default = "04:00";
        description = "When to check for updates (systemd calendar format)";
      };

      randomizedDelay = lib.mkOption {
        type = lib.types.str;
        default = "30min";
        description = "Random delay to add to scheduled time";
      };
    };

    backgroundBuild = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable low-priority background builds after detecting updates";
      };

      nice = lib.mkOption {
        type = lib.types.int;
        default = 19;
        description = "Nice level for background builds (0-19, higher = lower priority)";
      };

      ionice = lib.mkOption {
        type = lib.types.enum [
          "idle"
          "best-effort"
          "realtime"
        ];
        default = "idle";
        description = "IO scheduling class for background builds";
      };
    };

    firmware = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Include firmware updates via fwupd";
      };
    };

    git = {
      autoPush = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Automatically push commits to remote after upgrade";
      };
    };

    server = {
      rebootWindow = {
        start = lib.mkOption {
          type = lib.types.str;
          default = "03:00";
          description = "Start of reboot window (HH:MM) - server mode only";
        };

        end = lib.mkOption {
          type = lib.types.str;
          default = "05:00";
          description = "End of reboot window (HH:MM) - server mode only";
        };
      };
    };

    catchup = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run upgrade check on boot/resume if scheduled time was missed";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure state directory exists with proper permissions
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ];

    # Install the upgrade scripts
    environment.systemPackages = [
      upgradeScripts
      pkgs.nvd
      pkgs.procps
    ]
    ++ lib.optionals cfg.firmware.enable [
      pkgs.fwupd
    ];

    # Enable fwupd if firmware updates are enabled
    services.fwupd.enable = lib.mkIf cfg.firmware.enable true;

    # =========================================================================
    # Check Service - Checks for available updates
    # =========================================================================
    systemd.services.nixos-upgrade-check = {
      description = "Check for NixOS updates";

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "15min";
      };

      environment = {
        HOME = "/root";
      };

      script = ''
        ${upgradeScripts}/bin/nixos-upgrade-check \
          --flake-dir "${cfg.flake}" \
          --hostname "${config.networking.hostName}" \
          ${lib.optionalString cfg.firmware.enable "--check-firmware"}
      '';
    };

    # =========================================================================
    # Build Service - Low-priority background build
    # =========================================================================
    systemd.services.nixos-upgrade-build = lib.mkIf cfg.backgroundBuild.enable {
      description = "Background build for NixOS updates";

      # Start after check completes
      after = [ "nixos-upgrade-check.service" ];

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "4h"; # Background builds can take a while
      };

      environment = {
        HOME = "/root";
      };

      script = ''
        ${upgradeScripts}/bin/nixos-upgrade-build \
          --flake-dir "${cfg.flake}" \
          --hostname "${config.networking.hostName}" \
          --nice ${toString cfg.backgroundBuild.nice} \
          --ionice ${cfg.backgroundBuild.ionice}
      '';
    };

    # =========================================================================
    # Apply Service - Applies updates
    # =========================================================================
    systemd.services.nixos-upgrade-apply = {
      description = "Apply NixOS updates";

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "1h";
      };

      environment = {
        HOME = "/root";
        GIT_AUTHOR_NAME = "NixOS Auto-Upgrade";
        GIT_AUTHOR_EMAIL = "auto-upgrade@${config.networking.hostName}.local";
        GIT_COMMITTER_NAME = "NixOS Auto-Upgrade";
        GIT_COMMITTER_EMAIL = "auto-upgrade@${config.networking.hostName}.local";
      };

      script = ''
        ${upgradeScripts}/bin/nixos-upgrade-apply \
          --flake-dir "${cfg.flake}" \
          --hostname "${config.networking.hostName}" \
          --mode "${cfg.mode}" \
          ${lib.optionalString cfg.firmware.enable "--apply-firmware"} \
          ${lib.optionalString cfg.git.autoPush "--auto-push"} \
          ${lib.optionalString (cfg.mode == "server") "--auto-reboot"}
      '';
    };

    # =========================================================================
    # Timer - Scheduled checks
    # =========================================================================
    systemd.timers.nixos-upgrade-check = {
      description = "Timer for NixOS update checks";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.schedule.check;
        RandomizedDelaySec = cfg.schedule.randomizedDelay;
        Persistent = true; # Run if missed
        Unit = "nixos-upgrade-check.service";
      };
    };

    # =========================================================================
    # Background Build Timer - Starts after check
    # =========================================================================
    systemd.paths.nixos-upgrade-build-trigger = lib.mkIf cfg.backgroundBuild.enable {
      description = "Trigger background build when updates detected";
      wantedBy = [ "multi-user.target" ];

      pathConfig = {
        PathModified = "${stateDir}/state.json";
        Unit = "nixos-upgrade-build-check.service";
      };
    };

    # Helper service to check if build should start
    systemd.services.nixos-upgrade-build-check = lib.mkIf cfg.backgroundBuild.enable {
      description = "Check if background build should start";

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        # Only start build if state shows updates available and not already building
        if [[ -f "${stateDir}/state.json" ]]; then
          STATUS=$(${pkgs.jq}/bin/jq -r '.status' "${stateDir}/state.json" 2>/dev/null || echo "unknown")
          HAS_NIX=$(${pkgs.jq}/bin/jq -r '.pending_nix != null and .pending_nix.count > 0' "${stateDir}/state.json" 2>/dev/null || echo "false")
          BUILD_COMPLETE=$(${pkgs.jq}/bin/jq -r '.build_complete' "${stateDir}/state.json" 2>/dev/null || echo "false")

          if [[ "$STATUS" == "idle" ]] && [[ "$HAS_NIX" == "true" ]] && [[ "$BUILD_COMPLETE" != "true" ]]; then
            echo "Updates detected, starting background build..."
            systemctl start nixos-upgrade-build.service --no-block
          else
            echo "No build needed (status=$STATUS, has_nix=$HAS_NIX, build_complete=$BUILD_COMPLETE)"
          fi
        fi
      '';
    };

    # =========================================================================
    # Catchup Services - Run on boot/resume if check was missed
    # =========================================================================
    systemd.services.nixos-upgrade-catchup = lib.mkIf cfg.catchup.enable {
      description = "NixOS upgrade catchup (if scheduled check was missed)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        # Check if we missed the scheduled time
        LAST_CHECK=""
        if [[ -f "${stateDir}/state.json" ]]; then
          LAST_CHECK=$(${pkgs.jq}/bin/jq -r '.last_check // empty' "${stateDir}/state.json" 2>/dev/null || echo "")
        fi

        # If no last check or it was more than 24 hours ago, run check
        if [[ -z "$LAST_CHECK" ]]; then
          echo "No previous check recorded, triggering check..."
          systemctl start nixos-upgrade-check.service --no-block
        else
          LAST_CHECK_EPOCH=$(date -d "$LAST_CHECK" +%s 2>/dev/null || echo 0)
          NOW_EPOCH=$(date +%s)
          AGE=$((NOW_EPOCH - LAST_CHECK_EPOCH))

          # 24 hours in seconds
          if [[ $AGE -gt 86400 ]]; then
            echo "Last check was $(($AGE / 3600)) hours ago, triggering check..."
            systemctl start nixos-upgrade-check.service --no-block
          else
            echo "Last check was recent ($(($AGE / 3600)) hours ago), skipping"
          fi
        fi
      '';
    };

    # Also check on resume from suspend
    systemd.services.nixos-upgrade-resume = lib.mkIf cfg.catchup.enable {
      description = "Check for missed upgrades on resume";
      wantedBy = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];
      after = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
      ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        # Small delay to let network come up
        sleep 15
        systemctl start nixos-upgrade-catchup.service --no-block
      '';
    };

    # =========================================================================
    # Polkit Rules - Allow wheel group to manage upgrade services
    # =========================================================================
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units") {
          var unit = action.lookup("unit");
          if ((unit == "nixos-upgrade-check.service" ||
               unit == "nixos-upgrade-build.service" ||
               unit == "nixos-upgrade-apply.service") &&
              subject.isInGroup("wheel")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    # =========================================================================
    # Notification Service - For completed upgrades (server mode)
    # =========================================================================
    systemd.services.nixos-upgrade-notify = lib.mkIf (cfg.mode == "server") {
      description = "Notify about completed NixOS upgrade";
      after = [ "nixos-upgrade-apply.service" ];
      wantedBy = [ "nixos-upgrade-apply.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        # Log completion for server monitoring
        if [[ -f "${stateDir}/state.json" ]]; then
          STATUS=$(${pkgs.jq}/bin/jq -r '.status' "${stateDir}/state.json" 2>/dev/null || echo "unknown")
          ERROR=$(${pkgs.jq}/bin/jq -r '.error_message // empty' "${stateDir}/state.json" 2>/dev/null || echo "")

          if [[ "$STATUS" == "error" ]]; then
            echo "NixOS upgrade failed: $ERROR"
            # Could integrate with monitoring here (e.g., send to Prometheus, email, etc.)
          else
            echo "NixOS upgrade completed successfully"
          fi
        fi
      '';
    };
  };
}
