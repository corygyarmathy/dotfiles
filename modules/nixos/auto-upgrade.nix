# modules/nixos/auto-upgrade.nix
#
# Desktop upgrade module: build promoted updates in the background, show what
# is pending, and apply only when asked.
#
# Servers do not use this. They run stock `system.autoUpgrade` against a
# promoted ref and apply unattended (ADR 0001). A laptop should not switch
# generations under someone who is working, which is the only reason this
# module still exists.
#
# What it deliberately no longer does, compared to its previous form:
#
#   - update flake.lock          CI owns the lock now; this follows `deploy`
#   - commit anything to git     there is nothing local to commit
#   - keep a JSON state machine  systemd and the store already hold that state
#   - reboot on a schedule       that is a server behaviour
#   - catch up on resume         systemd timers with Persistent already do this
#
# The waybar front-end is packages/nixos-upgrade-scripts; the home-manager
# side is modules/home/desktop/auto-upgrade-desktop.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.auto-upgrade;

  stateDir = "/var/lib/nixos-upgrade";
  nextLink = "${stateDir}/next";

  flakeRef = "${cfg.flake}#nixosConfigurations.${config.networking.hostName}.config.system.build.toplevel";

  upgradeScripts = pkgs.callPackage ../../packages/nixos-upgrade-scripts { };
in
{
  options.cg.auto-upgrade = {
    enable = lib.mkEnableOption "Desktop upgrade indicator and on-demand apply";

    flake = lib.mkOption {
      type = lib.types.str;
      default = "github:corygyarmathy/dotfiles/deploy";
      description = ''
        Flake reference to follow, without the attribute. Defaults to the
        promoted `deploy` branch, so the desktop tracks exactly what CI has
        proven builds for every host.
      '';
    };

    schedule = {
      check = lib.mkOption {
        type = lib.types.str;
        default = "04:00";
        description = "When to build pending updates (systemd calendar format)";
      };

      randomizedDelay = lib.mkOption {
        type = lib.types.str;
        default = "30min";
        description = "Random delay added to the scheduled time";
      };
    };

    backgroundBuild = {
      nice = lib.mkOption {
        type = lib.types.int;
        default = 19;
        description = "Nice level for the background build (0-19, higher is lower priority)";
      };

      ionice = lib.mkOption {
        type = lib.types.enum [
          "idle"
          "best-effort"
          "realtime"
        ];
        default = "idle";
        description = "IO scheduling class for the background build";
      };
    };

    firmware.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include firmware updates via fwupd in the indicator and apply action";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      upgradeScripts
      pkgs.nvd # for inspecting a diff by hand
    ]
    ++ lib.optional cfg.firmware.enable pkgs.fwupd;

    services.fwupd.enable = lib.mkIf cfg.firmware.enable true;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
    ];

    # =========================================================================
    # Build - fetch the promoted revision and build it, without activating
    # =========================================================================
    systemd.services.nixos-upgrade-build = {
      description = "Build the promoted NixOS configuration";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "4h";
        Nice = cfg.backgroundBuild.nice;
        IOSchedulingClass = cfg.backgroundBuild.ionice;
      };

      path = [
        pkgs.nix
        pkgs.git
      ];
      environment.HOME = "/root";

      script = ''
        # --refresh, or the flake evaluation cache pins `deploy` to whatever it
        # resolved to last time and the build silently never sees a new
        # revision.
        #
        # --out-link doubles as a GC root, so the built system survives until
        # the next build replaces it - otherwise `nix-collect-garbage` between
        # the nightly build and the user clicking apply would throw the work
        # away and leave the indicator pointing at nothing.
        nix build --refresh --print-build-logs \
          "${flakeRef}" \
          --out-link "${nextLink}"
      '';
    };

    systemd.timers.nixos-upgrade-build = {
      description = "Timer for building promoted NixOS updates";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule.check;
        RandomizedDelaySec = cfg.schedule.randomizedDelay;
        # Covers both a missed run while powered off and one missed while
        # suspended: systemd re-arms wall-clock timers after resume, so the
        # bespoke catch-up and resume units this module used to carry were
        # doing what systemd already does.
        Persistent = true;
        Unit = "nixos-upgrade-build.service";
      };
    };

    # =========================================================================
    # Apply - activate exactly what was built and displayed
    # =========================================================================
    systemd.services.nixos-upgrade-apply = {
      description = "Apply the built NixOS configuration";

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "1h";
      };

      path = [
        pkgs.nix
        pkgs.systemd
      ];
      environment.HOME = "/root";

      script = ''
        set -euo pipefail

        if [ ! -L "${nextLink}" ]; then
          echo "Nothing built to apply; run nixos-upgrade-build.service first." >&2
          exit 1
        fi

        target="$(readlink -f "${nextLink}")"

        if [ "$target" = "$(readlink -f /run/current-system)" ]; then
          echo "Already running $target; nothing to do."
          exit 0
        fi

        # Activating the built path directly, rather than `nixos-rebuild switch
        # --flake`, so what gets applied is exactly what the indicator showed.
        # Re-resolving the flake here would race with `deploy` moving between
        # the nightly build and the click, and silently install something the
        # user never saw. These two steps are what nixos-rebuild itself does.
        nix-env -p /nix/var/nix/profiles/system --set "$target"
        "$target/bin/switch-to-configuration" switch
      '';
    };

    # =========================================================================
    # Firmware - separate, because it reboots differently and fails differently
    # =========================================================================
    systemd.services.nixos-upgrade-firmware = lib.mkIf cfg.firmware.enable {
      description = "Apply pending firmware updates";

      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "1h";
      };

      script = ''
        # Not --offline: scheduling a firmware update for the next boot without
        # saying so would surprise someone who clicked "apply" on a laptop.
        ${pkgs.fwupd}/bin/fwupdmgr update --assume-yes --no-reboot-check
      '';
    };

    # =========================================================================
    # Let the user drive it from the bar
    # =========================================================================
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units") {
          var unit = action.lookup("unit");
          if ((unit == "nixos-upgrade-build.service" ||
               unit == "nixos-upgrade-apply.service" ||
               unit == "nixos-upgrade-firmware.service") &&
              subject.isInGroup("wheel")) {
            return polkit.Result.YES;
          }
        }
      });
    '';
  };
}
