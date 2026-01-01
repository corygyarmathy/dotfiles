# modules/nixos/auto-upgrade.nix
#
# Base auto-upgrade module for NixOS.
# Handles flake updates, system rebuilds, and optional firmware updates.
# For desktop interactive features, see: modules/home/desktop/auto-upgrade-desktop.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.auto-upgrade;
  stateDir = "/var/lib/nixos-auto-upgrade";

  # Script to check if upgrade is needed (ran within window or recently)
  checkUpgradeNeeded = pkgs.writeShellScript "check-upgrade-needed" ''
    set -euo pipefail

    STATE_FILE="${stateDir}/last-upgrade"
    WINDOW_END_HOUR=${toString cfg.window.endHour}
    WINDOW_END_MIN=${toString cfg.window.endMinute}

    # If state file doesn't exist, upgrade is needed
    if [[ ! -f "$STATE_FILE" ]]; then
      echo "needed"
      exit 0
    fi

    LAST_UPGRADE=$(cat "$STATE_FILE")
    NOW=$(date +%s)

    # Calculate today's window end time
    TODAY_WINDOW_END=$(date -d "today $WINDOW_END_HOUR:$WINDOW_END_MIN" +%s)

    # If current time is before today's window end, use yesterday's window end
    if [[ $NOW -lt $TODAY_WINDOW_END ]]; then
      WINDOW_END=$(date -d "yesterday $WINDOW_END_HOUR:$WINDOW_END_MIN" +%s)
    else
      WINDOW_END=$TODAY_WINDOW_END
    fi

    # If last upgrade was before the window end, upgrade is needed
    if [[ $LAST_UPGRADE -lt $WINDOW_END ]]; then
      echo "needed"
    else
      echo "current"
    fi
  '';

  # Script to record successful upgrade
  recordUpgrade = pkgs.writeShellScript "record-upgrade" ''
    mkdir -p "${stateDir}"
    date +%s > "${stateDir}/last-upgrade"
  '';

  # Script to set/clear reboot pending flag
  setRebootPending = pkgs.writeShellScript "set-reboot-pending" ''
    mkdir -p "${stateDir}"
    echo "$1" > "${stateDir}/reboot-pending"
    # Also store the summary
    if [[ -n "''${2:-}" ]]; then
      echo "$2" > "${stateDir}/reboot-summary"
    fi
  '';

  # Main upgrade script
  upgradeScript = pkgs.writeShellScript "nixos-auto-upgrade" ''
    set -euo pipefail

    FLAKE_DIR="${cfg.flake}"
    HOSTNAME="${config.networking.hostName}"

    # Get the owner of the flake directory for permission handling
    FLAKE_OWNER=$(stat -c '%U' "$FLAKE_DIR")
    FLAKE_GROUP=$(stat -c '%G' "$FLAKE_DIR")

    # Signal that upgrade is in progress
    mkdir -p "${stateDir}"
    echo "running" > "${stateDir}/status"

    cleanup() {
      if [[ -f "${stateDir}/status" ]] && [[ "$(cat ${stateDir}/status)" == "running" ]]; then
        echo "idle" > "${stateDir}/status"
      fi
    }
    trap cleanup EXIT

    cd "$FLAKE_DIR"

    # Allow root to operate on user-owned repo
    ${pkgs.git}/bin/git config --global --add safe.directory "$FLAKE_DIR" 2>/dev/null || true

    # Fix ownership of flake.lock if it got changed to root
    if [[ -f flake.lock ]]; then
      chown "$FLAKE_OWNER:$FLAKE_GROUP" flake.lock 2>/dev/null || true
    fi

    # Stash any local changes (as the flake owner)
    STASHED=""
    if ! ${pkgs.git}/bin/git diff --quiet 2>/dev/null; then
      echo "Working directory not clean, stashing changes"
      ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git stash push -m "auto-upgrade-stash-$(date +%Y%m%d-%H%M%S)"
      STASHED=1
    fi

    restore_stash() {
      if [[ -n "$STASHED" ]]; then
        ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git stash pop || true
      fi
    }

    # Get current system for comparison
    CURRENT=$(readlink -f /run/current-system)

    # Update flake inputs (as the flake owner to avoid permission issues)
    echo "Updating flake inputs..."
    if ! ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.nix}/bin/nix flake update 2>&1; then
      echo "Flake update failed"
      restore_stash
      echo "failed" > "${stateDir}/status"
      exit 1
    fi

    # Check if lock file changed
    if ${pkgs.git}/bin/git diff --quiet flake.lock 2>/dev/null; then
      echo "No updates available"
      restore_stash
      ${recordUpgrade}
      echo "idle" > "${stateDir}/status"
      exit 0
    fi

    # Build new system
    echo "Building new system..."
    NEW=$(${pkgs.nix}/bin/nix build ".#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" \
      --no-link --print-out-paths 2>&1) || {
      echo "Build failed, reverting lock file"
      ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git checkout flake.lock
      restore_stash
      echo "failed" > "${stateDir}/status"
      exit 1
    }

    # Generate diff
    echo "Generating package diff..."
    DIFF=$(${pkgs.nvd}/bin/nvd diff "$CURRENT" "$NEW" 2>/dev/null || echo "Could not generate diff")

    # Count changes
    UPGRADED=$(echo "$DIFF" | grep -c "^\[U\]" || echo "0")
    ADDED=$(echo "$DIFF" | grep -c "^\[A\]" || echo "0")
    REMOVED=$(echo "$DIFF" | grep -c "^\[R\]" || echo "0")

    # Check for notable changes
    KERNEL_CHANGED=""
    if echo "$DIFF" | grep -qE "linux-[0-9].*->"; then
      KERNEL_CHANGED="yes"
    fi

    FIRMWARE_CHANGED=""
    if echo "$DIFF" | grep -qiE "(firmware|fwupd).*->"; then
      FIRMWARE_CHANGED="yes"
    fi

    # Generate summaries at different detail levels
    SUMMARY_MINIMAL="$UPGRADED updated, $ADDED added, $REMOVED removed"
    if [[ -n "$KERNEL_CHANGED" ]]; then
      SUMMARY_MINIMAL="$SUMMARY_MINIMAL (kernel updated)"
    fi

    # Notable packages for moderate summary
    NOTABLE=$(echo "$DIFF" | grep -E "^\[U\]" | grep -iE "(linux|systemd|openssl|openssh|sudo|polkit|kernel|firmware|glibc)" | head -10 || true)
    SUMMARY_MODERATE="$SUMMARY_MINIMAL"
    if [[ -n "$NOTABLE" ]]; then
      SUMMARY_MODERATE="$SUMMARY_MODERATE

      Notable updates:
      $NOTABLE"
    fi

    SUMMARY_FULL="$SUMMARY_MINIMAL

    $DIFF"

    # Determine which summary to use based on config
    case "${cfg.summaryLevel}" in
      minimal)  SUMMARY="$SUMMARY_MINIMAL" ;;
      moderate) SUMMARY="$SUMMARY_MODERATE" ;;
      full)     SUMMARY="$SUMMARY_FULL" ;;
      *)        SUMMARY="$SUMMARY_MODERATE" ;;
    esac

    ${lib.optionalString cfg.firmware.enable ''
            # Check for firmware updates
            echo "Checking for firmware updates..."
            FWUPD_UPDATES=$(${pkgs.fwupd}/bin/fwupdmgr get-updates 2>&1 || true)
            if echo "$FWUPD_UPDATES" | grep -q "has no available firmware updates"; then
              echo "No firmware updates available"
            elif echo "$FWUPD_UPDATES" | grep -qE "^[A-Za-z].*:$"; then
              echo "Firmware updates available, applying..."
              # Apply firmware updates (they'll be staged for next boot)
              ${pkgs.fwupd}/bin/fwupdmgr update --no-reboot -y 2>&1 || true
              FIRMWARE_CHANGED="yes"
              SUMMARY="$SUMMARY

      Firmware updates applied (will take effect after reboot)"
            fi
    ''}

    # Create commit message
    REBOOT_NOTE=""
    if [[ -n "$KERNEL_CHANGED" ]] || [[ -n "$FIRMWARE_CHANGED" ]]; then
      REBOOT_NOTE=" (reboot required)"
    fi

    COMMIT_MSG="chore(nix): auto-upgrade$REBOOT_NOTE

    $SUMMARY_MINIMAL

    $DIFF

    Generated: $(date -Iseconds)"

    # Commit the lock file (as the flake owner)
    ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git add flake.lock
    ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git commit -m "$COMMIT_MSG"

    # Apply the upgrade
    echo "Applying upgrade..."
    ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake ".#$HOSTNAME"

    ${lib.optionalString cfg.autoPush ''
      if ${pkgs.git}/bin/git remote get-url origin &>/dev/null; then
        echo "Pushing to remote..."
        ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git push || echo "Push failed - manual push required"
      fi
    ''}

    restore_stash

    # Record successful upgrade
    ${recordUpgrade}

    # Check if reboot is needed
    REBOOT_NEEDED=""
    BOOTED_KERNEL=$(readlink /run/booted-system/kernel 2>/dev/null || echo "")
    CURRENT_KERNEL=$(readlink /run/current-system/kernel 2>/dev/null || echo "")

    if [[ -n "$BOOTED_KERNEL" ]] && [[ -n "$CURRENT_KERNEL" ]] && [[ "$BOOTED_KERNEL" != "$CURRENT_KERNEL" ]]; then
      REBOOT_NEEDED="yes"
    fi

    if [[ -n "$FIRMWARE_CHANGED" ]]; then
      REBOOT_NEEDED="yes"
    fi

    if [[ -n "$REBOOT_NEEDED" ]]; then
      ${setRebootPending} "yes" "$SUMMARY"
      echo "reboot-pending" > "${stateDir}/status"
    else
      ${setRebootPending} "no" ""
      echo "idle" > "${stateDir}/status"
    fi

    echo "Upgrade complete!"

    # Output summary for notification systems to capture
    echo "---UPGRADE-SUMMARY-START---"
    echo "$SUMMARY"
    echo "---UPGRADE-SUMMARY-END---"
    echo "---REBOOT-NEEDED:$REBOOT_NEEDED---"
  '';

  # Script to just check for updates (no apply)
  checkUpdatesScript = pkgs.writeShellScript "nixos-check-updates" ''
    set -euo pipefail

    FLAKE_DIR="${cfg.flake}"
    HOSTNAME="${config.networking.hostName}"

    cd "$FLAKE_DIR"

    # Allow root to operate on user-owned repo
    ${pkgs.git}/bin/git config --global --add safe.directory "$FLAKE_DIR" 2>/dev/null || true

    # Copy flake.lock to temp location
    TEMP_DIR=$(mktemp -d)
    cp flake.lock "$TEMP_DIR/flake.lock.backup"

    cleanup() {
      cp "$TEMP_DIR/flake.lock.backup" flake.lock
      rm -rf "$TEMP_DIR"
    }
    trap cleanup EXIT

    # Update flake inputs (dry run effectively)
    ${pkgs.nix}/bin/nix flake update 2>&1 || exit 1

    # Check if lock file changed
    if ${pkgs.git}/bin/git diff --quiet flake.lock 2>/dev/null; then
      echo "---CHECK-RESULT:no-updates---"
      exit 0
    fi

    # Get current system
    CURRENT=$(readlink -f /run/current-system)

    # Build to check what would change (eval only for speed if possible)
    echo "Evaluating changes..."
    NEW=$(${pkgs.nix}/bin/nix build ".#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" \
      --no-link --print-out-paths --dry-run 2>&1 | tail -1) || {
      # If dry-run doesn't give us a path, do a real build
      NEW=$(${pkgs.nix}/bin/nix build ".#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" \
        --no-link --print-out-paths 2>&1) || {
        echo "---CHECK-RESULT:error---"
        exit 1
      }
    }

    if [[ -n "$NEW" ]] && [[ -d "$NEW" ]]; then
      DIFF=$(${pkgs.nvd}/bin/nvd diff "$CURRENT" "$NEW" 2>/dev/null || echo "Could not generate diff")
      UPGRADED=$(echo "$DIFF" | grep -c "^\[U\]" || echo "0")
      ADDED=$(echo "$DIFF" | grep -c "^\[A\]" || echo "0")
      REMOVED=$(echo "$DIFF" | grep -c "^\[R\]" || echo "0")
      
      echo "---CHECK-RESULT:updates-available---"
      echo "---CHECK-SUMMARY:$UPGRADED updated, $ADDED added, $REMOVED removed---"
    else
      echo "---CHECK-RESULT:updates-available---"
      echo "---CHECK-SUMMARY:Updates available (details pending build)---"
    fi
  '';

