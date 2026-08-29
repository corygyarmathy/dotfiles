# Behaviour tests - item 4 of docs/plans/deployment-hardening.md, and the
# primary pre-deploy gate per ADR 0002.
#
# The build gate proves that a host configuration evaluates and that its
# derivations realise. It proves nothing about whether the services that
# configuration ships actually start, or whether the config files they are
# handed are accepted by the programs that read them. Service configuration is
# the failure class this homelab actually experiences, so that gap is the
# whole point of this directory: these tests boot real VMs and assert against
# them.
#
# Exposed as flake `checks`, so `nix flake check` runs them and the existing
# `nixos ci` gate picks them up with no workflow changes.
#
# TEST MODULES, NOT HOSTS. A whole host configuration will not boot in a VM:
# disko expects real disks, ZFS expects a pool, sops expects host keys,
# homelab01 expects an NFS server on homelab02. Each test instantiates the
# service module under examination in an otherwise minimal machine, with
# secrets stubbed by ./lib.nix.
#
# NO NETWORK. The VMs run inside the Nix build sandbox, which has none. That
# is a constraint on what can be tested here rather than an inconvenience:
# anything whose behaviour depends on fetching something at runtime - every
# `virtualisation.oci-containers` service in modules/services, all of which
# pull `:latest` from a registry - cannot be started in this harness as
# written. See the `data-safety` discussion in the plan.
{
  pkgs,
  self,
  inputs,
}:
let
  testLib = import ./lib.nix { inherit pkgs self inputs; };
