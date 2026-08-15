# Plan: hardening the deployment pipeline

Status: sketch, not yet started. Follows on from [ADR 0001](../adr/0001-gitops-deployment-with-a-promoted-ref.md), which built the pipeline and named these as its known gaps.

Three pieces, in the order they are worth doing:

1. **Behaviour tests** — turn the gate from "it builds" into "it works"
2. **Rollback** — recover from a bad deploy without a keyboard in front of the machine
3. **An operational writeup** — after the thing has run long enough to have a history

---

## 1. Behaviour tests

### The problem

The gate builds every host configuration and validates the Prometheus rules. That proves the Nix evaluates and the derivations realise. It proves nothing about whether Jellyfin starts, whether Caddy routes to it, or whether the NFS mount comes up.

This is the single largest gap in the pipeline. Unattended nixpkgs-unstable bumps reach the servers with only a compile-time gate, and the first signal that something is broken is an alert firing after it has already deployed.

### Approach

`pkgs.testers.runNixOSTest` boots real VMs and asserts against them. Exposed as flake `checks`, so `nix flake check` runs them and the existing `nixos ci` gate picks them up with no workflow changes.

**Test modules, not hosts.** A whole host configuration will not boot in a VM — disko expects real disks, ZFS expects a pool, sops expects host keys, homelab01 expects an NFS server. Instantiate the _service module_ in a minimal machine instead, with secrets stubbed.

```nix
# checks/media-stack.nix (sketch)
testers.runNixOSTest {
  name = "media-stack";

  nodes.machine = {
    imports = [ ../modules/services/media-stack ];

    cg.service.media-stack = {
      enable = true;
      # point at tmpfs rather than the NFS mount
    };

    # sops cannot decrypt in a VM; hand the modules plain files instead
    cg.testing.stubSecrets = true;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("sonarr.service")
    machine.wait_for_open_port(8989)
    machine.succeed("curl -sf http://localhost:8989/ >/dev/null")
  '';
}
```

The secret stubbing is the part that needs designing rather than typing. Options:

- a `cg.testing.stubSecrets` flag on the sops module that swaps `config.sops.secrets.<x>.path` for a `pkgs.writeText` fixture — invasive, but keeps the test honest about which secrets a module consumes;
- per-test `sops.secrets` overrides pointing at fixtures — no production code changes, but each test has to know the secret names;
- `sops.age.keyFile` set to a committed throwaway key with a fixture secrets file — the most realistic, and exercises the sops wiring itself.

The third is the most faithful and the most work. Start with the second and see whether the duplication actually hurts.

### Candidates, in order of value

| Test             | Asserts                                            | Why it earns its place                                                           |
| ---------------- | -------------------------------------------------- | -------------------------------------------------------------------------------- |
| `reverse-proxy`  | Caddy starts, routes to a stub backend, serves 200 | every public service depends on it; a routing regression is invisible to a build |
| `monitoring`     | Prometheus starts, loads rules, scrapes a target   | rule and config errors only surface at activation                                |
| `digital-garden` | quartz builds a vault and the result is served     | the failure mode is a _successful_ build and an empty site                       |
| `media-stack`    | the arr services reach their ports                 | the largest module, and the one with the most moving parts                       |

`digital-garden` is the most valuable per line: it is the one place where the current gate is actively misleading, because a broken plugin index produces a build that succeeds.

### Cost and risks

- **KVM.** NixOS tests need it. GitHub's free runners have historically been inconsistent here, though the `nix-installer-action` already in use enables KVM when available. Verify early with a single trivial test — if it falls back to TCG emulation the tests still run, just slowly enough to matter.
- **Runtime.** Minutes per test, in parallel matrix jobs. Acceptable for a nightly gate; worth watching if it starts delaying the lock PR's auto-merge.
- **Maintenance.** A VM test that is flaky is worse than no test, because it trains you to re-run the gate. Prefer few, sharp assertions over broad ones.

---

## 2. Rollback

### The problem

A bad deploy currently has no automated recovery. If a service breaks, the alert fires and you fix forward. If the machine does not boot, you need physical access to a box in a cupboard.

Worth separating three distinct failure modes, because they need different answers:

| Failure               | Current recovery        | Gap                             |
| --------------------- | ----------------------- | ------------------------------- |
| does not boot         | boot menu, physically   | needs a keyboard on the machine |
| boots, service broken | alert, then fix forward | slow; degraded the whole time   |
| boots, network broken | physical access         | no remote path at all           |

