# modules/nixos/upgrade-verify.nix
#
# Health-gated activation: check that a newly activated generation actually
# came up, and put the previous one back if it did not.
#
# Item 3 of docs/plans/deployment-hardening.md. Boot counting handles a
# generation that will not boot; this handles one that boots and then fails to
# bring its services up, which is the failure class this homelab actually
# experiences (ADR 0002).
#
# ---------------------------------------------------------------------------
# Why this is not an ExecStartPost on nixos-upgrade
# ---------------------------------------------------------------------------
#
# The plan sketched verification as an ExecStartPost. That is wrong for the
# path that matters. `system.autoUpgrade` with allowReboot runs
# `nixos-rebuild boot` and then branches three ways:
#
#   kernel unchanged            -> `nixos-rebuild switch` inside the unit
#   kernel changed, in window   -> `shutdown -r +1`, activation at next boot
#   kernel changed, out of it   -> nothing activates at all
#
# `shutdown -r +1` returns immediately, so an ExecStartPost fires while the old
# generation is still running and would happily bless the system on its way
# out - and would never see the one that lands. Nightly lock bumps change the
# kernel often, so that is the common case, not the corner.
#
# So verification is anchored on the generation instead of on the trigger: it
# records the store path it last blessed, and does nothing unless the running
# system differs from it. That single rule covers all three branches. The unit
# is started from two places, and either one arriving first is fine:
#
#   - a timer at boot, for the reboot path, which also re-checks on a schedule
#     (`recheckSchedule`) so that a generation nothing thought to announce is
#     still eventually judged
#   - nixos-upgrade's ExecStopPost, for the same-unit switch path (where it is
#     a no-op in the other two branches, because the running system has not
#     changed)
#
# ExecStopPost rather than ExecStartPost, because systemd skips ExecStartPost
# when ExecStart fails - which used to skip verification in precisely the case
# it is most wanted. `nixos-rebuild switch` exits non-zero if any unit is
# failing once activation has finished, so a failed nixos-upgrade quite often
# means "the new generation is live and something on it is unhappy", which is
# the judgement this module exists to make. Trusting the trigger's exit code
# would also undo the point of anchoring on the generation.
#
# The timer exists rather than `wantedBy = multi-user.target` because
# `systemctl is-system-running --wait` blocks until startup completes. A unit
# inside the boot transaction waiting for the boot transaction is a deadlock.
#
# ---------------------------------------------------------------------------
# Being conservative about what counts as failure
# ---------------------------------------------------------------------------
#
# A rollback loop is worse than the degradation it protects against, and the
# obvious implementation - roll back whenever `is-system-running` says
# `degraded` - has an obvious false positive: a host that was already degraded
# before the upgrade would revert every generation it was ever offered, for a
# reason that has nothing to do with the new one.
#
# So nixos-upgrade records the set of failed units *before* it does anything,
# and verification only counts units that were not already failing. Three more
# guards on top of that:
#
#   - no baseline, or one older than `baselineMaxAge`, means report but never
#     roll back, since a new failure cannot be told from an old one.
#   - no rollback for a generation nixos-upgrade did not stage. See below.
#   - no rollback within `rollbackCooldown` of the last one, so a bad revision
#     that keeps being re-offered flaps once a night rather than in a loop.
#   - no rollback if the profile has no previous generation to return to.
#
# `rollback.enable` is off by default. The failure mode of this module is
# reverting a healthy server, and the honest way to find that out is to watch
# it decide for a few weeks before letting it act.
#
# ---------------------------------------------------------------------------
# Verifying by hand-applied generations, without fighting the person
# ---------------------------------------------------------------------------
#
# Verification runs on whatever is booted, so a hand-run `nixos-rebuild switch`
# gets judged too. That is wanted - it is a generation nothing else checks -
# but it must never be reverted. Automatic rollback is worth having because
# nobody is watching at 04:00; someone at a terminal mid-troubleshooting has
# more context than this script does, and taking their work away is worse than
# the degradation it would be protecting against.
#
# `baselineMaxAge` was once assumed to cover this. It does not: the baseline is
# written by nixos-upgrade's ExecStartPre, so switching by hand at 08:00 after
# an 04:00 upgrade leaves a baseline four hours old and comfortably inside the
# limit. Rebooting to test a change - an ordinary thing to do while debugging -
# then fires the OnBootSec trigger straight into an armed rollback.
#
# So rollback is gated on provenance rather than on the trigger or the clock:
# nixos-upgrade records the generation it staged, and rollback is refused
# unless that is what is running. It falls out of the profile symlink, which
# nixos-upgrade already sets in both its `boot` and `switch` branches, so there
# is no new lifecycle to keep honest. A missing record means refuse, which is
# also what a freshly deployed host sees.
#
# It is worth being clear about what this gives up: a generation applied by
# hand and then abandoned is never reverted automatically. That is the intended
# reading - a human touched it, so a human owns it - and `nixos_verify_result`
# still alerts either way. It also makes rollback structurally non-recursive,
# since the generation reverted *to* was never the staged one, which the
# cooldown previously handled more bluntly.
#
# Provenance is also what makes `recheckSchedule` safe to have. Verification
# used to run only when something announced a change, so a generation that
# arrived quietly was never judged; re-checking on a schedule closes that, but
# only became reasonable once a periodic firing could no longer revert
# somebody's afternoon. What is left is bounded by `baselineMaxAge` doing the
# job it was always meant to do: rollback needs evidence contemporary with the
# upgrade, so a scheduled run can only act inside that window, and reports for
# the rest of the generation's life.
#
# ---------------------------------------------------------------------------
# What it cannot do
# ---------------------------------------------------------------------------
#
# Verification runs on the host, so a machine that has lost its network still
# believes it is fine - and it is, locally. That is item 6's problem
# (`deploy-rs` with magicRollback, which waits for the *deployer* to reconnect)
# and is not addressed here.
#
# A rollback is judged by what ends up running, not by what
# switch-to-configuration returned. That script installs the bootloader before
# it activates anything, so a bootloader failure leaves the profile moved and
# nothing else - and its exit code is useless as a success signal in the other
# direction too, since it returns non-zero whenever a unit is failing after
# activation, which is the state every rollback starts from by definition.
# `nixos_verify_rollback_failed` carries the difference between "the old
# generation is running again" and "the profile moved and nothing happened".
#
# The rollback is deliberately services-only: the previous generation is made
# current and made the boot default, but nothing reboots. After a kernel-
# changing upgrade that means the new kernel keeps running under the old
# userland until the next reboot. Rebooting automatically off the back of a
# health check is the one ingredient a rollback loop needs, and boot counting
# does not help there - these generations boot fine, they just come up broken.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.upgrade-verify;

  # Same literal as monitoring.nix and deploy-metrics.nix, which both hardcode
  # it. Worth an option the day it needs to move, not before.
  metricsDir = "/var/lib/prometheus-node-exporter";
  metricsFile = "${metricsDir}/nixos_verify.prom";

  stateDir = "/var/lib/nixos-deploy";
  verifiedFile = "${stateDir}/verified-system";
  baselineFile = "${stateDir}/failed-units-baseline";
  rollbackStamp = "${stateDir}/last-rollback";
  stagedFile = "${stateDir}/automation-staged";

  host = config.networking.hostName;

  failedUnits = "${pkgs.systemd}/bin/systemctl list-units --failed --plain --no-legend --no-pager";

  # Snapshot the units that are already failing, before the upgrade touches
  # anything. Written even when empty - an empty baseline is a real answer and
  # a missing one is not.
  baselineScript = pkgs.writeShellScript "nixos-upgrade-baseline" ''
    set -uo pipefail
    mkdir -p "${stateDir}"
    ${failedUnits} | ${pkgs.gawk}/bin/awk '{print $1}' | sort -u > "${baselineFile}.tmp"
    mv "${baselineFile}.tmp" "${baselineFile}"
  '';

  # What nixos-upgrade staged, read off the profile symlink it just set. Run
  # from ExecStopPost so it records on both outcomes, and so the `boot` branch
  # is captured before the reboot that activates it.
  stagedScript = pkgs.writeShellScript "nixos-upgrade-record-staged" ''
    set -uo pipefail
    mkdir -p "${stateDir}"
    readlink -f /nix/var/nix/profiles/system > "${stagedFile}.tmp"
    mv "${stagedFile}.tmp" "${stagedFile}"
  '';

  verifyScript = pkgs.writeShellScript "nixos-upgrade-verify" ''
    set -uo pipefail

    mkdir -p "${stateDir}" "${metricsDir}"

    # Set only by the rollback path below, but written on every run so the
    # gauge is never stale from a previous verification.
    rollback_failed=0

    current="$(readlink -f /run/current-system)"

    # The whole trigger story collapses into this comparison. Anything already
    # blessed - including the generation we rolled back to - is not our
    # business, so both triggers can fire freely.
    if [ -r "${verifiedFile}" ] && [ "$current" = "$(cat "${verifiedFile}")" ]; then
      echo "Generation already verified: $current"
      exit 0
    fi

    echo "Verifying generation: $current"

    # Provenance, not trigger: rollback is refused below for anything
    # nixos-upgrade did not stage. A missing record refuses too, which is what
    # a host that has not upgraded since this landed will see.
    if [ -r "${stagedFile}" ] && [ "$current" = "$(cat "${stagedFile}")" ]; then
      manual=0
    else
      manual=1
      echo "Not the generation nixos-upgrade staged; this one was applied by hand."
    fi

    # Let units that are going to fail get on with failing. A switch returns as
    # soon as systemd has accepted the jobs, not when they have settled.
    sleep ${toString cfg.settleSeconds}

    # Blocks until systemd leaves the `starting` state, which after a reboot is
    # the thing actually worth waiting for. Its exit code is deliberately not
    # the verdict - `degraded` is the input to the comparison below, not the
    # conclusion.
    state="$(timeout ${toString cfg.settleTimeoutSeconds} \
      ${pkgs.systemd}/bin/systemctl is-system-running --wait 2>/dev/null || true)"
    echo "systemd reports: ''${state:-unknown}"

    now="$(date +%s)"
    ${failedUnits} | ${pkgs.gawk}/bin/awk '{print $1}' | sort -u > "${stateDir}/failed-units-now"

    # Only units that were not already broken before the upgrade started.
    if [ -r "${baselineFile}" ]; then
      new_failures="$(comm -23 "${stateDir}/failed-units-now" "${baselineFile}" | tr '\n' ' ')"
      baseline_age="$(( now - $(stat -c %Y "${baselineFile}") ))"
    else
      new_failures="$(tr '\n' ' ' < "${stateDir}/failed-units-now")"
      baseline_age=-1
    fi

    # Units this host cannot be considered well without, whether or not they
    # show up as `failed` - an inactive unit is not a failed one, and a service
    # that never started is exactly the failure being looked for.
    down_critical=""
    ${lib.optionalString (cfg.criticalUnits != [ ]) ''
      for unit in ${lib.escapeShellArgs cfg.criticalUnits}; do
        if ! ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"; then
          down_critical="$down_critical $unit"
        fi
      done
    ''}

    problems="$(echo "$new_failures $down_critical" | tr -s ' ' | sed 's/^ //;s/ $//')"

    write_metrics() {
      tmp="${metricsFile}.tmp"
      cat > "$tmp" <<EOF
    # HELP nixos_verify_result Whether the last activation verification passed (1=pass, 0=fail)
    # TYPE nixos_verify_result gauge
    nixos_verify_result{host="${host}"} $1
    # HELP nixos_verify_timestamp_seconds Unix timestamp of the last activation verification
    # TYPE nixos_verify_timestamp_seconds gauge
    nixos_verify_timestamp_seconds{host="${host}"} $now
    # HELP nixos_verify_rolled_back Whether the last verification ended in a rollback (1=yes)
    # TYPE nixos_verify_rolled_back gauge
    nixos_verify_rolled_back{host="${host}"} $2
    # HELP nixos_verify_manual_generation Whether the verified generation was applied by hand rather than staged by nixos-upgrade (1=manual, and so exempt from rollback)
    # TYPE nixos_verify_manual_generation gauge
    nixos_verify_manual_generation{host="${host}"} $manual
    # HELP nixos_verify_rollback_failed Whether a rollback was attempted and did not fully take effect (1=yes)
    # TYPE nixos_verify_rollback_failed gauge
    nixos_verify_rollback_failed{host="${host}"} $rollback_failed
    EOF
      if [ -r "${rollbackStamp}" ]; then
        cat >> "$tmp" <<EOF
    # HELP nixos_verify_rollback_timestamp_seconds Unix timestamp of the last automatic rollback
    # TYPE nixos_verify_rollback_timestamp_seconds gauge
    nixos_verify_rollback_timestamp_seconds{host="${host}"} $(cat "${rollbackStamp}")
    EOF
      fi
      # node_exporter reads this directory continuously; a half-written file is
      # a parse error rather than a missing metric.
      mv "$tmp" "${metricsFile}"
    }

    if [ -z "$problems" ]; then
      echo "$current" > "${verifiedFile}"
      write_metrics 1 0
      echo "Verification passed."
      exit 0
    fi

    echo "Verification FAILED. Units not accounted for by the pre-upgrade baseline:$problems" >&2

    # ------------------------------------------------------------------------
    # Everything below decides whether to act on that, and each `exit 1` is a
    # deliberate refusal, not an error - the alert has already been armed by
    # write_metrics.
    # ------------------------------------------------------------------------

    ${
      if !cfg.rollback.enable then
        ''
          write_metrics 0 0
          echo "Rollback is disabled (cg.upgrade-verify.rollback.enable); reporting only." >&2
          exit 1
        ''
      else
        ''
          if [ "$manual" = 1 ]; then
            write_metrics 0 0
            echo "This generation was applied by hand, not staged by nixos-upgrade; reporting only. Reverting someone's work mid-troubleshooting is not this script's call." >&2
            exit 1
          fi

          if [ "$baseline_age" -lt 0 ]; then
            write_metrics 0 0
            echo "No pre-upgrade baseline, so these failures cannot be attributed to this generation; refusing to roll back." >&2
            exit 1
          fi

          if [ "$baseline_age" -gt ${toString cfg.baselineMaxAgeSeconds} ]; then
            write_metrics 0 0
            echo "Baseline is ''${baseline_age}s old, past the ${toString cfg.baselineMaxAgeSeconds}s limit; refusing to roll back on stale evidence." >&2
            exit 1
          fi

          if [ -r "${rollbackStamp}" ]; then
            since="$(( now - $(cat "${rollbackStamp}") ))"
            if [ "$since" -lt ${toString cfg.rollback.cooldownSeconds} ]; then
              write_metrics 0 0
              echo "Rolled back ''${since}s ago, inside the ${toString cfg.rollback.cooldownSeconds}s cooldown; refusing to roll back again." >&2
              exit 1
            fi
          fi

          generations="$(${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --list-generations | wc -l)"
          if [ "$generations" -lt 2 ]; then
            write_metrics 0 0
            echo "No previous generation to return to; refusing to roll back." >&2
            exit 1
          fi

          echo "Rolling back to the previous generation."
          ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --rollback
          target="$(readlink -f /nix/var/nix/profiles/system)"

          # The rolled-back profile's own script, not /run/current-system's -
          # that one belongs to the generation being abandoned. `boot` first so
          # the bootloader default reverts even if `switch` then has trouble;
          # no reboot, for the reason in the header.
          boot_ok=1
          /nix/var/nix/profiles/system/bin/switch-to-configuration boot || boot_ok=0
          /nix/var/nix/profiles/system/bin/switch-to-configuration switch || true

          # ------------------------------------------------------------------
          # Judged on what is running, never on what switch-to-configuration
          # returned.
          #
          # Its exit code cannot be used here. It exits non-zero whenever any
          # unit is failing once activation has finished - which is the state
          # this host is in by definition, since that is what verification just
          # found - so a non-zero return says nothing about whether the
          # rollback took. The symlink does.
          #
          # The other direction is what made this check necessary: bootloader
          # installation happens *before* activation, so when it fails,
          # switch-to-configuration exits without activating anything. The
          # profile has already moved by then, and the old code took that as
          # proof of a rollback and reported success while the broken
          # generation kept running.
          # ------------------------------------------------------------------
          running="$(readlink -f /run/current-system)"

          if [ "$running" != "$target" ]; then
            rollback_failed=1
            write_metrics 0 0
            echo "ROLLBACK DID NOT TAKE. The profile was moved to $target, but $running is still running, so activation never happened - most likely switch-to-configuration failed before it got that far. This host is still on the generation that failed verification and needs hands on it now." >&2
            exit 1
          fi

          # A real move happened, so the cooldown applies whatever else went
          # wrong: the point of the stamp is that a re-offered bad revision
          # flaps once a night rather than in a loop.
          echo "$now" > "${rollbackStamp}"

          if [ "$boot_ok" -eq 0 ]; then
            rollback_failed=1
            write_metrics 0 1
            echo "Rolled back, but the bootloader was not updated. Services are on $target now; the next reboot will return to the generation that failed verification. Fix the bootloader before rebooting." >&2
            exit 1
          fi

          write_metrics 0 1
          echo "Rolled back. The host is no longer tracking the promoted ref - fix forward and check it takes the next revision." >&2
          exit 1
        ''
    }
  '';
