# Plan: hardening the deployment pipeline

Status: revised 2026-08-16 to follow [ADR 0002](../adr/0002-protect-at-activation-not-in-the-rollout.md), which retires the staged rollout and moves protection to activation time. Supersedes the earlier version of this plan, whose "health-gate the canary promotion" item is dropped along with the canary itself.

Already in place, and assumed by everything below: the deployment metrics in `modules/services/monitoring/deploy-metrics.nix` and the `NixosDeployFailed` / `NixosDeployStale` / `NixosRebootPending` rules in `modules/services/monitoring/alert-rules.yml`. No new monitoring work is required to start.

Six pieces. The first two are small and independent; the rest can proceed in any order once they are in.

| #   | Item                      | Size    | Status                                                   |
| --- | ------------------------- | ------- | -------------------------------------------------------- |
| 1   | Boot counting             | ~1 line | **proven on homelab01** - remaining hosts still to follow |
| 2   | Retire `deploy-stable`    | small   | **done** 2026-08-16                                      |
| 3   | Health-gated activation   | medium  | **landed, not armed** - reports, does not yet roll back  |
| 4   | Behaviour tests           | large   | not started - now the highest-value item                 |
| 5   | Service confinement       | medium  | _proposed, not yet decided_                              |
| 6   | `deploy-rs` interactively | small   | not started - one prerequisite removed                   |

### Where this stands, 2026-08-16

