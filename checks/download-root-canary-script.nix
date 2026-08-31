# checks/download-root-canary-script.nix
#
# Unit test for the canary script's storage-side behaviour - the parts the VM
# test cannot reach without a second host exporting NFS under root_squash.
# Two promises are under test:
#
#   - only the store owner primes the sentinel. A root_squash'd NFS client's
#     root is squashed to nobody, cannot create or chown inside the 2775 tree,
#     and a client that did create would hand a wiping service its sentinel
#     back every ten minutes;
#   - only a stat that reached a real, mounted filesystem is allowed to confirm
#     absence. ENOENT from an unmounted automount (server unreachable) is a
#     dead mount, not a wiped root, and must be reported 1/unconfirmed.
#
# The script under test is taken from the module's own evaluated ExecStart
# (never a copy) and driven through the environment overrides the script
# supports, against fixture mountinfo and a scratch sentinel.
{
  inputs,
  pkgs,
  self,
}:
let
  eval = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit self inputs;
    };
    modules = [
      # The service modules assume sops-nix is imported (checks/lib.nix does
      # this for every test node); monitoring.nix declares secrets against it,
      # and a host without it refuses the whole option.
      inputs.sops-nix.nixosModules.sops
      ../modules/services/media-stack/media-stack.nix
      ../modules/services/media-stack/download-root-canary.nix
      ../modules/services/monitoring/monitoring.nix
      ../modules/services/nas-storage.nix
      {
        cg.service.media-stack.enable = true;
        cg.service.media-stack.canary.enable = true;
        cg.service.monitoring.enable = true;
        system.stateVersion = "24.11";
      }
    ];
  };

  execStartValue = eval.config.systemd.services.download-root-canary.serviceConfig.ExecStart;
  execStart = if builtins.isList execStartValue then execStartValue else [ execStartValue ];
  canaryScript = builtins.elemAt (builtins.filter (s: s != "") execStart) 0;
in
pkgs.runCommand "check-download-root-canary-script" { script = builtins.toString canaryScript; } ''
    set -euo pipefail

    work=$PWD/work
    mkdir -p "$work/srv-media/downloads" "$work/metrics"
    export SENTINEL="$work/srv-media/downloads/.download-root-canary"
    export PRIME_MARKER="$work/primed"
    export METRICS_DIR="$work/metrics"
    export METRICS_FILE="$METRICS_DIR/download_root_canary.prom"
    export MOUNTINFO="$work/mountinfo"

    fail() { echo "FAIL: $*" >&2; exit 1; }
    metric() { grep -oE '[01]$' "$METRICS_FILE"; }

    # Fixture mountinfo: a root line plus one describing the sentinel's store.
    # Real mountinfo lists an automount's autofs trigger and the real mount at
    # the same depth, in either order; the script must prefer the real one.
    mk_fixture() {
      cat >"$MOUNTINFO" <<EOF
  36 35 0:1 / / rw - rootfs rw
  $1
  EOF
    }

    zfs() { mk_fixture "37 36 0:2 / $work/srv-media rw,relatime - zfs tank rw"; }
    nfs() { mk_fixture "38 37 0:3 / $work/srv-media rw,relatime - autofs systemd-1
  39 38 0:3 / $work/srv-media rw,relatime - nfs4 10.0.0.9:/srv/media rw"; }
    nfs_first() { mk_fixture "38 37 0:3 / $work/srv-media rw,relatime - nfs4 10.0.0.9:/srv/media rw
  39 38 0:4 / $work/srv-media rw,relatime - autofs systemd-1"; }
    autofs_alone() { mk_fixture "38 37 0:4 / $work/srv-media rw,relatime - autofs systemd-1"; }
    rootfs() { mk_fixture ""; }

    run() {
      rm -f "$METRICS_FILE" "$METRICS_FILE.tmp"
      "$script" >"$PWD/out.log" 2>"$PWD/err.log" || fail "script exited non-zero (see err.log)"
    }

    echo "case: the owner primes on its first post-boot run"
    zfs
    rm -f "$SENTINEL" "$PRIME_MARKER"
    run
    [ -e "$SENTINEL" ] || fail "owner did not prime"
    [ -e "$PRIME_MARKER" ] || fail "owner marker not set"
    [ "$(metric)" = 1 ] || fail "metric != 1 right after prime"
    grep -q "sentinel present" "$PWD/out.log" || fail "no present log"

    echo "case: a deletion after boot prime is reported, not re-created"
    zfs
    rm -f "$SENTINEL"
    run
    [ ! -e "$SENTINEL" ] || fail "deleted sentinel re-created by owner"
    [ -e "$PRIME_MARKER" ] || fail "marker lost between runs"
    [ "$(metric)" = 0 ] || fail "metric != 0 after a confirmed deletion"

    echo "case: nfs client observes a genuine missing sentinel (server mounted)"
    nfs
    rm -f "$SENTINEL" "$PRIME_MARKER"
    run
    [ "$(metric)" = 0 ] || fail "client did not report a confirmed missing (metric='$(metric)', sentinel=$(test -e "$SENTINEL" && echo exists || echo gone), err=$(cat "$PWD/err.log" 2>/dev/null || true))"
    [ ! -e "$SENTINEL" ] || fail "client wrote the sentinel"
    [ ! -e "$PRIME_MARKER" ] || fail "client primed despite nfs cover"

    echo "case: nfs client observes an existing sentinel"
    nfs
    : >"$SENTINEL"
    run
    [ "$(metric)" = 1 ] || fail "client did not report present"

    echo "case: nfs client with the autofs trigger listed after the real mount"
    nfs_first
    rm -f "$SENTINEL"
    run
    [ "$(metric)" = 0 ] || fail "cover resolved to autofs over the real mount"

    echo "case: the root filesystem alone covers the store - owner primes through it"
    rootfs
    rm -f "$SENTINEL" "$PRIME_MARKER"
    run
    [ -e "$SENTINEL" ] || fail "owner did not prime via the root fs"
    [ -e "$PRIME_MARKER" ] || fail "marker not set when the root fs covers the store"
    [ "$(metric)" = 1 ] || fail "metric != 1 after a root-fs prime"

    echo "case: server down - unmounted automount, sentinel unreachable"
    autofs_alone
    rm -f "$SENTINEL" "$PRIME_MARKER"
    run
    [ "$(metric)" = 1 ] || fail "an unreachable sentinel was reported missing"
    [ ! -e "$SENTINEL" ] || fail "client wrote into an unmounted store"
    [ ! -e "$PRIME_MARKER" ] || fail "an unmounted trigger was marked primed"
    grep -q "unreachable" "$PWD/err.log" || fail "no unconfirmed log line"

    touch "$out"
    echo "ok: download-root-canary-script"
''