in
{
  options.cg.auto-upgrade = {
    enable = lib.mkEnableOption "Automatic system upgrades";

    flake = lib.mkOption {
      type = lib.types.str;
      default = "/home/coryg/git/dotfiles";
      description = "Path to flake directory";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "04:00";
      description = "When to run upgrades (systemd calendar format)";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "45min";
      description = "Random delay to add to scheduled time";
    };

    window = {
      startHour = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = "Start hour of upgrade window (0-23)";
      };
      startMinute = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "Start minute of upgrade window";
      };
      endHour = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "End hour of upgrade window (0-23)";
      };
      endMinute = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "End minute of upgrade window";
      };
    };

    autoPush = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Automatically push commits to remote";
    };

    summaryLevel = lib.mkOption {
      type = lib.types.enum [
        "minimal"
        "moderate"
        "full"
      ];
      default = "moderate";
      description = ''
        Level of detail in upgrade summaries:
        - minimal: Just counts (e.g., "5 updated, 2 added")
        - moderate: Counts plus notable packages (kernel, security, etc.)
        - full: Complete nvd diff output
      '';
    };

    firmware = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include firmware updates via fwupd";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure state directory exists
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ];

    environment.systemPackages =
      with pkgs;
      [
        nvd
        procps # For pgrep in session detection
      ]
      ++ lib.optionals cfg.firmware.enable [
        fwupd
      ];

    # Enable fwupd service if firmware updates are enabled
    services.fwupd.enable = lib.mkIf cfg.firmware.enable true;

    # Main upgrade service
    systemd.services.nixos-auto-upgrade = {
      description = "NixOS auto-upgrade";
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "30min";
      };

      environment = {
        HOME = "/root";
        GIT_AUTHOR_NAME = "NixOS Auto-Upgrade";
        GIT_AUTHOR_EMAIL = "auto-upgrade@${config.networking.hostName}.local";
        GIT_COMMITTER_NAME = "NixOS Auto-Upgrade";
        GIT_COMMITTER_EMAIL = "auto-upgrade@${config.networking.hostName}.local";
      };

      path =
        with pkgs;
        [
          nix
          git
          nvd
          nixos-rebuild
          coreutils
          gnugrep
          gawk
          systemd
          sudo
        ]
        ++ lib.optionals cfg.firmware.enable [ fwupd ];

      script = ''
        ${upgradeScript}
      '';
    };

    # Timer for scheduled upgrades
    systemd.timers.nixos-auto-upgrade = {
      description = "Timer for NixOS auto-upgrade";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        Persistent = true;
        Unit = "nixos-auto-upgrade.service";
      };
    };

    # Service to run upgrade if missed (triggered on boot/resume)
    systemd.services.nixos-auto-upgrade-catchup = {
      description = "NixOS auto-upgrade catchup (if scheduled upgrade was missed)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = with pkgs; [
        coreutils
        gnugrep
      ];

      script = ''
        # Check if upgrade is needed
        RESULT=$(${checkUpgradeNeeded})

        if [[ "$RESULT" == "needed" ]]; then
          echo "Upgrade missed, triggering catchup..."
          systemctl start nixos-auto-upgrade.service --no-block
        else
          echo "System is up to date"
        fi
      '';
    };

    # Also trigger catchup on resume from suspend
    systemd.services.nixos-auto-upgrade-resume = {
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
        sleep 10
        systemctl start nixos-auto-upgrade-catchup.service --no-block
      '';
    };

    # Service to handle auto-reboot decision after upgrade
    systemd.services.nixos-auto-upgrade-reboot = {
      description = "Auto-reboot if needed and no graphical session active";
      after = [ "nixos-auto-upgrade.service" ];
      wantedBy = [ "nixos-auto-upgrade.service" ];

      serviceConfig = {
        Type = "oneshot";
      };

      script = ''
        # Check if reboot is needed
        if [[ ! -f "${stateDir}/reboot-pending" ]] || [[ "$(cat ${stateDir}/reboot-pending)" != "yes" ]]; then
          echo "No reboot needed"
          exit 0
        fi

        # Check if any graphical session is active
        SESSION_ACTIVE="no"

        # Check for common compositors
        if ${pkgs.procps}/bin/pgrep -x "Hyprland" > /dev/null 2>&1; then
          SESSION_ACTIVE="yes"
        elif ${pkgs.procps}/bin/pgrep -x "gnome-shell" > /dev/null 2>&1; then
          SESSION_ACTIVE="yes"
        elif ${pkgs.procps}/bin/pgrep -x "kwin_wayland" > /dev/null 2>&1; then
          SESSION_ACTIVE="yes"
        elif ${pkgs.procps}/bin/pgrep -x "sway" > /dev/null 2>&1; then
          SESSION_ACTIVE="yes"
        fi

        # Also check loginctl for graphical sessions
        if ${pkgs.systemd}/bin/loginctl list-sessions --no-legend 2>/dev/null | grep -qE '(wayland|x11)'; then
          SESSION_ACTIVE="yes"
        fi

        if [[ "$SESSION_ACTIVE" == "yes" ]]; then
          echo "Graphical session active, skipping auto-reboot"
          echo "User will be prompted to reboot manually"
          exit 0
        fi

        echo "No graphical session active, rebooting..."
        ${pkgs.systemd}/bin/systemctl reboot
      '';
    };

    # Export scripts for use by other modules (like the desktop module)
    environment.etc."nixos-auto-upgrade/check-updates.sh" = {
      mode = "0755";
      source = checkUpdatesScript;
    };

    environment.etc."nixos-auto-upgrade/upgrade.sh" = {
      mode = "0755";
      source = upgradeScript;
    };

    # Service to check for updates (can be triggered by users via polkit)
    systemd.services.nixos-check-updates = {
      description = "Check for NixOS updates (no apply)";

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "10min";
      };

      environment = {
        HOME = "/root";
      };

      path =
        with pkgs;
        [
          nix
          git
          nvd
          coreutils
          gnugrep
          sudo
          jq
        ]
        ++ lib.optionals cfg.firmware.enable [ fwupd ];

      script = ''
        FLAKE_DIR="${cfg.flake}"
        HOSTNAME="${config.networking.hostName}"
        STATE_DIR="${stateDir}"

        mkdir -p "$STATE_DIR"

        # Clear previous status at start of check
        echo "checking" > "$STATE_DIR/status"

        # Get the owner of the flake directory
        FLAKE_OWNER=$(stat -c '%U' "$FLAKE_DIR")
        FLAKE_GROUP=$(stat -c '%G' "$FLAKE_DIR")

        cd "$FLAKE_DIR" || {
          echo "CHECK-RESULT:error" > "$STATE_DIR/check-result"
          echo "error" > "$STATE_DIR/status"
          echo "Failed to cd to $FLAKE_DIR"
          exit 1
        }

        ${pkgs.git}/bin/git config --global --add safe.directory "$FLAKE_DIR" 2>/dev/null || true

        # Fix ownership of flake.lock if it got changed to root
        if [[ -f flake.lock ]]; then
          chown "$FLAKE_OWNER:$FLAKE_GROUP" flake.lock 2>/dev/null || true
        fi

        # Ensure flake.lock is clean before we start
        ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git checkout flake.lock 2>/dev/null || true

        cleanup() {
          # Restore flake.lock to its original committed state using git
          cd "$FLAKE_DIR" 2>/dev/null || true
          ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.git}/bin/git checkout flake.lock 2>/dev/null || true
          chown "$FLAKE_OWNER:$FLAKE_GROUP" flake.lock 2>/dev/null || true
        }
        trap cleanup EXIT

        # Update flake inputs as the flake owner (to avoid permission issues)
        echo "Updating flake inputs..."
        if ! ${pkgs.sudo}/bin/sudo -u "$FLAKE_OWNER" ${pkgs.nix}/bin/nix flake update 2>&1; then
          echo "CHECK-RESULT:error" > "$STATE_DIR/check-result"
          echo "error" > "$STATE_DIR/status"
          echo "Flake update failed"
          exit 1
        fi

        # Check if lock file changed
        if ${pkgs.git}/bin/git diff --quiet flake.lock 2>/dev/null; then
          echo "CHECK-RESULT:no-updates" > "$STATE_DIR/check-result"
          echo "idle" > "$STATE_DIR/status"
          echo "No updates available"
          exit 0
        fi

        echo "Updates detected, building to check changes..."

        # Get current system
        CURRENT=$(readlink -f /run/current-system)
        echo "Current system: $CURRENT"

        # Try to build to see what would change
        # Build as root (needs privileges), but the flake is readable
        echo "Starting nix build..."
        BUILD_OUTPUT_FILE=$(mktemp)

        if ${pkgs.nix}/bin/nix build ".#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" \
          --no-link --print-out-paths > "$BUILD_OUTPUT_FILE" 2>&1; then
          BUILD_EXIT=0
        else
          BUILD_EXIT=$?
        fi

        BUILD_OUTPUT=$(cat "$BUILD_OUTPUT_FILE")
        rm -f "$BUILD_OUTPUT_FILE"

        echo "Build exit code: $BUILD_EXIT"
        echo "Build output:"
        echo "$BUILD_OUTPUT"
        echo "---"

        if [[ $BUILD_EXIT -ne 0 ]]; then
          echo -e "CHECK-RESULT:updates-available\nCHECK-SUMMARY:Updates available (build preview failed)---" > "$STATE_DIR/check-result"
          echo "failed" > "$STATE_DIR/status"
          echo "Build failed but updates are available"
          exit 0
        fi

        # Extract the store path (last line that looks like a store path)
        NEW=$(echo "$BUILD_OUTPUT" | grep "^/nix/store/" | tail -1)

        echo "New system path: $NEW"

        if [[ -n "$NEW" ]] && [[ -d "$NEW" ]]; then
          echo "Running nvd diff..."
          DIFF=$(${pkgs.nvd}/bin/nvd diff "$CURRENT" "$NEW" 2>&1) || true
          UPGRADED=$(echo "$DIFF" | grep -c "^\[U\]") || UPGRADED=0
          ADDED=$(echo "$DIFF" | grep -c "^\[A\]") || ADDED=0
          REMOVED=$(echo "$DIFF" | grep -c "^\[R\]") || REMOVED=0
          
          TOTAL=$((UPGRADED + ADDED + REMOVED))
          echo "Changes: $UPGRADED updated, $ADDED added, $REMOVED removed"
          
          # Check for firmware updates if enabled
          FIRMWARE_UPDATES=""
          ${lib.optionalString cfg.firmware.enable ''
            echo "Checking for firmware updates..."
            FIRMWARE_OUTPUT=$(${pkgs.fwupd}/bin/fwupdmgr get-updates --json 2>/dev/null || echo "{}")
            FIRMWARE_COUNT=$(echo "$FIRMWARE_OUTPUT" | ${pkgs.jq}/bin/jq '[.Devices[]? | select(.Releases != null)] | length' 2>/dev/null || echo "0")
            if [[ "$FIRMWARE_COUNT" -gt 0 ]]; then
              FIRMWARE_UPDATES=", $FIRMWARE_COUNT firmware"
              echo "Firmware updates available: $FIRMWARE_COUNT"
              # Save firmware details to state
              echo "$FIRMWARE_OUTPUT" > "$STATE_DIR/firmware-updates.json"
            else
              rm -f "$STATE_DIR/firmware-updates.json"
            fi
          ''}
          
          if [[ $TOTAL -eq 0 ]] && [[ -z "$FIRMWARE_UPDATES" ]]; then
            # Flake inputs changed but no package differences and no firmware updates
            echo "CHECK-RESULT:no-updates" > "$STATE_DIR/check-result"
            echo "idle" > "$STATE_DIR/status"
            echo "Flake inputs updated but no package changes"
          else
            echo -e "CHECK-RESULT:updates-available\nCHECK-SUMMARY:$UPGRADED updated, $ADDED added, $REMOVED removed$FIRMWARE_UPDATES---" > "$STATE_DIR/check-result"
            echo "updates-available" > "$STATE_DIR/status"
          fi
        else
          echo "Could not determine new system path, but updates are available"
          
          # Still check firmware even if nix build path unclear
          FIRMWARE_UPDATES=""
          ${lib.optionalString cfg.firmware.enable ''
            echo "Checking for firmware updates..."
            FIRMWARE_OUTPUT=$(${pkgs.fwupd}/bin/fwupdmgr get-updates --json 2>/dev/null || echo "{}")
            FIRMWARE_COUNT=$(echo "$FIRMWARE_OUTPUT" | ${pkgs.jq}/bin/jq '[.Devices[]? | select(.Releases != null)] | length' 2>/dev/null || echo "0")
            if [[ "$FIRMWARE_COUNT" -gt 0 ]]; then
              FIRMWARE_UPDATES=", $FIRMWARE_COUNT firmware"
              echo "Firmware updates available: $FIRMWARE_COUNT"
              echo "$FIRMWARE_OUTPUT" > "$STATE_DIR/firmware-updates.json"
            fi
          ''}
          
          echo -e "CHECK-RESULT:updates-available\nCHECK-SUMMARY:Updates available$FIRMWARE_UPDATES---" > "$STATE_DIR/check-result"
          echo "updates-available" > "$STATE_DIR/status"
        fi

        echo "Check complete"
        exit 0
      '';
    };

    # Allow users in wheel group to start the check-updates and auto-upgrade services
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units") {
          var unit = action.lookup("unit");
          if ((unit == "nixos-check-updates.service" || unit == "nixos-auto-upgrade.service") &&
              subject.isInGroup("wheel")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    environment.etc."nixos-auto-upgrade/state-dir".text = stateDir;
  };
}