Items 1-3 landed today as four PRs (#22-#25). What remains before any of them can be called finished:

- **Item 1** is proven end to end on `homelab01` - counter written, boot counted, `boot-complete.target` reached, entry blessed - and is still on that host alone. A second PR enables `homelab02` and `xps15`.
- **Item 3** landed with `rollback.enable = false` on both servers and has passed once on each. It verifies, exports metrics and alerts; it does not act. Arming it is one line per host, and should wait for a few weeks of evidence about how often it would have fired on a host that was actually fine.
- **Item 4** is now the binding constraint. ADR 0002 made behaviour tests the primary pre-deploy gate, and until they exist the gate is still "it builds" - which is precisely the class of failure items 1 and 3 are left cleaning up after.

A note on sequencing, since it caught us out today: item 2's ordering section argued it was safe to take before item 3, and that held - but only because the interval was hours. Both servers now take a promoted revision on the same night with no automated recovery from a bad one, and that stays true until item 3 is armed.

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

### What landed

`modules/nixos/boot-counting.nix`, a `cg.boot-counting` wrapper with an assertion that systemd-boot is actually the loader, since the setting is silently inert otherwise. Enabled on `homelab01` only (#22); `homelab02` and `xps15` follow once this is proven.

Confirmed on `homelab01` before it took the config: the ESP already held `nixos-<hash>.conf` entries and `loader.conf` held a plain `default`, which is exactly the state the corrected risk note above predicts - the renaming was never boot counting's doing.

### First evidence, 2026-08-16 16:08

Activated on `homelab01` ahead of the 04:00 run. Everything on the _write_ side does what it should:

```
$ cat /boot/loader/loader.conf
timeout 5
preferred nixos-62c2ed95…c877a8ef.conf
default nixos-*
console-mode keep

$ ls /boot/loader/entries/ | grep '+'
nixos-62c2ed95…c877a8ef+3.conf          # the new generation, and only it

$ bootctl
  Current Boot Loader: systemd-boot 261.1
             Features: ✓ Boot counting
Default Boot Loader Entry:
                tries: 3 left
```

Exactly one of the 32 entries carries a counter - the other 31 predate this and have none, which is what makes the fallback safe: an entry that was never counted is treated as good, so `default nixos-*` still has somewhere to land.

`systemd-bless-boot.service` and `boot-complete.target` are both present in the running system and both `inactive`, which is correct rather than concerning: this boot came from an uncounted entry, so `systemd-bless-boot-generator` had no reason to pull them in.

### Blessing confirmed, 2026-08-16 16:25

`homelab01` was rebooted rather than left to a kernel bump, because the clearing half of the mechanism is the half that can bite: blessing only happens on a boot _from_ a counted entry, and had `boot-complete.target` not been reached on this host, the counter would never clear and the third reboot would mark a perfectly good generation bad and fall back to an older one. Worth one deliberate reboot on the compute node to find out, rather than discovering it on the storage node three reboots later.

```
$ bootctl | grep 'Current Entry'
  Current Entry: nixos-62c2ed95…c877a8ef.conf     # no +N - the counter was cleared

$ systemctl is-active systemd-bless-boot.service
active

$ ls /boot/loader/entries/ | grep '+'
                                                  # nothing counting down
```

`systemd-bless-boot.service` entered active at 16:24:51 with `Result=success` and exit status 0, and `loader.conf` kept its `preferred` line through the blessing. The round trip is therefore complete and observed: entry written `+3` → booted → decremented → `boot-complete.target` reached → counter cleared → entry blessed.

Item 1's "done when" is met for `homelab01`.

**Still outstanding:** enabling `homelab02` and `xps15`, now that the mechanism has been proven end to end somewhere it was safe to prove it.

---

## 2. Retire `deploy-stable`

### The problem

`homelab02` follows a ref that trails `deploy` by 24 hours, so a change merged for it arrives a day late, and any deliberate deployment in the meantime is reverted overnight and reinstated the following night. ADR 0002 has the full reasoning.

### Approach

- Point `hosts/homelab02/default.nix` at `github:corygyarmathy/dotfiles/deploy#homelab02` and rewrite the comment above it, which currently explains the staging.
- Delete `.github/workflows/promote-stable.yml`.
- Delete the `origin/deploy-stable` branch, and drop `deploy-stable` from the `reserve-deploy-namespace` ruleset only if the ruleset names it explicitly - the `deploy/` namespace reservation itself must stay. (It did name it explicitly. Deleting the branch also needs the `protect-deploy-stable` ruleset removed first, which blocks deletion with zero bypass actors.)
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

### What happened

Done 2026-08-16 (#23). `homelab02` follows `deploy`, `promote-stable.yml` is deleted, the branch and the `protect-deploy-stable` ruleset are gone, and `reserve-deploy-namespace` reserves `refs/heads/deploy/**` alone. `protect-deploy` was checked afterwards and is untouched - the API `PUT` replaces a whole ruleset, so a neighbouring one being damaged is a silent failure worth checking for rather than assuming.

The offset stayed at 04:15, on the second of the two arguments above.

The cutover above is written as though it goes cleanly. It took three attempts, and the failures are the useful part:

- **The fast-forward was run against a moving target.** `git push origin origin/deploy:refs/heads/deploy-stable` was issued after #23 merged but before its promote job had advanced `deploy`, so it resolved to the previous commit - one short of the one that repoints `homelab02`. Naming the SHA explicitly is immune to this; `origin/deploy` is not a stable noun for the couple of minutes after a merge.
- **`homelab02` had to be cut over by hand anyway.** Deleting the branch was only safe once `homelab02` had _activated_ the repointing commit, and that was not scheduled until 04:15. `systemctl start nixos-upgrade.service` did it early. That was only safe because `flake.lock` was unchanged across the range: had the kernel differed, `nixos-upgrade` outside the reboot window would have staged the generation and skipped, leaving the host uncut-over while reporting success.
- **A stacked PR broke on squash-merge.** #24 was based on #23's branch; squash merging produced new SHAs on `master`, so #24 then carried duplicate copies of two already-merged commits and went `CONFLICTING`. Fixed by rebasing onto `master` and dropping them. Any stack on a squash-merge repository needs that step every time a base lands.

---

## 3. Health-gated activation

### The problem

A revision that builds, boots, and then fails to bring its services up has no automated recovery. The alert fires and you fix forward, degraded the whole time. With item 2 in place, both servers take that revision on the same night.

### Approach

Verify after switching, and revert if the system does not come up clean.

**The `ExecStartPost` sketch this plan previously carried does not work**, and the reason is worth recording. `system.autoUpgrade` with `allowReboot` runs `nixos-rebuild boot` and then branches three ways: kernel unchanged means a `switch` inside the unit; kernel changed and inside the window means `shutdown -r +1`, with activation at the next boot; kernel changed outside it means nothing activates at all. `shutdown -r +1` returns immediately, so an `ExecStartPost` fires while the _old_ generation is still running - it would bless the outgoing system on its way out and never see the one that lands. Nightly lock bumps change the kernel often, so that is the common branch, not a corner.

So verification is anchored on the generation rather than on the trigger. It records the store path it last blessed and does nothing unless the running system differs, which makes all three branches fall out of one rule, and lets it be started from two places without coordination:

```
nixos-upgrade.service
  ├─ ExecStartPre:  record the set of units already failing
  └─ ExecStartPost: systemctl start --no-block nixos-upgrade-verify

nixos-upgrade-verify.service        (also started by a timer at OnBootSec)
  ├─ running system == last blessed?  ⇒ exit 0
  ├─ settle, then systemctl is-system-running --wait
  ├─ failed units now, minus the pre-upgrade baseline
  ├─ probe the host's own critical units
  └─ on failure: nix-env -p /nix/var/nix/profiles/system --rollback
                 && $profile/bin/switch-to-configuration boot && … switch
```

A timer rather than `wantedBy = multi-user.target`, because `is-system-running --wait` blocks until startup completes and a unit inside the boot transaction waiting on the boot transaction is a deadlock.

The baseline subtraction is what makes the check conservative in the way the note below demands: without it, a host with one chronically failing unit would revert every generation it was ever offered, for a reason having nothing to do with the new one.

Notes carried over from the previous version of this plan, all still true:

- `systemctl is-system-running` returning `degraded` is a cheap, generic signal - the same condition the existing `node_systemd_unit_state` alert keys off, evaluated immediately instead of at the next scrape.
- The check must be _conservative_. A rollback loop is worse than the degradation it protects against. Give services time to settle and revert only on unambiguous failure.
- A rollback must alert loudly. Silently reverting means the host stops tracking `deploy` and then trips `NixosDeployStale` two days later with a confusing message. Emit it through the existing textfile metrics so it rides the stack that already exists.
- This cannot recover a network-level mistake: verification runs on the host, and a machine that has lost its network still believes it is fine. Item 6 is the remedy for that case.

One addition worth considering: arm the rollback _before_ switching rather than after, as a transient timer (`systemd-run --on-active=…`) that reverts unless cancelled by a successful verification. That covers activation hanging, and partially covers the network case, since the timer fires locally whether or not anything can reach the host. Verify first that a transient timer survives `switch-to-configuration`. **Not built.** It is a second mechanism for a failure the first does not cover, and there is no evidence yet that activation hanging happens here; the cheaper first move is a `TimeoutStartSec` on `nixos-upgrade.service`, which turns a hang into a failed unit and an existing alert.

### Landed in two stages

Shipped reporting-only (#24): `modules/nixos/upgrade-verify.nix`, the `NixosVerifyFailed` and `NixosRolledBack` rules, and `criticalUnits` on both servers - with the rollback itself behind `cg.upgrade-verify.rollback.enable`, default false. The failure mode of this module is reverting a healthy server, and watching it decide for a few weeks costs nothing while guessing at the false-positive rate could cost a night's uptime on the storage node. Arming it afterwards is a one-line change per host.

### First run, 2026-08-16

Both servers, triggered by `nixos-upgrade`'s `ExecStartPost` rather than the boot timer - so the same-unit switch path is exercised and works:

```
Verifying generation: /nix/store/xzd1cyim…-nixos-system-homelab01-…
systemd reports: running
Verification passed.
Consumed 69ms CPU time over 2min 90ms wall clock time, 4.2M memory peak
```

`homelab02` identical. Two useful readings beyond "it passed":

- **The critical unit lists are right.** A pass means every unit in them was active, so `srv-media.automount`, `caddy`, `jellyfin`, `zfs-import-tank`, `nfs-server` all reported correctly. Had the automount trap not been caught, this is where it would have shown up as a spurious failure on `homelab01`.
- **It is free.** Under 70ms of CPU; the two minutes of wall clock are the deliberate settle, and it runs `--no-block` so nothing waits on it.

### The boot timer, 2026-08-16 16:27

The reboot of `homelab01` for item 1 incidentally exercised item 3's other trigger, three minutes into the new boot:

```
Starting Verify the running NixOS generation came up healthy...
Generation already verified: /nix/store/xzd1cyim…-nixos-system-homelab01-…
Finished Verify the running NixOS generation came up healthy.
```

Small output, three things proven. The timer fires at all, so the reboot path has a trigger - this is the branch the plan's original `ExecStartPost` design could never have reached. The generation-keyed guard works: the running system had been blessed before the reboot, so it exited immediately rather than re-verifying and re-sleeping. And nothing deadlocked, which is what the timer exists to avoid - a unit ordered inside the boot transaction while waiting on `is-system-running --wait` would have hung the boot instead.

What remains unexercised is the timer finding _new_ work: booting into a generation that has never been verified, which needs a kernel bump. The trigger is proven; the verdict it will reach on a fresh generation is not.

**Stage two, still outstanding:** arm `rollback.enable`, `homelab01` first. The signal to look for beforehand is `nixos_verify_result` staying at 1 across a few weeks of nightly upgrades - every 0 in that window is a rollback that would have happened, and worth understanding before it does.

Two things worth checking rather than assuming, both of which would have caused nightly reverts of healthy hosts:

- `homelab01`'s media mount is an **automount**, so `srv-media.mount` is legitimately inactive most of the time and `srv-media.automount` is the unit to probe.
- `zfs-import-tank.service` and `nfs-server.service` are `Type=oneshot`; both set `RemainAfterExit`, so `is-active` stays meaningful after they finish. A oneshot without it would read as inactive forever.

### Done when

A deliberately broken service configuration, deployed to `homelab01`, reverts itself and raises an alert saying so. Reaching that requires arming `rollback.enable`, which is deliberately a separate decision from landing the mechanism.

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

### Observations banked 2026-08-16, from building items 1-3

Recorded now because the detail evaporates. Roughly in order of how much they would interest a reader.

**Where the plan was wrong, and why**

- The health-gated activation design in this plan **could not have worked**. `ExecStartPost` on `nixos-upgrade` fires after `shutdown -r +1` returns, so on any kernel-changing upgrade it would have inspected the outgoing generation and blessed it - and never seen the one that lands. Nightly lock bumps change the kernel often, so the broken branch was the common one. The fix was to stop keying on the trigger and key on the generation instead. Worth writing up as the difference between a design that reads correctly and one checked against the unit the module actually generates.
- Item 1's headline risk - ESP entries migrating to content-hash names - **did not exist**. That naming is unconditional in the pinned nixpkgs, verified first in `systemd-boot-builder.py` and then on `homelab01`'s live ESP. A risk register is only as good as the last time someone checked it against the source.
- The plan had no cutover section for item 2 until one was written mid-implementation, and it was needed: deleting `promote-stable.yml` freezes the ref that carries the change to the host being changed. A migration that removes the mechanism delivering it is a shape worth naming.

**What the pipeline did under change**

- `deploy-stable` was **18 commits behind** when work started, and the 24h guard was working exactly as written. The storage node had silently missed every service change merged since it was set up. The best argument for ADR 0002 turned out to be the state of the thing it was arguing about.
- Stacked PRs **never ran CI**, because `ci.yml` is scoped to `branches: [master]`. Two consequences, one obvious and one not: the gate did not gate, and their closures were never pushed to Cachix - which is what made the hosts reject a locally built deploy, since the paths could not be substituted and were therefore unsigned.
- The gate is scoped by base branch, which is a reasonable default that silently stops applying the moment anyone stacks. Worth deciding whether to widen it or to stop stacking.

**Two failures of identity, not content**

Both cost real time, and both look identical from the outside - a branch that will not merge for no visible reason.

- An `--amend` on a commit another branch was based on forked the stack, leaving two commits with the same tree and different SHAs.
- Squash-merging a base turned the child PR's already-merged commits into duplicates and marked it `CONFLICTING`. `git merge-tree` was the fastest way to get a straight answer; GitHub's `mergeable` field lags a push by long enough to mislead.

**Deployment ergonomics**

- `trusted-users = root` meant `nixos-rebuild --target-host` only ever worked for a closure already in Cachix - i.e. only for changes that had been through CI, which is the opposite of what iterating is for. The failure surfaces as `lacks a signature by a trusted key`, several lines above a cascade of unrelated I/O errors that read like the real problem.
- The `README`'s documented deploy command used `root@`, which `cg.ssh-hardening` has always refused. Nobody had run it.
- Both of these argue item 6 is less optional than its "small" sizing suggests.