### Layer 0 — health-gate the canary (prevention, cheapest)

`promote-stable.yml` currently advances `deploy-stable` on elapsed time alone. The deployment metrics from phase 4 already say whether homelab01 is well. Gate on them:

- query Prometheus for `nixos_deploy_last_run_success{host="homelab01"}` and `nixos_deploy_pending_reboot{host="homelab01"}` for the target revision
- refuse to promote if homelab01 is unhealthy, and alert instead

This is the highest value per unit of work in this document. It turns the canary from "has had it for 24h" into "has had it for 24h _and is fine_", which is what a canary is supposed to mean. It needs Prometheus reachable from CI, which is the real obstacle — either an authenticated endpoint through the existing Cloudflare tunnel, or a small pushed summary the workflow can read without inbound access.

### Layer 1 — boot counting (does not boot)

`boot.loader.systemd-boot.bootCounting` implements [systemd's Automatic Boot Assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/): a new entry is written with a counter, systemd-boot decrements it each attempt, and once the system reaches `boot-complete.target`, `systemd-bless-boot.service` marks the entry good. An entry that exhausts its tries is skipped in favour of an older generation.

All three hosts already use systemd-boot, so this is close to free:

```nix
boot.loader.systemd-boot.bootCounting = {
  enable = true;
  tries = 3;
};
```

This is the native answer to the unattended-kernel-bump risk that motivated the canary in the first place, and it works without anyone being present.

Worth understanding before enabling: `boot-complete.target` is reached once the boot succeeds, _not_ once services are healthy. It protects against a kernel that will not boot, not against one that boots into a broken userspace. Layer 2 covers that.

### Layer 2 — health-gated activation (boots, service broken)

After a switch, verify and revert if the system is unhealthy:

```
nixos-upgrade.service
  └─ ExecStartPost: nixos-upgrade-verify
       ├─ systemctl is-system-running --wait   (degraded ⇒ fail)
       ├─ probe the host's own critical units
       └─ on failure: nix-env -p /nix/var/nix/profiles/system --rollback
                      && /run/current-system/bin/switch-to-configuration switch
```

Notes:

- `systemctl is-system-running` returning `degraded` is a good, cheap, generic signal — it is exactly what the existing `node_systemd_unit_state` alert keys off, evaluated immediately instead of five minutes later.
- The check must be _conservative_. A rollback loop caused by an over-eager health check is worse than the degradation it is protecting against. Give services time to settle, and roll back only on unambiguous failure.
- A rollback must alert loudly. Silently reverting means the host stops tracking `deploy` and then trips `NixosDeployStale` two days later with a confusing message.
- This cannot recover a network-level mistake, since the verification runs on the host itself and a machine that has lost its network still thinks it is fine.

### Layer 3 — deploy-rs for the network case (optional)

The one failure this does not cover is locking yourself out — a firewall or interface change that leaves the machine up but unreachable. `deploy-rs`'s magic rollback is the established answer: it activates, waits for a confirmation _over the new configuration_, and reverts if the confirmation never arrives.

It was rejected as the primary mechanism in ADR 0001 because it is push-based and would reintroduce the dependency on an operator's machine being online. But it could be adopted narrowly, for exactly this case, without disturbing the pull model — for instance homelab01 deploying homelab02, since the two already have SSH between them and the storage node is the one worth protecting.

That is a real increase in moving parts for one failure mode. Worth doing only after actually being locked out once, or before a change that is obviously risky.

### Suggested order

1. Boot counting — one option, native, covers the catastrophic case
2. Health-gated activation — moderate work, covers the common case
3. Health-gated canary promotion — highest value, blocked on Prometheus reachability
4. deploy-rs — only if the network case bites

---

## 3. Operational writeup

After the pipeline has run for a month or so, write up what actually happened: what broke, what the alerts caught, what they missed, what was tuned and why.

The value is not the incidents themselves but the evidence of operating something over time rather than building it and walking away. `docs/recovery-2026-07-25-qbittorrent-reconciliation.md` is already an example of this done well — a real incident, a real root cause, and the reasoning about what to change.

Candidate material already visible:

- whether `NixosDeployStale` ever fired, and whether 48h was the right threshold
- whether the reboot window is actually wide enough for a large nixpkgs bump, which is the failure `NixosRebootPending` was written to catch
- how often the lock update produced a genuinely empty closure diff, i.e. whether daily is the right cadence
- whether the 24h canary lag ever mattered