in
{
  # Static validation. Cheap, and worth keeping separate from the VM test
  # below: when both fail, which one failed says whether the rule file is
  # malformed or merely rejected in context.
  #
  # promtool lives in the `cli` output, not `out`.
  alert-rules =
    pkgs.runCommand "check-alert-rules" { nativeBuildInputs = [ pkgs.prometheus.cli ]; }
      ''
        promtool check rules ${../modules/services/monitoring/alert-rules.yml}
        touch $out
      '';

  # Unit tests for the rules' logic against synthetic series - the two-branch
  # join behind the journal-tail enrichment and the templates that render it.
  # Static validity cannot catch a join that silently drops its fallback
  # branch, which would turn every enrichment gap into a missed page, and
  # waiting out SystemdUnitFailed's 5m hold-down in a VM just to read one
  # annotation would be the slow way to learn the same thing.
  #
  # The @RULES@ placeholder becomes the rule file's store path, realised as a
  # writeText input rather than passAsFile: promtool resolves rule_files
  # relative to its working directory, which here is an empty build
  # directory, so the test file needs the absolute path baked in either way.
  alert-rules-unit =
    let
      testYml = pkgs.writeText "alert-rules.test.yml" (
        builtins.replaceStrings [ "@RULES@" ] [ "${../modules/services/monitoring/alert-rules.yml}" ] (
          builtins.readFile ./alert-rules.test.yml
        )
      );
    in
    pkgs.runCommand "check-alert-rules-unit" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
      promtool test rules ${testYml}
      touch $out
    '';

  # Same idea for the Alertmanager side: routing, inhibition and muting are
  # assembled by monitoring.nix from options, and a structural mistake there
  # surfaces only when alertmanager refuses to start - on the machines whose
  # job is to notice that everything else stopped. This evaluates the
  # configuration exactly as a production host would receive it (every
  # routing feature switched on) and hands it to amtool. JSON is valid YAML,
  # which saves generating YAML by hand; the sops secret *paths* embedded in
  # the config are checked structurally, never read.
  alertmanager-config =
    let
      eval = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.sops-nix.nixosModules.sops
          ../modules/services/monitoring/monitoring.nix
          (
            { ... }:
            {
              cg.service.monitoring = {
                enable = true;
                alertmanager = {
                  enable = true;
                  ntfy.enable = true;
                  email = {
                    to = "root@example.com";
                    from = "alerts@example.com";
                    authUsername = "alerts";
                  };
                };
                scrapeTargets = [ "localhost:9100" ];
                cloudflaredTarget = "localhost:20241";
              };
            }
          )
        ];
      };
    in
    pkgs.runCommand "check-alertmanager-config"
      {
        nativeBuildInputs = [ pkgs.prometheus-alertmanager ];
        passAsFile = [ "amConfig" ];
        amConfig = builtins.toJSON eval.config.services.prometheus.alertmanager.configuration;
      }
      ''
        amtool check-config "$amConfigPath" | tee amtool.out
        grep -q SUCCESS amtool.out
        mkdir $out
      '';

  # Boot counting wraps systemd-bless-boot in a guard so that a redundant
  # mid-session re-bless - a nixpkgs bump restarts the packaged unit, and the
  # boot decision was already made - cannot leave the unit failed and turn
  # every switch into an exit-4 apply failure. The whole decision is a
  # case-statement over bless-boot's output, so the risk is a branch
  # misclassified: a benign re-bless going red, or a real ESP error swallowed.
  # Neither shows up in a build, and both would take a failing night to
  # notice, so this pins the mapping the way the VM checks pin services.
  #
  # It is a unit test rather than a VM for the same reason the benign failure
  # is rare: bless-boot produces it only under EFI against a consumed boot
  # counter, which the QEMU harness does not model. What is testable is the
  # string -> exit-code function itself, so the script under test is taken
  # from the module's own evaluated ExecStart (never a copy) with only the
  # bless-boot binary swapped for a stand-in emitting each branch. The
  # stand-in fails with distinct exit codes so the "propagate everything not
  # recognised" fall-through is asserted exactly, not just as non-zero.
  bless-boot-guard =
    let
      eval = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ../modules/nixos/boot-counting.nix
          {
            boot.loader.systemd-boot.enable = true;
            boot.loader.efi.canTouchEfiVariables = true;
            cg.boot-counting.enable = true;
          }
        ];
      };
      execStart = builtins.filter (
        s: s != ""
      ) eval.config.systemd.services."systemd-bless-boot".serviceConfig.ExecStart;
      guardScript = builtins.elemAt execStart 0;

      # Messages and exit codes follow the real tool's paths in
      # <systemd>/src/bless-boot/bless-boot.c: a successful or already
      # performed blessing (0), and failures that are either the three benign
      # "nothing left to bless" states (exit 1) or genuine ESP/rename errors
      # (distinct codes, so propagation is asserted exact).
      fakeBlessBoot = pkgs.writeShellScript "fake-systemd-bless-boot" ''
        case "$CASE" in
          blessed)          echo "Marked boot as 'good'. (Boot attempt counter is at 1.)" ; exit 0 ;;
          already-blessed)  echo "Operation already executed before, not doing anything." ; exit 0 ;;
          no-counting)      echo "Not booted with boot counting in effect." >&2 ; exit 1 ;;
          stale-counter)    echo "Path read from LoaderBootCountPath does not contain a counter, refusing: /loader/entries/nixos+0.conf" >&2 ; exit 1 ;;
          pruned)           echo "Can't find boot counter source file for '/loader/entries/nixos-b6320f7.conf'." >&2 ; exit 1 ;;
          esp-missing)      echo "Couldn't find $BOOT partition. It is recommended to mount it to /boot." >&2 ; exit 3 ;;
          esp-open)         echo "Failed to open $BOOT partition '/boot': No such file or directory" >&2 ; exit 5 ;;
          rename-fail)      echo "Failed to rename '/loader/entries/x+3-1.conf' to '/loader/entries/x.conf': Input/output error" >&2 ; exit 7 ;;
          *)                echo "unexpected CASE=$CASE" >&2 ; exit 9 ;;
        esac
      '';
    in
    pkgs.runCommand "check-bless-boot-guard" { guard = builtins.toString guardScript; } ''
      mkdir -p fakebin
      ln -s ${fakeBlessBoot} fakebin/systemd-bless-boot

      # Swap only the binary the guard invokes; everything else in the unit
      # is shipped verbatim.
      sed 's|^bless=".*"$|bless="'"$PWD"'/fakebin/systemd-bless-boot"|' "$guard" > guard
      chmod +x guard

      assert_rc() {
        name=$1
        want=$2
        export CASE="$name"
        set +e
        got=$(./guard 2>&1)
        rc=$?
        set -e
        if [ "$rc" -ne "$want" ]; then
          echo "FAIL: bless-boot-guard: $name exited $rc, expected $want" >&2
          printf '%s\n' "$got" >&2
          exit 1
        fi
        echo "ok: $name -> $rc"
      }

      assert_rc blessed 0
      assert_rc already-blessed 0
      assert_rc no-counting 0
      assert_rc stale-counter 0
      assert_rc pruned 0
      assert_rc esp-missing 3
      assert_rc esp-open 5
      assert_rc rename-fail 7

      touch $out
    '';

  # The build gate and its self-heal hook, together.
  #
  # A laptop's `nixos-upgrade-build` can be asked to run before the network
  # works: network-online.target only means a default route exists, and the
  # Persistent timer fires the catch-up at the first opportunity after the
  # 04:00 slot, which is usually just after boot. The module's defence is
  # three things that only exist as text in the generated unit, dispatcher and
  # NetworkManager.conf - a wait-for-connectivity gate in the build's script,
  # a marker that turns a deferral into a retryable event rather than a
  # genuine failure, and a dispatcher hook that clears the marker and restarts
  # the build on `up` / `connectivity-change` when the network returns. All
  # default to silently doing nothing if they evaluate, so this reads the
  # evaluated outputs (never a copy) and asserts the behaviour markers that a
  # refactor could fold away without breaking the build: the gate becoming a
  # bare `nix build`, the deferral losing its marker, the hook forgetting to
  # handicap by CONNECTIVITY_STATE, or NetworkManager's connectivity check
  # being dropped so the `connectivity-change` branch never fires.
  auto-upgrade-build-gate =
    let
      eval = inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ../modules/nixos/auto-upgrade.nix
          {
            networking.hostName = "check-md";
            networking.networkmanager.enable = true;
            system.stateVersion = "24.11";
            cg.auto-upgrade = {
              enable = true;
              flake = "github:corygyarmathy/dotfiles/deploy";
            };
          }
        ];
      };
      buildScript = eval.config.systemd.services.nixos-upgrade-build.script;
      dispatchers = eval.config.networking.networkmanager.dispatcherScripts;
      retryScript = builtins.concatStringsSep "\n" (
        builtins.map (d: builtins.readFile d.source) dispatchers
      );
    in
    pkgs.runCommand "check-auto-upgrade-build-gate"
      {
        passAsFile = [
          "build"
          "retry"
          "nmsettings"
        ];
        build = buildScript;
        retry = retryScript;
        nmsettings = builtins.toJSON eval.config.networking.networkmanager.settings;
      }
      ''
        fail() { echo "FAIL: $*" >&2; exit 1; }

        # The gate itself.
        grep -q 'github.com' "$buildPath" \
          || fail "build service no longer waits for outbound connectivity"
        grep -q 'deferring the build until a connection comes up' "$buildPath" \
          || fail "connectivity timeout no longer defers the build"
        grep -q 'offline-defers' "$buildPath" \
          || fail "deferral marker was removed from the build script"

        # The self-heal hook: scoped to network-return events, throttled by
        # the marker, and only ever a retry of a failed unit.
        grep -qF 'up)' "$retryPath" \
          || fail "dispatcher no longer reacts to connection-up events"
        grep -qF 'connectivity-change' "$retryPath" \
          || fail "dispatcher no longer reacts to connectivity-change"
        grep -qF 'CONNECTIVITY_STATE' "$retryPath" \
          || fail "connectivity-change is no longer gated on the assessed state"
        grep -qF 'offline-defers' "$retryPath" \
          || fail "retry is no longer limited to deferred (offline) builds"
        grep -qF 'is-failed --quiet' "$retryPath" \
          || fail "dispatcher no longer checks the unit is failed before retrying"
        grep -qF 'start --no-block' "$retryPath" \
          || fail "retry no longer starts the build asynchronously"
        grep -qF '"$systemctl" reset-failed' "$retryPath" \
          || fail "retry no longer clears the failed result first"

        # Without NetworkManager actually assessing connectivity, the
        # connectivity-change branch above can never fire.
        grep -q '"connectivity"' "$nmsettingsPath" \
          || fail "NetworkManager connectivity checking is no longer enabled"
        grep -q '"uri"' "$nmsettingsPath" \
          || fail "NetworkManager connectivity check has no probe URI"

        touch $out
      '';

  digital-garden = testLib.mkTest ./digital-garden.nix;
  digital-garden-sync-health = import ./digital-garden-sync-health.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
  grafana = testLib.mkTest ./grafana.nix;
  monitoring = testLib.mkTest ./monitoring.nix;

  # Not a VM: what it asserts is a shape in the generated configuration, and
  # the file says why that shape is worth a check of its own.
  publish = import ./publish.nix { inherit pkgs self inputs; };
  reverse-proxy = testLib.mkTest ./reverse-proxy.nix;

  # Also not a VM: sops leaves the key structure and the recipient list
  # readable without decrypting, so "does this secret exist, and can the host
  # that wants it open the file" is answerable in the sandbox.
  secrets = import ./secrets.nix { inherit pkgs self; };

  upgrade-verify = testLib.mkTest ./upgrade-verify.nix;
}
