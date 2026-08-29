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
# The build is gated on real outbound connectivity (schedule.onlineWait):
# `network-online.target` on a NetworkManager laptop can be satisfied while the
# wifi is still joining, and a fetch made before the network works would leave
# the indicator showing an error for the rest of the session. A deferral drops
# a marker (`offline-defers`) that the NetworkManager dispatcher hook consumes
# by re-running the build once a connection - or assessed connectivity -
# returns.
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

      # `network-online.target` only means NetworkManager has reached a
      # default route. On a laptop that can predate any real internet (DNS
      # still settling, captive portal up, wifi auth unfinished), and the
      # Persistent catch-up fires this unit at the first opportunity after the
      # 04:00 slot was missed - typically just after boot, before the user has
      # signed in. Rather than fail the fetch (which leaves the waybar
      # indicator showing an error for the rest of the session), the build
      # waits up to this many seconds for real outbound connectivity first.
      # The dispatcher hook then defers the build to when a connection comes
      # up if this window runs out.
      onlineWait = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Seconds to wait for outbound connectivity before deferring a scheduled build";
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
        pkgs.curl
      ];
      environment.HOME = "/root";

      script = ''
        # Only touch the network once there is real outbound connectivity.
        #
        # `network-online.target` is ordered here, but it means NetworkManager
        # has *a* default route - not that the internet works. On a laptop the
        # timer's Persistent catch-up fires this the moment the machine boots,
        # which is before the user has signed in and often before the wifi has
        # come up, and `--refresh` turns a fetch made too early into a hard
        # unit failure that the waybar indicator then shows for the rest of
        # the session. The actual precondition for a flake build is an HTTPS
        # connection to the flake host, so wait for that.
        #
        # The timeout defers rather than fails: the NetworkManager dispatcher
        # hook restarts this unit when a connection comes up, and a later
        # success clears the failed state the indicator reads. The marker it
        # leaves behind is what lets the hook tell "deferred for being
        # offline" (retry when the network returns) from "build genuinely
        # failed" (keep showing the error) - see the dispatcher below.
        deadline=$(( $(date +%s) + ${toString cfg.schedule.onlineWait} ))
        while :; do
          if ${pkgs.curl}/bin/curl -fsS --connect-timeout 5 --max-time 10 \
              https://github.com/ >/dev/null 2>&1; then
            break
          fi
          if [ "$(date +%s)" -ge "$deadline" ]; then
            touch "${stateDir}/offline-defers"
            echo "No outbound connectivity after ${toString cfg.schedule.onlineWait}s; deferring the build until a connection comes up." >&2
            exit 1
          fi
          sleep 5
        done

        # Connectivity confirmed, so any offline condition (and with it the
        # deferral marker) is over. Clear it first: a build that now fails for
        # a real reason must stay failed rather than be retried on every
        # reconnect.
        rm -f "${stateDir}/offline-defers"

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

    # Self-heal a build that the connectivity gate had to defer.
    #
    # A deferral is still a failure to systemd, and a failed build shows on
    # the waybar indicator for the rest of the session even once the machine
    # is online - so when the network genuinely comes back, re-run the build.
    # Success clears the failed state and the indicator goes back to the
    # truth.
    #
    # The marker makes that retry safe: it is left only by the gate's timeout
    # path and removed as soon as connectivity is confirmed, so a genuinely
    # broken fetch or build (marker absent) keeps its error instead of being
    # retried on every reconnect forever.
    #
    # Two events mean "the network is back". `up`, when a device activates,
    # and `connectivity-change` when the assessed level recovers on an
    # *already-linked* device - a captive portal accepted, an ISP outage
    # ending, a VPN coming up. The second needs NetworkManager to actually
    # assess connectivity (enabled below); without it a same-connection
    # recovery never reaches this hook, which is precisely the stale-error
    # case that matters after sign-in.
    #
    # It never restarts an in-flight build and never force-builds ahead of a
    # deferral, and the gateway between a disconnected and a connected state
    # is narrow: `reset-failed` + `start` replaces a failed result with a
    # fresh, cheaper attempt.
    networking.networkmanager = {
      dispatcherScripts = [
        {
          type = "basic";
          source = pkgs.writeShellScript "nixos-upgrade-build-retry" ''
            case "$NM_DISPATCHER_ACTION" in
              up)
                ;;
              connectivity-change)
                [ "$CONNECTIVITY_STATE" = "FULL" ] || exit 0
                ;;
              *)
                exit 0
                ;;
            esac

            if [ ! -f "${stateDir}/offline-defers" ]; then
              exit 0
            fi

            unit=nixos-upgrade-build.service
            systemctl=${pkgs.systemd}/bin/systemctl

            if "$systemctl" is-active --quiet "$unit"; then
              # already building (or waiting on the connectivity gate)
              exit 0
            fi

            if ! "$systemctl" is-failed --quiet "$unit"; then
              exit 0
            fi

            rm -f "${stateDir}/offline-defers"
            echo "Network is up; retrying $unit after its earlier offline deferral." >&2
            "$systemctl" reset-failed "$unit"
            "$systemctl" start --no-block "$unit"
          '';
        }
      ];

      # The dispatcher's `connectivity-change` branch above only exists if
      # NetworkManager assesses connectivity. That is off by default; the
      # accepted-portal / never-device-change recovery would otherwise never
      # fire. The check is a periodic request along the default route (the
      # URI returns a bare OK), which is the small cost of self-healing the
      # same-connection case.
      settings.connectivity = {
        enabled = true;
        uri = "http://connectivity-check.ubuntu.com/connectivity-check.html";
        interval = 300;
      };
    };

    # =========================================================================
    # Apply - activate exactly what was built and displayed
    # =========================================================================
    systemd.services.nixos-upgrade-apply = {
      description = "Apply the built NixOS configuration";

      # This unit's ExecStart *is* the switch. If a promoted change touches
      # this unit (e.g. a nixpkgs bump rewrites every ExecStart path), the
      # switch stops it and SIGTERMs itself, aborting activation partway
      # through and leaving stopped units down. Upstream marks its own
      # nixos-upgrade service the same way.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;

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
