# modules/services/monitoring/deploy-metrics.nix
#
# Exports deployment state as node_exporter textfile metrics (ADR 0001).
#
# The pull model's characteristic failure is silence: a host that quietly stops
# upgrading looks identical to a host with nothing to do. Prometheus already
# alerts on failed systemd units and on unreachable HTTP endpoints, so what is
# missing is evidence that the deployment mechanism itself is still running.
#
# Three things are worth knowing about a host, and none of them are visible
# today:
#
#   - when it last completed an upgrade run at all (staleness)
#   - whether that run succeeded
#   - whether a generation is staged but not yet activated
#
# That last one matters more than it looks. `nixos-upgrade` runs
# `nixos-rebuild boot` first, then reboots only if the kernel changed *and* the
# clock is inside the reboot window. If the build runs long enough to push the
# clock past that window, the unit prints "Outside of configured reboot window,
# skipping." and exits zero - so a host can sit on an unactivated kernel
# indefinitely while reporting success every single night.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.monitoring.deploy;

  metricsDir = "/var/lib/prometheus-node-exporter";
  metricsFile = "${metricsDir}/nixos_deploy.prom";
  stateDir = "/var/lib/nixos-deploy";
  stateFile = "${stateDir}/last-run";

  host = config.networking.hostName;

  # Baked in at build time, so this reports the revision of the generation that
  # is actually *running* the script - not whatever happens to be staged.
  revision = if config.system.configurationRevision != null then config.system.configurationRevision else "unknown";

  metricsScript = pkgs.writeShellScript "nixos-deploy-metrics" ''
      set -uo pipefail

      METRICS_DIR="${metricsDir}"
      METRICS_FILE="${metricsFile}"
      STATE_DIR="${stateDir}"
      STATE_FILE="${stateFile}"
      mkdir -p "$METRICS_DIR" "$STATE_DIR"

      # SERVICE_RESULT is set by systemd for ExecStopPost, so its presence means
      # this invocation is recording the outcome of an upgrade run. When it is
      # empty we are only re-rendering (at boot, or on the timer) and must not
      # overwrite the recorded verdict with a fabricated one.
      if [ -n "''${SERVICE_RESULT:-}" ]; then
        if [ "$SERVICE_RESULT" = "success" ]; then
          printf '%s %s\n' "$(date +%s)" 1 > "$STATE_FILE"
        else
          printf '%s %s\n' "$(date +%s)" 0 > "$STATE_FILE"
        fi
      fi

      # Same comparison nixos-upgrade makes: a staged generation only needs a
      # reboot when the kernel, initrd or modules differ from what is booted.
      booted="$(readlink /run/booted-system/{initrd,kernel,kernel-modules} 2>/dev/null || true)"
      built="$(readlink /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules} 2>/dev/null || true)"
      if [ -n "$booted" ] && [ "$booted" = "$built" ]; then
        PENDING=0
      else
        PENDING=1
      fi

      # mtime of the profile symlink itself - when this generation was staged.
      STAGED_TS="$(stat -c %Y /nix/var/nix/profiles/system 2>/dev/null || echo 0)"

      TMP="$METRICS_FILE.tmp"

      cat > "$TMP" <<EOF
    # HELP nixos_deploy_pending_reboot Whether a staged generation needs a reboot to activate
    # TYPE nixos_deploy_pending_reboot gauge
    nixos_deploy_pending_reboot{host="${host}"} $PENDING
    # HELP nixos_deploy_staged_timestamp_seconds Unix timestamp the current system generation was staged
    # TYPE nixos_deploy_staged_timestamp_seconds gauge
    nixos_deploy_staged_timestamp_seconds{host="${host}"} $STAGED_TS
    # HELP nixos_deploy_revision_info Flake revision of the running system
    # TYPE nixos_deploy_revision_info gauge
    nixos_deploy_revision_info{host="${host}",revision="${revision}"} 1
    EOF

      # Emitted only once an upgrade run has actually been recorded. A host that
      # has never completed one has no meaningful "last run", and seeding these
      # with zeroes would fire the staleness alert on day one for every host.
      if [ -r "$STATE_FILE" ]; then
        read -r LAST_TS LAST_OK < "$STATE_FILE" || true
        if [ -n "''${LAST_TS:-}" ] && [ -n "''${LAST_OK:-}" ]; then
          cat >> "$TMP" <<EOF
    # HELP nixos_deploy_last_run_timestamp_seconds Unix timestamp of the last nixos-upgrade run
    # TYPE nixos_deploy_last_run_timestamp_seconds gauge
    nixos_deploy_last_run_timestamp_seconds{host="${host}"} $LAST_TS
    # HELP nixos_deploy_last_run_success Whether the last nixos-upgrade run succeeded (1=success, 0=failure)
    # TYPE nixos_deploy_last_run_success gauge
    nixos_deploy_last_run_success{host="${host}"} $LAST_OK
    EOF
        fi
      fi

      # Atomic swap: node_exporter reads this directory continuously and a
      # half-written file is a parse error rather than a missing metric.
      mv "$TMP" "$METRICS_FILE"
  '';
in
{
  options.cg.service.monitoring.deploy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.system.autoUpgrade.enable;
      description = ''
        Export deployment state (last run, success, pending reboot, revision)
        as node_exporter textfile metrics. Defaults on wherever
        `system.autoUpgrade` is enabled, since that is exactly where a silent
        deployment failure is possible.
      '';
    };
  };

  config = lib.mkIf (config.cg.service.monitoring.enable && cfg.enable) {
    # Overrides the mkDefault in monitoring.nix, which otherwise leaves the
    # textfile collector off on any host without ZFS or the VPN - homelab01.
    cg.service.monitoring.textfileCollector.enable = true;

    systemd.tmpfiles.rules = [
      "d ${metricsDir} 0755 root root -"
      "d ${stateDir} 0755 root root -"
    ];

    # Runs on both success and failure, with SERVICE_RESULT set. In the reboot
    # path `shutdown -r +1` returns immediately, so the unit still finishes and
    # this still records the run before the machine goes down.
    systemd.services.nixos-upgrade = lib.mkIf config.system.autoUpgrade.enable {
      serviceConfig.ExecStopPost = [ metricsScript ];
    };

    systemd.services.nixos-deploy-metrics = {
      description = "Export NixOS deployment metrics for Prometheus";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = metricsScript;
      };
    };

    # Keeps pending_reboot and the running revision honest after a manual
    # `nixos-rebuild`, which is otherwise invisible until the next boot.
    systemd.timers.nixos-deploy-metrics = {
      description = "Timer for NixOS deployment metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
        Unit = "nixos-deploy-metrics.service";
      };
    };
  };
}
