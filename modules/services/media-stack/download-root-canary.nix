# modules/services/media-stack/download-root-canary.nix
#
# Item 8 of docs/plans/deployment-hardening.md, which item 4 named and did not
# do: a sentinel in the shared download root, checked on a timer, published as
# one textfile metric, and alerted on through the existing rules.
#
# Detection rather than prevention, and documented as such. Confinement of the
# sixteen oci-containers services and inspection of their app-level config are
# out of scope by ADR 0003 and item 4 respectively; the honest position the
# plan takes is that the download root is a shared mutable directory several
# services are configured, in their own databases, to write to. What this can
# promise is that it will not be quietly empty for long.
#
# It rides `cg.service.monitoring.textfileCollector`, so it only needs the
# monitoring stack that is already enabled on both servers: a sentinel file, a
# timer that stats it, one metric, one alert rule.
#
# Two parts, sized the way the plan asks:
#
#   1. RUNTIME CANARY. The sentinel `${dataPath}/downloads/.download-root-canary`
#      is primed and statted by the download-root-canary timer; whether it
#      exists is written to node_exporter's textfile collector. A definite
#      absence is published as 0 and, sustained, fires DownloadRootCanaryMissing.
#
#      The sentinel is a single file shared by both hosts (homelab01 mounts
#      homelab02's export read-write), and it is primed only by the host that
#      owns the store - a covering filesystem that is neither an NFS client
#      mount nor an automount trigger, i.e. homelab02's ZFS. NFS clients
#      observe only: under the root_squash export a client's root is squashed
#      to nobody and cannot create or chown inside the 2775 tree, so a client
#      that tried to prime would fail and, were a create ever to succeed, hand
#      a wiping service its sentinel back at every ten-minute run. The owner
#      primes at most once per boot (a /run marker clears on reboot), so every
#      healthy boot ends with its sentinel in place, and anything deleted after
#      that stays deleted - a wiping service must never be handed it back. A
#      deletion after boot is a genuine one; an alert with a `for:` fed by an
#      oscillation never fires.
#
#      Presence is reported 1 unless a stat that reached a real filesystem
#      says "No such file". A clean ENOENT from an UNMOUNTED automount (the
#      NFS server unreachable) is the mount being down, not the root being
#      empty - indistinguishable from a real wipe to a stat - so it is reported
#      as unconfirmed (1) and a dead server pages through its own monitors
#      (systemd units, ZFS, node reachability), not as data loss. A hung stat
#      on a hard-mounted server is bounded by timeout(1) (these mounts are
#      `intr`, so the 60s limit holds) and also reported 1.
#
#   2. STATIC GUARD - the "smaller thing". A NixOS assertion that no
#      service-declared output or post-processing directory covers the download
#      root (is it, or an ancestor of it, by path segment). Honest scope: it
#      can only see paths declared as Nix option values. The paths that
#      actually mattered on 2026-07-25 and 2026-07-27 lived in a
#      service-managed SQLite database, which no Nix-level check can read -
#      that class is the runtime canary's business. Paths that live in
#      generated config/scripts (unpackerr's paths, the cleanup scripts'
#      completeDir) are not harvested either: they are code, reviewed as code,
#      while an option default can change and only show up in the eval. What
#      the guard does catch is the configuration-level class it is named for,
#      and only for registered options - a new media-adjacent service must add
#      its output option to `declaredOutputs` the moment it has one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  stack = config.cg.service.media-stack;
  cfg = config.cg.service.media-stack.canary;
  monitoring = config.cg.service.monitoring;

  downloadRoot = "${stack.dataPath}/downloads";
  sentinel = "${downloadRoot}/.download-root-canary";
  primeMarker = "/run/download-root-canary-primed";

  metricsDir = "/var/lib/prometheus-node-exporter";
  metricsFile = "${metricsDir}/download_root_canary.prom";

  # All of the shell's state (paths that can differ from the defaults below)
  # is overridable via the environment, so the checks can run this exact script
  # against fixture mountinfo and a scratch sentinel rather than a copy.
  canaryScript = pkgs.writeShellScript "download-root-canary-check" ''
    set -uo pipefail

    METRICS_DIR="''${METRICS_DIR:-${metricsDir}}"
    METRICS_FILE="''${METRICS_FILE:-${metricsFile}}"
    SENTINEL="''${SENTINEL:-${sentinel}}"
    PRIME_MARKER="''${PRIME_MARKER:-${primeMarker}}"
    MOUNTINFO="''${MOUNTINFO:-/proc/self/mountinfo}"
    TMP_FILE="$METRICS_FILE.tmp"

    mkdir -p "$METRICS_DIR"

    # Whether $target is $mp or under it. `"$mp"/*` cannot express it for
    # mp = "/" (which would yield "//*"), so the root mount is special-cased.
    under() {
      local target=$1 mp=$2
      [ "$mp" = "$target" ] && return 0
      [ "$mp" = "/" ] && [[ "$target" == /* ]] && return 0
      [[ "$target" == "$mp"/* ]]
    }

    # The filesystem covering the sentinel: the fstype of the longest
    # mountpoint (mountinfo field 5) that is it or a parent of it. When a real
    # filesystem and its automount trigger share the deepest mountpoint, the
    # real one wins; empty when nothing is mounted there.
    cover_fs() {
      local target=$1 line mp maxlen=0 entry=""
      while IFS= read -r line; do
        set -- $line
        mp=''${5:-}
        [ -n "$mp" ] || continue
        under "$target" "$mp" && [ "''${#mp}" -gt "$maxlen" ] && maxlen=''${#mp}
      done <"$MOUNTINFO"

      while IFS= read -r line; do
        set -- $line
        mp=''${5:-}
        [ -n "$mp" ] || continue
        [ "''${#mp}" -ne "$maxlen" ] && continue
        if under "$target" "$mp"; then
          rest=''${line#*" - "}
          set -- $rest
          entry=''${1:-}
          [ "$entry" != "autofs" ] && break
        fi
      done <"$MOUNTINFO"
      printf '%s' "$entry"
    }

    # Whether the covering filesystem means this host owns the store. Owner =
    # a real, reachable, local filesystem (homelab02's ZFS). NFS clients and
    # automount triggers are observers, not owners.
    owner_fs() {
      case "$1" in
        nfs|nfs4|autofs|"")
          return 1
          ;;
        *)
          return 0
          ;;
      esac
    }

    # Prime at most once per boot, and only on the owner. /run clears on
    # reboot, so every healthy owner boot ends with its sentinel in place, and
    # anything deleted after that stays deleted - a wiping service must never
    # be handed it back. If the store is not reachable yet (late ZFS import),
    # priming fails without the marker, so the next run retries.
    if owner_fs "$(cover_fs "$SENTINEL")" && [ ! -e "$PRIME_MARKER" ]; then
      if timeout 60 install -m 0644 /dev/null "$SENTINEL" 2>/dev/null; then
        : > "$PRIME_MARKER"
      else
        echo "download-root-canary: could not prime $SENTINEL yet (store not up?); retrying next run" >&2
      fi
    fi

    # Presence check - also what trigger-mounts an idle NFS automount, so the
    # covering-fs re-read below reflects the state this stat actually ran
    # against. `ls -d` rather than `test -e` so a clean ENOENT can be told
    # apart from a mount that is failing - `test`/`stat` collapse both into
    # exit 1. A 60s timeout bounds a stat hanging on a hard-mounted NFS server.
    check="$(LC_ALL=C timeout 60 ls -d -- "$SENTINEL" 2>&1)"
    rc=$?

    cover=$(cover_fs "$SENTINEL")

    present=1
    state=unconfirmed
    case "$rc" in
      0)
        present=1
        state=present
        ;;
      124)
        # stat() hung: a hard-mounted server is not answering. A hung mount is
        # not a wiped root; the mount's own monitors cover a dead server, so
        # presence is reported unconfirmed rather than missing.
        echo "download-root-canary: sentinel check timed out - reporting present rather than missing" >&2
        ;;
      *)
        if printf '%s' "$check" | grep -q "No such file"; then
          if [ "$cover" = "autofs" ] || [ -z "$cover" ]; then
            # ENOENT from an unmounted automount (NFS server unreachable) is
            # indistinguishable from a wiped root to a stat. Report presence
            # unconfirmed and let the mount's own monitors tell the story.
            echo "download-root-canary: sentinel unreachable ($cover not mounted) - reporting present rather than missing" >&2
          else
            present=0
            state=missing
          fi
        else
          # Non-ENOENT failure (I/O error, automount failure): same reasoning
          # as the timeout, we cannot see the sentinel and must not guess.
          echo "download-root-canary: $check" >&2
        fi
        ;;
    esac

    {
      echo "# HELP download_root_canary_present Whether the download-root canary sentinel exists (1 = present or unconfirmed, 0 = confirmed missing)"
      echo "# TYPE download_root_canary_present gauge"
      echo "download_root_canary_present $present"
    } >"$TMP_FILE"

    # Atomic swap, same reason as deploy-metrics: the collector reads this
    # directory continuously and a half-written file is a parse error rather
    # than a missing metric.
    mv "$TMP_FILE" "$METRICS_FILE"
    echo "download-root-canary: sentinel $state"
  '';
in
{
  options.cg.service.media-stack.canary = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = stack.enable;
      description = ''
        Watch the download root with a primed sentinel and publish its presence
        as a textfile metric, alerting through the existing rules if it goes
        missing. Defaults on wherever media-stack is enabled.
      '';
    };
  };

  config = lib.mkMerge [
    # ------------------------------------------------------------------
    # 1. Runtime canary. Gated on monitoring because the whole point is to
    # ride the textfile collector it enables. media-stack on its own is not
    # enough - without it there is nothing listening.
    # ------------------------------------------------------------------
    (lib.mkIf (stack.enable && cfg.enable && monitoring.enable) {
      # Overrides the mkDefault in monitoring.nix, which otherwise leaves the
      # textfile collector off on any host without ZFS or the VPN - homelab01.
      cg.service.monitoring.textfileCollector.enable = true;

      systemd.tmpfiles.rules = [
        "d ${metricsDir} 0755 root root -"
      ];

      systemd.services.download-root-canary = {
        description = "Download root canary presence check";
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "systemd-tmpfiles-setup.service"
        ];
        # Deliberately no wantedBy: nothing needs the canary at boot, and a
        # boot-time stat is exactly what would stall multi-user.target against
        # a down NFS server (the automount trigger can burn its 30s
        # mount-timeout). The timer's OnBootSec=5min is the first run.
        serviceConfig = {
          Type = "oneshot";
          ExecStart = canaryScript;
        };
      };

      # 5min after boot (the owner re-primes each run until the marker is set,
      # in case of a late store import), then every 10min. Detection latency
      # is therefore ~10min plus the alert's `for:` - comfortably inside the
      # plan's "not quietly empty for two days".
      systemd.timers.download-root-canary = {
        description = "Timer for download root canary check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "10min";
          Unit = "download-root-canary.service";
        };
      };
    })

    # ------------------------------------------------------------------
    # 2. Static guard. Active wherever the media stack is, independent of the
    # canary toggle: it protects the same tree the runtime side watches, and
    # item 4 named it as a check for every moderation.
    # ------------------------------------------------------------------
    (lib.mkIf stack.enable {
      assertions =
        let
          # Is `candidate` the download root, or an ancestor of it, by path
          # segment? /srv/media/downloadsX does not count (a sibling) while
          # /srv/media does - a directory that covers its own sentinel is
          # invisible to it, which is the whole class this guard exists for.
          # Lexical by design: these are managed option values, and the ".."
          # / symlink / duplicate-separator headroom a resolver would add is
          # not the class being caught.
          ancestorsOrSelf =
            candidate:
            let
              drop = s: builtins.filter (x: x != "" && x != ".") (lib.splitString "/" s);
              c = drop candidate;
              d = drop downloadRoot;
              shared = if lib.length c <= lib.length d then lib.length c else lib.length d;
              aligned = lib.all (i: lib.elemAt c i == lib.elemAt d i) (lib.genList (i: i) shared);
            in
            lib.length c <= lib.length d && aligned;

          # The option-valued output/post-processing directories in the fleet,
          # for the services that are actually enabled. This list is the whole
          # reach of the guard, and that is sized honestly: see the header for
          # what is deliberately not here and why.
          byService =
            svc: attr:
            let
              svcOpts = lib.attrByPath [ "cg" "service" svc ] { } config;
            in
            if svcOpts.enable or false then svcOpts.${attr} or null else null;

          declaredOutputs = lib.filter (o: o.path != null) [
            {
              name = "cg.service.suwayomi.downloadPath";
              path = byService "suwayomi" "downloadPath";
            }
            {
              name = "cg.service.shelfmark.ingestPath";
              path = byService "shelfmark" "ingestPath";
            }
          ];
        in
        lib.imap0 (_: o: {
          assertion = !ancestorsOrSelf o.path;
          message = ''
            download-root-safety: ${o.name} is `${o.path}`, which is the
            download root (`${downloadRoot}`) or an ancestor of it. A service
            whose output or post-processing directory covers the download
            root cannot be watched by the sentinel inside it - the
            configuration-level class the would-be data-safety test protected
            (item 4 of docs/plans/deployment-hardening.md). Point the output
            at a sibling directory under `${stack.dataPath}`.
          '';
        }) declaredOutputs;
    })
  ];
}