in
{
  options.cg.upgrade-verify = {
    enable = lib.mkEnableOption "verify a newly activated generation, and revert it if it did not come up";

    criticalUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "caddy.service"
        "nfs-server.service"
      ];
      description = ''
        Units this host cannot be considered well without. Checked with
        `is-active`, so an inactive unit counts as down - a service that never
        started is not a failed one, and is exactly what this looks for.

        Name automount units rather than their mount units where a filesystem
        is mounted on demand: `srv-media.mount` is legitimately inactive most
        of the time, and probing it would revert healthy generations.
      '';
    };

    settleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        How long to wait after activation before judging anything. A switch
        returns once systemd has accepted the jobs, not once they have settled,
        and a service that crashes on its third restart should still count.
      '';
    };

    settleTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Cap on `systemctl is-system-running --wait`, which otherwise blocks for
        as long as a boot takes to finish - or forever, if one never does.
      '';
    };

    recheckSchedule = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "hourly";
      example = "*:0/30";
      description = ''
        systemd calendar expression for re-checking the running generation,
        alongside the boot and post-upgrade triggers. `null` disables it,
        leaving verification dependent on something thinking to ask for it.

        This is a safety net rather than a schedule: a generation that has
        already been blessed is a no-op, so almost every firing does nothing
        but read a file. What it catches is the case with no trigger at all -
        a `nixos-rebuild switch` run by hand, or an upgrade path that failed
        in a way that skipped its own hook.
      '';
    };

    baselineMaxAgeSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6 * 60 * 60;
      description = ''
        How old the pre-upgrade snapshot of failed units may be and still be
        used as evidence. Past this, verification reports but will not roll
        back, since it can no longer tell a new failure from an old one.
      '';
    };

    rollback = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Actually revert to the previous generation when verification fails,
          rather than only recording and alerting.

          Off by default on purpose. The failure mode of this module is
          reverting a healthy server, and the way to find that out is to watch
          it decide for a while first.
        '';
      };

      cooldownSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6 * 60 * 60;
        description = ''
          Minimum interval between automatic rollbacks. A revision that is
          still promoted will be offered again the next night; this bounds that
          to one revert per window rather than a loop.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.system.autoUpgrade.enable;
        message = ''
          cg.upgrade-verify expects system.autoUpgrade.enable. It hangs its
          pre-upgrade baseline off nixos-upgrade.service, and without that
          there is nothing to record what the host looked like before a
          generation was activated.
        '';
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root -"
      "d ${metricsDir} 0755 root root -"
    ];

    systemd.services.nixos-upgrade = {
      serviceConfig = {
        ExecStartPre = [ baselineScript ];
        # ExecStopPost fires on both outcomes; ExecStartPost would not fire at
        # all when the upgrade failed. See the header. deploy-metrics.nix hangs
        # off the same hook for the same reason.
        #
        # --no-block: this fires while nixos-upgrade is still deactivating, and
        # the queued job is ordered After=nixos-upgrade.service, so it waits for
        # this unit to finish rather than running mid-activation. Blocking here
        # would deadlock against that ordering, and a verification that waits
        # minutes to settle should not hold the upgrade unit open regardless.
        ExecStopPost = [
          # Ordered before the trigger below, so the record is on disk by the
          # time verification reads it. (It would be anyway - the queued job
          # waits for this unit to deactivate - but not by accident.)
          stagedScript
          "${pkgs.systemd}/bin/systemctl start --no-block nixos-upgrade-verify.service"
        ];
      };
    };

    systemd.services.nixos-upgrade-verify = {
      description = "Verify the running NixOS generation came up healthy";
      # Ordering only, never Conflicts - that would stop nixos-upgrade, which
      # is the unit that just started this one. With After, the job queued by
      # ExecStartPost simply waits for the upgrade to finish, so a rollback can
      # never run while nixos-rebuild is mid-activation.
      after = [ "nixos-upgrade.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = verifyScript;
        # Comfortably more than settleSeconds + settleTimeoutSeconds, so the
        # unit's own timeout never pre-empts the checks it is running.
        TimeoutStartSec = cfg.settleSeconds + cfg.settleTimeoutSeconds + 600;
      };
      path = [
        pkgs.coreutils # comm, sort, stat, timeout, tr
        pkgs.gnused
      ];
    };

    # Two triggers in one timer. OnBootSec covers the reboot path, where the
    # generation activates long after nixos-upgrade.service has gone; the
    # calendar entry covers everything with no trigger at all. A timer rather
    # than wantedBy, so verification is not inside the boot transaction it
    # waits on.
    #
    # Deliberately not Persistent: a missed calendar run would then fire at
    # boot, which is what OnBootSec is already there for.
    systemd.timers.nixos-upgrade-verify = {
      description = "Timer for post-boot and periodic generation verification";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        Unit = "nixos-upgrade-verify.service";
      }
      // lib.optionalAttrs (cfg.recheckSchedule != null) {
        OnCalendar = cfg.recheckSchedule;
      };
    };
  };
}
