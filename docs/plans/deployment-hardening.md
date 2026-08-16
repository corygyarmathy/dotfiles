# Plan: hardening the deployment pipeline

Status: revised 2026-08-16 to follow [ADR 0002](../adr/0002-protect-at-activation-not-in-the-rollout.md), which retires the staged rollout and moves protection to activation time. Supersedes the earlier version of this plan, whose "health-gate the canary promotion" item is dropped along with the canary itself.

Already in place, and assumed by everything below: the deployment metrics in `modules/services/monitoring/deploy-metrics.nix` and the `NixosDeployFailed` / `NixosDeployStale` / `NixosRebootPending` rules in `modules/services/monitoring/alert-rules.yml`. No new monitoring work is required to start.

Six pieces. The first two are small and independent; the rest can proceed in any order once they are in.

| #   | Item                     | Size   | Blocks                            |
| --- | ------------------------ | ------ | --------------------------------- |
| 1   | Boot counting            | ~1 line | nothing - do first                |
| 2   | Retire `deploy-stable`   | small  | nothing, once 1 is in             |
| 3   | Health-gated activation  | medium | nothing                           |
| 4   | Behaviour tests          | large  | nothing - grows incrementally     |
| 5   | Service confinement      | medium | _proposed, not yet decided_       |
| 6   | `deploy-rs` interactively | small  | nothing                           |

---

## 1. Boot counting

### The problem

An unattended kernel or initrd change that fails to boot leaves a host down until someone stands in front of it. `homelab02` reboots unattended inside a 04:00-05:00 window with `allowReboot = true`, and it is the host holding the pool.

### Approach

