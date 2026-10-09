# The AFK agent's unit: every parameter supplied, every secret a path, and the
# kill switch removing what it switched on.
#
# The binary's own behaviour is tested offline in its own repository. What only
# this repository can get wrong is the wiring - a parameter the module forgot,
# a credential that does not arrive, a secret that leaks into the unit's
# environment - and the binary refuses to start on the first two. So the VM
# boots the unit for real and asserts how far it gets: past every parameter,
# the store opened, and on to its first request to GitHub, which the sandbox
# has no network for. A usage error would end the run earlier and with a
# different exit status.
#
# The App key is a real, throwaway RSA key generated at build time rather than
# a stub string, because the binary parses the key before it asks GitHub
# anything, and a stub would fail there instead - earlier than the property
# under test. The other credentials are ./stub-secrets.nix fixtures; the unit
# takes all three through `LoadCredential`, which systemd reads as root, so
# there is no per-secret ownership for a `private` fixture to catch.
{ pkgs, lib, ... }:
let
  appKey = pkgs.runCommand "afk-agent-test-app-key" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    openssl genrsa -out $out 2048
  '';

  opencodeKey = "stub-opencode-key-VALUE-MUST-NOT-LEAK";
  ntfyToken = "stub-ntfy-token-VALUE-MUST-NOT-LEAK";

  # The memory subtest's run, as the unit: a bystander standing in for opencode,
  # then the gate. The bystander holds 160M of a 256M ceiling, so it is the
  # larger process when the gate's lint step fills the rest - the gate is the
  # kernel's choice only because of its oom_score_adj.
  oomGate = pkgs.writeShellScript "afk-agent-oom-gate" ''
    cd oom-gate
    until [ -e go ]; do sleep 0.1; done
    ${pkgs.python3}/bin/python3 -c 'import time; b = b"a" * (160 << 20); open("ready", "w").close(); time.sleep(600)' &
    bystander=$!
    until [ -e ready ]; do sleep 0.1; done
    "$AFK_GATE" && echo "gate passed" || echo "gate failed"
    kill -0 "$bystander" && echo "bystander alive"
    kill "$bystander"
  '';

  # The build-side subtest's workspace: a one-step lint job, then a check whose
  # builder grows without bound inside nix-daemon's cgroup. The host matrix is
  # never reached. The check is named in checks/matrix.json, as in this
  # repository; ci.yml's `checks` job only reads that file.
  buildOomCi = pkgs.writeText "ci.yml" ''
    jobs:
      lint:
        runs-on: x
        steps:
          - run: "true"
      build:
        strategy:
          matrix:
            host: [none]
  '';
  buildOomFlake = pkgs.writeText "flake.nix" ''
    {
      outputs = _: {
        checks.x86_64-linux.hog = derivation {
          name = "hog";
          system = "x86_64-linux";
          builder = "/bin/sh";
          args = [ "-c" "x=x; while :; do x=$x$x; done" ];
        };
      };
    }
  '';
  buildOomGate = pkgs.writeShellScript "afk-agent-build-oom-gate" ''
    cd build-oom
    "$AFK_GATE" && echo "gate passed" || echo "gate failed"
  '';
