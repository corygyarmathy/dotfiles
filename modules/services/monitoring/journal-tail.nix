# modules/services/monitoring/journal-tail.nix
#
# Puts the last few journal lines of a failed unit INTO the alert that
# reports it, without standing up a log pipeline (Loki + Alloy remain
# deliberately deferred).
#
# The chain is the established textfile pattern: a oneshot service writes
# journal_tail.prom next to the other exporters' files, node_exporter serves
# it, Prometheus scrapes it, and a recording rule in alert-rules.yml joins
# the captured tail onto node_systemd_unit_state so alert annotations can
# render it directly. Everything downstream of the metric - push lane, email
# lane, dashboard - flows unchanged.
#
# Deliberately best-effort. A unit whose journal has nothing for the current
# boot produces no series, and the recording rule's fallback branch selects
# the bare failed-unit condition instead; the alert then says so rather than
# pretending output existed. Enrichment gaps must degrade to the old alert,
# never suppress it.
#
# Sizing: 8 lines capped at 150 bytes each keeps a tail near 1.2 KB, so two
# or three simultaneously-failed units still fit inside ntfy's 4 KB message
# limit on the push lane. The email lane carries the full text regardless;
# anything longer than the push message allows is what `journalctl` is for.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cg.service.monitoring.journalTail;

  metricsDir = "/var/lib/prometheus-node-exporter";
  metricsFile = "${metricsDir}/journal_tail.prom";

  # Prometheus text exposition escapes, applied line-wise before joining the
  # lines with literal backslash-n sequences. Everything outside printable
  # ASCII (control characters, ANSI colour codes, invalid UTF-8 from a
  # misbehaving unit) is stripped first: one malformed label value makes
  # node_exporter reject the WHOLE file for that scrape, which would take the
  # zfs/gluetun/deploy metrics down with it. Truncation happens after that
  # filtering, under LC_ALL=C so cut counts bytes and can never split a
  # multibyte character.
  journalTailScript = pkgs.writeShellScript "journal-tail-exporter" ''
    set -euo pipefail

    OUT_DIR="${metricsDir}"
    TMP_FILE="${metricsFile}.tmp"
    mkdir -p "$OUT_DIR"

    {
      echo "# HELP systemd_unit_journal_tail_info Recent journal output of a systemd unit, captured while it is in failed state"
      echo "# TYPE systemd_unit_journal_tail_info gauge"

      # Column 1 of list-units output is the unit name; --plain keeps table
      # headers out of --no-legend output on the systemctl versions that
      # would otherwise emit them.
      units="$(systemctl list-units --state=failed --plain --no-legend 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}' || true)"
      for unit in $units; do
        # Current boot only: failed state does not survive a reboot, so older
        # entries cannot be what fired the alert. Timestamps stay in
        # (short-iso) because crash-loop cadence is triage information.
        tail="$(journalctl -u "$unit" -b -n ${toString cfg.lines} -o short-iso --no-pager 2>/dev/null \
          | tr -d '\r' \
          | tr -cd '\11\12\40-\176' \
          | LC_ALL=C cut -c1-150 \
          | ${pkgs.gawk}/bin/awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s%s", sep, $0; sep="\\n"}' \
          || true)"
        [ -n "$tail" ] || continue
        printf 'systemd_unit_journal_tail_info{name="%s",tail="%s"} 1\n' "$unit" "$tail"
      done
    } > "$TMP_FILE"

    # Atomic swap, same reason as deploy-metrics: the collector reads this
    # directory continuously and a half-written file is a parse error rather
    # than a missing metric.
    mv "$TMP_FILE" "${metricsFile}"
  '';
in
{
  options.cg.service.monitoring.journalTail = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Capture the last journal lines of failed systemd units as a textfile
        metric, so unit-failure alerts carry the relevant output instead of
        only pointing at journalctl.
      '';
    };

    lines = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "How many journal lines to capture per failed unit.";
    };
  };

  config = lib.mkIf (config.cg.service.monitoring.enable && cfg.enable) {
    # Overrides the mkDefault in monitoring.nix, which otherwise leaves the
    # textfile collector off on any host without ZFS or the VPN - homelab01.
    cg.service.monitoring.textfileCollector.enable = true;

    systemd.tmpfiles.rules = [
      "d ${metricsDir} 0755 root root -"
    ];

    systemd.services.journal-tail-exporter = {
      description = "Capture failed units' journal tails for Prometheus";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = journalTailScript;
      };
    };

    # One-minute cadence matches the scrape interval: the tail is never more
    # than a couple of minutes older than the alert it enriches, well inside
    # SystemdUnitFailed's 5m hold-down. A run with no failed units rewrites
    # the file header-only, which is what clears stale tails promptly -
    # skipping the write would leave a recovered unit's output attached to
    # nothing until Prometheus staleness got around to it.
    systemd.timers.journal-tail-exporter = {
      description = "Timer for journal tail capture";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        Unit = "journal-tail-exporter.service";
      };
    };
  };
}
