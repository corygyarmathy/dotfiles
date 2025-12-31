# modules/nixos/auto-upgrade.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.auto-upgrade;

  # Custom upgrade script that includes diff in commit message
  upgradeScript = pkgs.writeShellScript "nixos-auto-upgrade" ''
    set -euo pipefail

    FLAKE_DIR="${cfg.flake}"
    HOSTNAME="${config.networking.hostName}"

    cd "$FLAKE_DIR"

    # Allow root to operate on user-owned repo (required for systemd service)
    ${pkgs.git}/bin/git config --global --add safe.directory "$FLAKE_DIR"

    # Ensure we're on a clean branch (or stash changes)
    if ! ${pkgs.git}/bin/git diff --quiet 2>/dev/null; then
      echo "Working directory not clean, stashing changes"
      ${pkgs.git}/bin/git stash push -m "auto-upgrade-stash-$(date +%Y%m%d-%H%M%S)"
      STASHED=1
    fi

    # Get current system for comparison
    CURRENT=$(readlink -f /run/current-system)

    # Update flake inputs
    echo "Updating flake inputs..."
    ${pkgs.nix}/bin/nix flake update nixpkgs

    # Check if lock file changed
    if ${pkgs.git}/bin/git diff --quiet flake.lock 2>/dev/null; then
      echo "No updates available"
      [ "''${STASHED:-}" = "1" ] && ${pkgs.git}/bin/git stash pop || true
      exit 0
    fi

    # Build new system to get diff
    echo "Building new system..."
    NEW=$(${pkgs.nix}/bin/nix build ".#nixosConfigurations.$HOSTNAME.config.system.build.toplevel" \
      --no-link --print-out-paths 2>/dev/null) || {
      echo "Build failed, reverting lock file"
      ${pkgs.git}/bin/git checkout flake.lock
      [ "''${STASHED:-}" = "1" ] && ${pkgs.git}/bin/git stash pop || true
      exit 1
    }

    # Generate diff
    echo "Generating package diff..."
    DIFF=$(${pkgs.nvd}/bin/nvd diff "$CURRENT" "$NEW" 2>/dev/null || echo "Could not generate diff")

    # Count changes for summary
    UPGRADED=$(echo "$DIFF" | grep -c "^\[U\]" || echo "0")
    ADDED=$(echo "$DIFF" | grep -c "^\[A\]" || echo "0")  
    REMOVED=$(echo "$DIFF" | grep -c "^\[R\]" || echo "0")

    # Check if kernel changed (indicates reboot needed)
    REBOOT_NEEDED=""
    if echo "$DIFF" | grep -q "linux.*->"; then
      REBOOT_NEEDED=" (reboot required)"
    fi

    # Create commit message
    COMMIT_MSG="chore(nix): update nixpkgs $REBOOT_NEEDED

    Auto-upgrade: $UPGRADED updated, $ADDED added, $REMOVED removed

    $DIFF

    Generated: $(date -Iseconds)"
        
    # Commit the lock file
    ${pkgs.git}/bin/git add flake.lock
    ${pkgs.git}/bin/git commit -m "$COMMIT_MSG"

    # Apply the upgrade
    echo "Applying upgrade..."
    ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --flake ".#$HOSTNAME"

    # Push if enabled option is configured
    ${lib.optionalString cfg.autoPush ''
      if ${pkgs.git}/bin/git remote get-url origin &>/dev/null; then
        echo "Pushing to remote..."
        ${pkgs.git}/bin/git push || echo "Push failed - manual push required"
      fi
    ''}

    # Restore stashed changes if any
    [ "''${STASHED:-}" = "1" ] && ${pkgs.git}/bin/git stash pop || true

    echo "Upgrade complete!"
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

    rebootWindow = {
      lower = lib.mkOption {
        type = lib.types.str;
        default = "03:00";
        description = "Start of reboot window (HH:MM)";
      };
      upper = lib.mkOption {
        type = lib.types.str;
        default = "05:00";
        description = "End of reboot window (HH:MM)";
      };
    };

    autoPush = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Automatically push commits to remote";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.nvd ];

    systemd = {
      # Custom upgrade service (replaces system.autoUpgrade)
      services.nixos-auto-upgrade = {
        description = "NixOS auto-upgrade with detailed commit messages";

        restartIfChanged = false;
        unitConfig.X-StopOnRemoval = false;

        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "30min";
        };

        environment = {
          HOME = "/root";
          GIT_AUTHOR_NAME = "NixOS Auto-Upgrade";
          GIT_AUTHOR_EMAIL = "auto-upgrade@xps15.local";
          GIT_COMMITTER_NAME = "NixOS Auto-Upgrade";
          GIT_COMMITTER_EMAIL = "auto-upgrade@xps15.local";
        };

        path = [
          pkgs.nix
          pkgs.git
          pkgs.nvd
          pkgs.nixos-rebuild
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gawk
        ];

        script = ''
          ${upgradeScript}
        '';

        # Handle reboot if needed
        postStart = ''
          # Check if reboot is needed and we're in the window
          CURRENT_HOUR=$(date +%H:%M)
          LOWER="${cfg.rebootWindow.lower}"
          UPPER="${cfg.rebootWindow.upper}"

          if ${pkgs.nix}/bin/nix-store --query --requisites /run/current-system \
             | grep -q "linux-[0-9]"; then
            # Check if booted kernel matches current
            BOOTED=$(readlink /run/booted-system/kernel)
            CURRENT=$(readlink /run/current-system/kernel)
            
            if [ "$BOOTED" != "$CURRENT" ]; then
              if [[ "$CURRENT_HOUR" > "$LOWER" && "$CURRENT_HOUR" < "$UPPER" ]]; then
                echo "Kernel updated and within reboot window, scheduling reboot"
                ${pkgs.systemd}/bin/shutdown -r +1 "NixOS auto-upgrade: kernel updated"
              else
                echo "Kernel updated but outside reboot window ($LOWER-$UPPER)"
              fi
            fi
          fi
        '';
      };

      # Timer for the upgrade
      timers.nixos-auto-upgrade = {
        description = "Timer for NixOS auto-upgrade";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.dates;
          RandomizedDelaySec = cfg.randomizedDelaySec;
          Persistent = true; # Run if missed (e.g., laptop was asleep)
          Unit = "nixos-auto-upgrade.service";
        };
      };

      # Notification service
      services.nixos-upgrade-notify = {
        description = "Notify user of NixOS upgrade result";
        after = [ "nixos-auto-upgrade.service" ];
        wantedBy = [ "nixos-auto-upgrade.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "coryg";
        };
        environment = {
          DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
        };
        script = ''
          if systemctl is-failed nixos-auto-upgrade.service 2>/dev/null; then
            ${pkgs.libnotify}/bin/notify-send -u critical \
              "NixOS Upgrade Failed" \
              "Check: journalctl -u nixos-auto-upgrade" || true
          else
            # Get summary from latest commit
            cd ${cfg.flake}
            SUMMARY=$(${pkgs.git}/bin/git log -1 --pretty=format:"%s" 2>/dev/null || echo "Update complete")
            ${pkgs.libnotify}/bin/notify-send \
              "NixOS Upgrade Complete" \
              "$SUMMARY" || true
          fi
        '';
      };
    };
  };
}