[systemd's Automatic Boot Assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/), which `boot.loader.systemd-boot` gained in nixpkgs 26.11 - the release both servers run. A new entry is written with a boot counter in its filename, systemd-boot decrements it on each attempt, and `systemd-bless-boot.service` clears the counter once the system reaches `boot-complete.target`. An entry that exhausts its tries is skipped in favour of an older generation.

```nix
boot.loader.systemd-boot.bootCounting = {
  enable = true;
  tries = 3;
};
```

Both servers already use systemd-boot (`hosts/homelab01/default.nix:731`, `hosts/homelab02/default.nix:428`), so this belongs in the shared module rather than per host. `xps15` should get it too - it costs nothing and the laptop is the machine most likely to see a half-finished configuration.

### Risks

- ~~Boot loader entries on the ESP are renamed from `nixos-generation-<n>.conf` to `nixos-<content-hash>.conf`, and existing entries migrate on the next `nixos-rebuild boot`/`switch`.~~ Checked against the pinned nixpkgs while implementing: content-hash naming is unconditional in `systemd-boot-builder.py`, so the hosts already write `nixos-<hash>.conf` and boot counting does not cause that migration. What it does change is narrower - a `+<tries>` suffix on the entry filename, and `preferred <entry>` plus `default nixos-*` in `loader.conf` in place of a single `default`. Still worth taking on `homelab01` first, since it is the boot path of the storage node that is not worth proving things on.
- `boot-complete.target` means the boot succeeded, not that services are healthy. This layer covers a kernel that will not come up, nothing more. Item 3 covers the rest.

### Done when

Both servers have booted at least once with counting enabled, and `bootctl` shows entries blessed rather than counting down.

---

## 2. Retire `deploy-stable`

### The problem

`homelab02` follows a ref that trails `deploy` by 24 hours, so a change merged for it arrives a day late, and any deliberate deployment in the meantime is reverted overnight and reinstated the following night. ADR 0002 has the full reasoning.

### Approach

- Point `hosts/homelab02/default.nix` at `github:corygyarmathy/dotfiles/deploy#homelab02` and rewrite the comment above it, which currently explains the staging.
- Delete `.github/workflows/promote-stable.yml`.
- Delete the `origin/deploy-stable` branch, and drop `deploy-stable` from the `reserve-deploy-namespace` ruleset only if the ruleset names it explicitly - the `deploy/` namespace reservation itself must stay.
- Update `.github/workflows/README.md` and the repository `README.md`, both of which describe the two-tier rollout.
- Consider moving `homelab02`'s upgrade time back from 04:15 now that it is not waiting on a promotion job at 03:30. Keeping the offset from `homelab01` is still worth something: `homelab01` mounts NFS from `homelab02`, so the storage node should not be switching underneath it.

### Cutover

There is a trap in doing all of the above in one merge. `homelab02` follows `deploy-stable`, so the commit that repoints it at `deploy` only reaches it once `deploy-stable` advances - and the same merge deletes the workflow that advances it. Scheduled workflows run from the default branch, so `promote-stable.yml` stops firing the moment it leaves `master`, and `homelab02` is then frozen on whatever `deploy-stable` held, following a ref nothing moves.

The unwedge is one push, and needs no ruleset relaxation, since `protect-deploy-stable` blocks deletion and non-fast-forwards but not a fast-forward:

```bash
git fetch origin --prune
git push origin origin/deploy:refs/heads/deploy-stable
```

`homelab02` then takes that revision at 04:15, and from that activation onwards it follows `deploy` like everything else. Only after that has actually happened is it safe to delete the branch and its rulesets.

### Ordering

Strictly this should follow item 3, since it removes protection that health-gated activation replaces. In practice item 1 covers the catastrophic case and the observed failure history contains no base-system regression, so taking it directly after item 1 is defensible - it just means running for a while with no automated recovery from a revision that boots into broken services, which is the status quo today anyway.

### Done when

`homelab02` has taken a revision on the same night it was promoted, and no reference to `deploy-stable` remains in the repository.

---

## 3. Health-gated activation

### The problem

A revision that builds, boots, and then fails to bring its services up has no automated recovery. The alert fires and you fix forward, degraded the whole time. With item 2 in place, both servers take that revision on the same night.

### Approach

Verify after switching, and revert if the system does not come up clean:

```
nixos-upgrade.service
  └─ ExecStartPost: nixos-upgrade-verify
       ├─ systemctl is-system-running --wait   (degraded ⇒ fail)
       ├─ probe the host's own critical units
       └─ on failure: nix-env -p /nix/var/nix/profiles/system --rollback
                      && /run/current-system/bin/switch-to-configuration switch
```

Notes carried over from the previous version of this plan, all still true:

- `systemctl is-system-running` returning `degraded` is a cheap, generic signal - the same condition the existing `node_systemd_unit_state` alert keys off, evaluated immediately instead of at the next scrape.
- The check must be _conservative_. A rollback loop is worse than the degradation it protects against. Give services time to settle and revert only on unambiguous failure.
- A rollback must alert loudly. Silently reverting means the host stops tracking `deploy` and then trips `NixosDeployStale` two days later with a confusing message. Emit it through the existing textfile metrics so it rides the stack that already exists.
- This cannot recover a network-level mistake: verification runs on the host, and a machine that has lost its network still believes it is fine. Item 6 is the remedy for that case.

One addition worth considering: arm the rollback _before_ switching rather than after, as a transient timer (`systemd-run --on-active=…`) that reverts unless cancelled by a successful verification. That covers activation hanging, and partially covers the network case, since the timer fires locally whether or not anything can reach the host. Verify first that a transient timer survives `switch-to-configuration`.

### Done when

A deliberately broken service configuration, deployed to `homelab01`, reverts itself and raises an alert saying so.

---

## 4. Behaviour tests

### The problem

The gate builds every host configuration and validates the Prometheus rules. That proves the Nix evaluates and the derivations realise. It proves nothing about whether Jellyfin starts, whether Caddy routes to it, or whether cross-seed talks to Prowlarr by the address it was configured with.

Per ADR 0002 this is now the primary pre-deploy gate, because service configuration is the failure class this homelab actually experiences.

### Approach

`pkgs.testers.runNixOSTest` boots real VMs and asserts against them. Exposed as flake `checks`, so `nix flake check` runs them and the existing `nixos ci` gate picks them up with no workflow changes.

**Test modules, not hosts.** A whole host configuration will not boot in a VM - disko expects real disks, ZFS expects a pool, sops expects host keys, `homelab01` expects an NFS server. Instantiate the _service module_ in a minimal machine instead, with secrets stubbed.

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

- a `cg.testing.stubSecrets` flag on the sops module that swaps `config.sops.secrets.<x>.path` for a `pkgs.writeText` fixture - invasive, but keeps the test honest about which secrets a module consumes;
- per-test `sops.secrets` overrides pointing at fixtures - no production code changes, but each test has to know the secret names;
- `sops.age.keyFile` set to a committed throwaway key with a fixture secrets file - the most realistic, and exercises the sops wiring itself.

The third is the most faithful and the most work. Start with the second and see whether the duplication actually hurts.

### Candidates, in order of value

| Test             | Asserts                                                             | Why it earns its place                                                           |
| ---------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `data-safety`    | a canary file in the shared download root survives service startup  | models the LazyLibrarian incidents directly, and costs three lines per service    |
| `reverse-proxy`  | Caddy starts, routes to a stub backend, serves 200                  | every public service depends on it; a routing regression is invisible to a build |
| `monitoring`     | Prometheus starts, loads rules, scrapes a target                    | rule and config errors only surface at activation                                |
| `digital-garden` | quartz builds a vault and the result is served                      | the failure mode is a _successful_ build and an empty site                       |
| `media-stack`    | the arr services reach their ports                                  | the largest module, and the one with the most moving parts                       |

`data-safety` is new and first for a reason: two of the three recent incidents were a service touching data it had no business touching, and it is the cheapest assertion in the table.

`digital-garden` remains the most valuable per line among the rest: it is the one place where the current gate is actively misleading, because a broken plugin index produces a build that succeeds.

### Cost and risks

- **KVM.** NixOS tests need it. GitHub's free runners have historically been inconsistent here, though the `nix-installer-action` already in use enables KVM when available. Verify early with a single trivial test - if it falls back to TCG emulation the tests still run, just slowly enough to matter.
- **Runtime.** Minutes per test, in parallel matrix jobs. Acceptable for a nightly gate; worth watching if it starts delaying the lock PR's auto-merge.
- **Maintenance.** A flaky VM test is worse than no test, because it trains you to re-run the gate. Prefer few, sharp assertions over broad ones.

### Done when

At least one test exists, the gate runs it, and a deliberately broken service configuration fails CI rather than merging.

---

## 5. Service confinement _(proposed - not part of ADR 0002)_

### The problem

Two of the three recent incidents were a service damaging data outside its own scope. Detection after the fact is expensive; prevention is declarative and cheap. A service that cannot write to the shared download root cannot delete it.

### Approach

Tighten the systemd units the service modules generate - `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, and an explicit `ReadWritePaths` naming only what the service legitimately writes. For the podman-hosted services the equivalent is narrowing the bind mounts rather than mounting the media tree wholesale.

Pairs naturally with the `data-safety` test in item 4: the test asserts the property, the confinement enforces it.

### Risks

- Several of these services legitimately need broad access - qBittorrent writes into the download root by design, unpackerr extracts across it, cross-seed reads the whole media tree. The win is narrowing _which_ tree, not eliminating access, and getting it wrong shows up as a service that starts and then silently fails on IO.
- Worth doing one module at a time, behind the VM tests, rather than as a sweep.

### Decide first

Whether this belongs in this plan at all or as its own piece of work. It is prevention rather than deployment hardening, and it arrived late in the discussion that produced ADR 0002.

---

## 6. `deploy-rs` for interactive and recovery deployment

### The problem

`nixos-rebuild switch --flake .#homelab02 --target-host coryg@homelab02 --elevate=sudo --ask-elevate-password` is the supported path for iterating on a service, and it is long enough to discourage use. It also offers no protection when the change under test is the one most likely to lock you out - firewall, interface, or sshd configuration on a headless box in a cupboard.

### Approach

Adopt `deploy-rs` narrowly: an input, a `deploy.nodes` block, and `deployChecks` in `checks`. Its `magicRollback` activates, waits for the deployer to reconnect over the new configuration, and reverts if the confirmation never arrives - which is precisely the failure mode item 3 cannot cover.

Two things to settle:

- **A dedicated deploy user** with `sshUser` set to it and `user = "root"`, rather than deploying as `coryg`. `modules/nixos/ssh-hardening.nix` hardcodes `AllowUsers = [ "coryg" ]` and puts `authorizedKeys` on `users.users.coryg`, so both need to grow. Be clear-eyed that this contains accidents and gives an audit trail; it is not a security boundary, since anything that can set the system profile can set it to a closure containing a root shell.
- **`interactiveSudo`**, since `security.sudo.wheelNeedsPassword = true` and root SSH is disallowed. Confirm it works before building on it.

While here, add the `Host homelab01 homelab02 { User = "coryg"; }` block to `modules/home/development/ssh.nix` - it shortens plain `ssh` too.

### Explicitly not

The fleet mechanism. The servers keep pulling. Mutual push - each server deploying the other - was considered and rejected in ADR 0002.

### Done when

`deploy homelab02` from the laptop is one short command, and a deliberately broken firewall rule reverts itself instead of requiring a trip to the cupboard.

---

## 7. Operational writeup

After the pipeline has run for a month or so, write up what actually happened: what broke, what the alerts caught, what they missed, what was tuned and why.

The value is not the incidents themselves but the evidence of operating something over time rather than building it and walking away. `docs/recovery-2026-07-25-qbittorrent-reconciliation.md` is already an example of this done well - a real incident, a real root cause, and the reasoning about what to change.

Candidate material:

- whether `NixosDeployStale` ever fired, and whether 48h was the right threshold
- whether the reboot window is wide enough for a large nixpkgs bump, which is the failure `NixosRebootPending` was written to catch
- how often the lock update produced a genuinely empty closure diff, i.e. whether daily is the right cadence
- whether health-gated activation ever rolled back, and whether it was right to
- whether boot counting ever caught a generation, and whether three tries was the right number
- whether retiring the staged rollout was vindicated or regretted - ADR 0002 makes a falsifiable bet that base-system regressions are not this homelab's problem