in
{
  name = "afk-agent";

  nodes = {
    enabled =
      { lib, ... }:
      {
        imports = [
          ../modules/services/afk-agent.nix
          # The unit publishes to this host's ntfy and asserts it is enabled.
          # Its option defaults are what production reads; the server itself
          # does not have to answer for anything asserted here.
          ../modules/services/ntfy.nix
          # ntfy asserts the proxy is on, and only the option has to exist for
          # that: the real module wants a certificate email and a DNS token.
          {
            options.cg.service.reverse-proxy.enable = lib.mkOption { default = true; };
          }
          (import ./stub-secrets.nix {
            secrets."opencode/api-key" = opencodeKey;
            secrets."monitoring/ntfy/alerts-token" = ntfyToken;
          })
        ];

        networking.hostName = "afk-enabled";
        system.stateVersion = "24.11";

        sops.secrets."gh-ci/afk-agent-app-private-key".path = lib.mkForce "${appKey}";

        # Declared, not run: the server does not have to be up for the agent's
        # unit to be wired to it.
        cg.service.ntfy.enable = true;
        systemd.services.ntfy-sh.enable = false;

        # homelab01's values, so the check evaluates what production runs.
        cg.service.afk-agent = {
          enable = true;
          repo = "corygyarmathy/dotfiles";
          appId = "4882603";
          eligibilityLabel = "ready-for-agent";
          reviewQueueLimit = 3;
          workers = 2;
          poll = "1m";
          lease = "3h";
          retry = "15m";
          maxAttempts = 3;
          tokenWait = "1m";
          tokens.heavy-build = 1;
          budget = {
            age = "5m";
            threshold = 90;
          };
          notifyTopic = "afk-agent";
          tierNotifyAfter = 3;
          tiers = [
            {
              name = "review";
              models = [
                "opencode-go/deepseek-v4-pro"
                "opencode-go/glm-5.3"
              ];
            }
            {
              name = "implement";
              models = [
                "opencode-go/glm-5.3-flash"
                "opencode-go/deepseek-v4.1-flash"
              ];
            }
          ];
          review = {
            tier = "review";
            needs = [ "tool_call" ];
            floor = "should-fix";
            foldCut = 50;
          };
          implement = {
            tier = "implement";
            needs = [ "tool_call" ];
            branchPrefix = "afk/";
            gateAttempts = 3;
            handOffLabel = "needs-review";
            denylist = [
              ".github/workflows/**"
              "secrets/**"
              ".sops.yaml"
            ];
            ciWait = "2m";
            ciCeiling = "1h";
            ciFixes = 2;
            sizeSignal = 400;
            freshSessionAt = 200000;
            # Not homelab01's, which names none: empty passes nothing, so
            # only a set with something in it shows the binary parses what
            # the module writes. Two labels, one with a space and two globs.
            sensitive = {
              "job store schema" = [
                "internal/store/**"
                "internal/store.go"
              ];
              CI = [ ".github/workflows/**" ];
            };
          };
          revise.replays = 1;
          effectRounds = 3;
          handBackLabel = "needs-decision";
          commitIdentity = {
            name = "corygyarmathy-afk-agent[bot]";
            email = "326868600+corygyarmathy-afk-agent[bot]@users.noreply.github.com";
          };
          modelAttempts = 2;
          tierWait = "1h";
          modelTimeout = "1h";
          catalogueAge = "24h";
          maxMemory = "6G";
        };
        nix.settings = {
          max-jobs = 1;
          cores = 4;
        };
        systemd.services.nix-daemon.serviceConfig = {
          MemoryHigh = "4G";
          MemoryMax = "6G";
          CPUWeight = 20;
        };

        # What profiles/common.nix gives the gate's `nix build`, and no
        # substituters for it to wait on: the VM has no network.
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
        nix.settings.substituters = lib.mkForce [ ];
      };

    # The switch off. No stub secrets: declaring none when disabled is part of
    # what is asserted, and a stub for an undeclared name would pass silently.
    disabled = {
      imports = [ ../modules/services/afk-agent.nix ];
      networking.hostName = "afk-disabled";
      system.stateVersion = "24.11";
    };
  };

  testScript = ''
    start_all()

    with subtest("the unit gets past every parameter to its first request to GitHub"):
        # A start that fails, and is meant to: the VM has no network. Waiting
        # on the result of the first attempt rather than on a state, because
        # Restart= puts the unit back to activating a minute later.
        enabled.wait_until_succeeds(
            "test \"$(systemctl show -p ExecMainStatus --value afk-agent.service)\" != 0",
            timeout=120,
        )
        status = enabled.succeed("systemctl show -p ExecMainStatus --value afk-agent.service").strip()
        journal = enabled.succeed("journalctl -u afk-agent.service --no-pager")
        assert status == "1", f"exit {status}, not a runtime failure - 2 is a usage error:\n{journal}"
        assert "api.github.com" in journal, f"the run never reached GitHub:\n{journal}"

        # Opened before GitHub is asked anything, so its presence says the
        # store path was supplied and writable under the hardening.
        enabled.succeed("test -f /var/lib/afk-agent/state.db")

    with subtest("a hand-run of an implement transition gets past every parameter to GitHub"):
        # `afk work` resolves the review's dependencies, and asks GitHub who it
        # is, before it reads a single implement parameter, so the subtest
        # above cannot see them. `afk run` on an implement transition reads
        # all of them first. Through afk-agent-run, which is also what shows a
        # hand-run is the unit's account, environment and credentials.
        rc, out = enabled.execute("afk-agent-run afk run implement-gate --issue 1 2>&1")
        assert rc == 1, f"exit {rc}, not a runtime failure - 2 is a usage error:\n{out}"
        assert "api.github.com" in out, f"the run never reached GitHub:\n{out}"

    with subtest("a hand-run of a revise transition gets past every parameter to GitHub"):
        # A revision reads every implement parameter and its replay bound
        # before it asks GitHub who it is, and a missing or malformed bound
        # is a usage error, so only reaching GitHub shows `--replays` arrived.
        rc, out = enabled.execute("afk-agent-run afk run revise-replay --pr 1 2>&1")
        assert rc == 1, f"exit {rc}, not a runtime failure - 2 is a usage error:\n{out}"
        assert "api.github.com" in out, f"the run never reached GitHub:\n{out}"

    with subtest("the unit reaches the Nix daemon under its confinement"):
        # The gate builds through the daemon, from under ProtectSystem=strict.
        # NIX_REMOTE=daemon so the query cannot quietly open the store itself.
        enabled.succeed(
            "afk-agent-run env NIX_REMOTE=daemon nix-store --query --hash $(readlink -f /run/current-system)"
        )

    with subtest("a gate that outgrows the memory ceiling fails, and nothing else in the unit does"):
        # The test instrumentation panics on any OOM, a cgroup's included;
        # production keeps the kernel's default.
        enabled.succeed("echo 0 >/proc/sys/vm/panic_on_oom")
        # A workspace whose one lint step grows without bound.
        enabled.succeed(
            "mkdir -p /var/lib/afk-agent/oom-gate/.github/workflows",
            "printf 'jobs:\\n  lint:\\n    runs-on: x\\n    steps:\\n      - run: tail /dev/zero\\n' >/var/lib/afk-agent/oom-gate/.github/workflows/ci.yml",
            "chown -R afk-agent:afk-agent /var/lib/afk-agent/oom-gate",
            "afk-agent-run ${oomGate} >/tmp/oom-gate.out 2>&1 &",
        )
        # The ceiling lowered to one the VM can reach on the hand-run's own
        # transient unit, so the module's values stay homelab01's.
        unit = enabled.wait_until_succeeds(
            "systemctl list-units --plain --no-legend 'afk-agent-run-*.service' | awk '{print $1}' | grep .",
            timeout=30,
        ).strip()
        enabled.succeed(f"systemctl set-property --runtime {unit} MemoryMax=256M")
        enabled.succeed("touch /var/lib/afk-agent/oom-gate/go")
        # The deciding signal is how systemd ended the unit: the bystander can
        # print before systemd acts on the kill, and under `OOMPolicy=stop` the
        # hand-run does not return at all.
        enabled.wait_until_fails(f"systemctl is-active {unit}", timeout=120)
        journal = enabled.succeed(f"journalctl -u {unit} --no-pager")
        assert "result 'oom-kill'" not in journal, f"the unit did not outlive the OOM kill:\n{journal}"
        enabled.wait_until_succeeds("! pgrep -x systemd-run", timeout=30)
        out = enabled.succeed("cat /tmp/oom-gate.out")
        kernel = enabled.succeed("journalctl -k --no-pager")
        assert "gate failed" in out, f"the gate did not fail:\n{out}"
        assert "running out of memory" in out, f"the gate did not say why it failed:\n{out}"
        assert "bystander alive" in out, f"the OOM kill took more than the gate:\n{out}\n{kernel}"
        assert "(tail)" in kernel, f"the kernel did not kill the gate's lint step:\n{kernel}"
        enabled.succeed("echo 2 >/proc/sys/vm/panic_on_oom")

    with subtest("a build that outgrows nix-daemon's ceiling fails the gate, and the daemon serves on"):
        enabled.succeed("echo 0 >/proc/sys/vm/panic_on_oom")
        enabled.succeed(
            "mkdir -p /var/lib/afk-agent/build-oom/.github/workflows",
            "cp ${buildOomCi} /var/lib/afk-agent/build-oom/.github/workflows/ci.yml",
            "cp ${buildOomFlake} /var/lib/afk-agent/build-oom/flake.nix",
            "mkdir -p /var/lib/afk-agent/build-oom/checks",
            "echo '[\"hog\"]' >/var/lib/afk-agent/build-oom/checks/matrix.json",
            "chown -R afk-agent:afk-agent /var/lib/afk-agent/build-oom",
            "chmod -R u+w /var/lib/afk-agent/build-oom",
        )
        # Lowered for this run only, as the gate's own ceiling is above.
        enabled.succeed("systemctl set-property --runtime nix-daemon.service MemoryHigh=infinity MemoryMax=128M")
        out = enabled.succeed("afk-agent-run ${buildOomGate} 2>&1")
        events = enabled.succeed("cat /sys/fs/cgroup/system.slice/nix-daemon.service/memory.events")
        enabled.succeed("systemctl set-property --runtime nix-daemon.service MemoryHigh=4G MemoryMax=6G")
        assert "gate failed" in out, f"the gate did not fail:\n{out}"
        assert "oom_kill 0" not in events, f"the build was not OOM-killed in nix-daemon's cgroup:\n{out}\n{events}"
        assert "running out of memory" in out, f"the gate did not say why it failed:\n{out}"
        enabled.succeed("systemctl is-active nix-daemon.service")
        enabled.succeed(
            "afk-agent-run env NIX_REMOTE=daemon nix-store --query --hash $(readlink -f /run/current-system)"
        )
        enabled.succeed("echo 2 >/proc/sys/vm/panic_on_oom")

    with subtest("a check name CI's check-names job would refuse fails the gate, saying why"):
        # Split by the gate's loop, "x y" would fail anyway, as two attributes
        # nobody named; the message is what shows the name was refused.
        enabled.succeed("echo '[\"x y\"]' >/var/lib/afk-agent/build-oom/checks/matrix.json")
        out = enabled.succeed("afk-agent-run ${buildOomGate} 2>&1")
        assert "gate failed" in out, f"the gate did not fail:\n{out}"
        assert "check-names job requires" in out, f"the gate did not say the name was refused:\n{out}"

    with subtest("opencode's credentials are provisioned from the key"):
        auth = "/var/lib/afk-agent/.local/share/opencode/auth.json"
        assert enabled.succeed(f"stat -c '%U %a' {auth}").strip() == "afk-agent 600"
        key = enabled.succeed(f"${pkgs.jq}/bin/jq -r '.\"opencode-go\".key' {auth}").strip()
        assert key == "${opencodeKey}", "auth.json does not carry the opencode key"

    with subtest("opencode finds the agent's skills under its $HOME"):
        enabled.succeed("runuser -u afk-agent -- test -r /var/lib/afk-agent/.agents/skills/implement/SKILL.md")

    with subtest("the enrolment is a file both tiers resolve in"):
        env = enabled.succeed("systemctl show -p Environment --value afk-agent.service")
        enrolment = next(v.split("=", 1)[1] for v in env.split() if v.startswith("AFK_ENROLMENT="))
        for tier in ["review", "implement"]:
            enabled.succeed(
                f"${pkgs.jq}/bin/jq -e '.tiers | map(select(.name == \"{tier}\")) | .[0].models | length == 2' {enrolment}"
            )

    with subtest("the advisory review's floor and fold cut reach the unit, and the binary reads them"):
        # Optional to the binary - unset, the skill's own defaults hold - so
        # neither a parameter the module forgot nor a pin that predates them
        # fails the subtests above.
        params = dict(v.split("=", 1) for v in env.split() if "=" in v)
        assert params.get("AFK_REVIEW_FLOOR") == "should-fix", f"AFK_REVIEW_FLOOR is {params.get('AFK_REVIEW_FLOOR')!r}"
        assert params.get("AFK_REVIEW_FOLD_CUT") == "50", f"AFK_REVIEW_FOLD_CUT is {params.get('AFK_REVIEW_FOLD_CUT')!r}"
        usage = enabled.succeed("afk-agent-run afk help 2>&1")
        for flag in ["--review-floor", "--review-fold-cut"]:
            assert flag in usage, f"afk help does not list {flag}:\n{usage}"

    with subtest("the review procedure's link reaches the unit, and the binary reads it"):
        # Optional to the binary - unset, a description's reminder says it has
        # no link - so only this sees the module's default go missing.
        procedure = "https://github.com/corygyarmathy/skills/blob/master/docs/operators-review.md"
        assert params.get("AFK_REVIEW_PROCEDURE") == procedure, f"AFK_REVIEW_PROCEDURE is {params.get('AFK_REVIEW_PROCEDURE')!r}"
        assert "--review-procedure" in usage, f"afk help does not list --review-procedure:\n{usage}"

    with subtest("the sensitive paths reach the unit in the form the binary parses"):
        # Optional to the binary - unset, no description says it touches a
        # sensitive path. What it parses is shown by the implement hand-run
        # above, which reads it and would have ended in a usage error.
        # A label has spaces in it, which systemd quotes and `params` splits.
        import shlex
        quoted = dict(v.split("=", 1) for v in shlex.split(env))
        sensitive = "CI=.github/workflows/**;job store schema=internal/store/**,internal/store.go"
        assert quoted.get("AFK_SENSITIVE") == sensitive, f"AFK_SENSITIVE is {quoted.get('AFK_SENSITIVE')!r}"
        assert "--sensitive" in usage, f"afk help does not list --sensitive:\n{usage}"

    with subtest("unattended intake reaches the unit with its limit, and the binary reads both"):
        # Optional to the binary - unset, nothing is taken unattended and
        # there is no limit - so only this sees either go missing. What it
        # parses is shown by the first subtest, which would have ended in a
        # usage error on a malformed limit.
        assert params.get("AFK_ELIGIBILITY_LABEL") == "ready-for-agent", f"AFK_ELIGIBILITY_LABEL is {params.get('AFK_ELIGIBILITY_LABEL')!r}"
        assert params.get("AFK_REVIEW_QUEUE_LIMIT") == "3", f"AFK_REVIEW_QUEUE_LIMIT is {params.get('AFK_REVIEW_QUEUE_LIMIT')!r}"
        for flag in ["--eligibility-label", "--review-queue-limit"]:
            assert flag in usage, f"afk help does not list {flag}:\n{usage}"

    with subtest("no secret is in the unit's environment, the journal, or a command line"):
        for value in ["${opencodeKey}", "${ntfyToken}", "PRIVATE KEY"]:
            assert value not in env, "a credential value is in the unit's environment"
            assert value not in journal, "a credential value was logged"
        # Every secret parameter is a path into the credentials directory.
        # systemd reports the `%d` specifier expanded or not depending on its
        # version, so accept either spelling of the same directory.
        values = dict(v.split("=", 1) for v in env.split() if "=" in v)
        for name in ["AFK_APP_KEY", "AFK_BUDGET_KEY", "AFK_NOTIFY_KEY"]:
            value = values.get(name, "")
            assert value.startswith(("%d/", "/run/credentials/afk-agent.service/")), (
                f"{name} is not a credential path: {value!r}"
            )
        # The last character bracketed, or grep finds the literal in its own
        # command line and the assertion is about itself.
        enabled.fail(
            "grep -a -e '${lib.removeSuffix "K" opencodeKey}[K]' -e '${lib.removeSuffix "K" ntfyToken}[K]' /proc/[0-9]*/cmdline"
        )

    with subtest("the kill switch leaves nothing behind"):
        disabled.wait_for_unit("multi-user.target")
        disabled.fail("systemctl cat afk-agent.service")
        disabled.fail("id afk-agent")
        disabled.fail("test -e /var/lib/afk-agent")
  '';
}
