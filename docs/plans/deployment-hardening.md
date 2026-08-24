# Plan: hardening the deployment pipeline

Status: revised 2026-08-16 to follow [ADR 0002](../adr/0002-protect-at-activation-not-in-the-rollout.md), which retires the staged rollout and moves protection to activation time. Supersedes the earlier version of this plan, whose "health-gate the canary promotion" item is dropped along with the canary itself.

Already in place, and assumed by everything below: the deployment metrics in `modules/services/monitoring/deploy-metrics.nix` and the `NixosDeployFailed` / `NixosDeployStale` / `NixosRebootPending` rules in `modules/services/monitoring/alert-rules.yml`. No new monitoring work is required to start.

Six pieces originally; five now, since service confinement moved out to [ADR 0003](../adr/0003-service-confinement-is-bounded-by-hardlinking.md). The first two are small and independent; the rest can proceed in any order once they are in.

| #   | Item                      | Size    | Status                                                   |
| --- | ------------------------- | ------- | -------------------------------------------------------- |
| 1   | Boot counting             | ~1 line | **done** 2026-08-16 - all three hosts                    |
| 2   | Retire `deploy-stable`    | small   | **done** 2026-08-16                                      |
| 3   | Health-gated activation   | medium  | **landed, not armed** - reports, does not yet roll back  |
| 4   | Behaviour tests           | large   | **harness + 3 tests landed** - `media-stack` waits on the container move |
| 5   | Service confinement       | -       | **moved out** - [ADR 0003](../adr/0003-service-confinement-is-bounded-by-hardlinking.md) |
| 6   | `deploy-rs` interactively | small   | not started - one prerequisite removed                   |

### Where this stands, 2026-08-16

Items 1-4 all moved today, across PRs #22-#32. What remains before the rest can be called finished:

- **Item 1** is **done**. Proven end to end on `homelab01` first - counter written, boot counted, `boot-complete.target` reached, entry blessed - then extended to `homelab02` and `xps15` in #28. That closes the case the item was written for: `homelab02` reboots unattended inside the 04:00-05:00 window with `allowReboot = true`, and it is the host holding the pool.
- **Item 3** landed with `rollback.enable = false` on both servers and has passed once on each. It verifies, exports metrics and alerts; it does not act. Arming it is one line per host, and should wait for a few weeks of evidence about how often it would have fired on a host that was actually fine.
- **Item 4** has a harness and three tests - `monitoring`, `reverse-proxy`, `digital-garden` - all running in the gate, each verified against a deliberate break that the host build accepts. What remains is `media-stack`, which now waits on the migration off `oci-containers` rather than on anything in this harness. **This is also where the plan was most wrong.** It argued that since ADR 0003 ruled out enforcing the data-safety property structurally, the `data-safety` test was the only thing left that could cover it - and that did not follow. The test turned out to be the one candidate on the list that cannot be built as written and would have asserted nothing if it were, so it is struck rather than deferred. A real argument for needing something is not evidence that the proposed something works.

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

### Extended to the rest of the fleet, 2026-08-16

`homelab02` and `xps15` followed in #28, once the mechanism had been proven end to end somewhere it was safe to prove it. The item's "done when" - both servers booted at least once with counting enabled, and `bootctl` showing entries blessed rather than counting down - is now met on the fleet rather than on one host, and **item 1 is closed**.

Worth noting what the sequencing bought, since it is the whole argument for doing it this way: the deliberate reboot on the compute node found nothing wrong, but it was the only way to learn that the _clearing_ half works before trusting it on the storage node. Had `boot-complete.target` not been reachable, the third unattended reboot would have marked a perfectly good generation bad and fallen back - on the machine holding the pool, at 04:00, with nobody watching.

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

| Test             | Asserts                                                             | Why it earns its place                                                           | Status |
| ---------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------ |
| ~~`data-safety`~~ | ~~a canary file in the shared download root survives service startup~~ | **struck** - the assertion is vacuous; see below                              | struck |
| `reverse-proxy`  | Caddy starts, routes to a stub backend, serves 200                  | every public service depends on it; a routing regression is invisible to a build | **done** |
| `monitoring`     | Prometheus starts, loads rules, scrapes a target                    | rule and config errors only surface at activation                                | **done** |
| `digital-garden` | the generator builds a vault and the result is served                | the failure mode is a _successful_ build and an empty site                       | **done** |
| `media-stack`    | the arr services reach their ports                                  | the largest module, and the one with the most moving parts                       | waiting on the move off containers |

The original ordering put `data-safety` first, and ADR 0003 sharpened the case: the recent data loss was one root cause - LazyLibrarian's PostProcessor pointed at the shared download root - firing twice, two days apart, for 3.68 TiB, and ADR 0003 established that no arrangement of bind mounts can prevent a recurrence for the services that hardlink, because the kernel will not link across a mount boundary. The conclusion drawn from that - _therefore the test is the only thing that covers it_ - did not follow, and is corrected below. It is a good example of a real argument for needing something being mistaken for evidence that the proposed something works.

`digital-garden` is now first, and for the reason it was always ranked highly: it is the one place where the current gate is actively misleading, because a broken plugin index produces a build that succeeds.

### Cost and risks

- ~~**KVM.** NixOS tests need it. GitHub's free runners have historically been inconsistent here.~~ **Answered on the first run: KVM is present and enabled.** Details below; the advice to verify early was right, and it was cheap - a trivial local test up front, then a step in the workflow that says which case CI is in.
- ~~**Runtime.** Minutes per test.~~ **Measured: seconds, not minutes**, and inside the slowest host build, so the gate is no slower. Below.
- **Maintenance.** A flaky VM test is worse than no test, because it trains you to re-run the gate. Prefer few, sharp assertions over broad ones. Still the live risk, and the only one of the three that cannot be settled by measuring once - see the four failure modes recorded above, three of which produced a test that passed when it should not have.

### Done when

At least one test exists, the gate runs it, and a deliberately broken service configuration fails CI rather than merging.

### What landed

`checks/`, wired into `flake.nix` as `checks.x86_64-linux` and therefore picked up by `nix flake check` in the existing `flake-check` job - no workflow changes, as the approach above predicted.

- `checks/default.nix` - the index, and where `alert-rules` moved to from `flake.nix`.
- `checks/lib.nix` - `mkTest`, a `runNixOSTest` wrapper supplying the `specialArgs` this repo's modules are written against. `self` is not optional; several modules reach into `self.packages`.
- `checks/stub-secrets.nix` - the secret stubbing, discussed below.
- `checks/monitoring.nix`, `checks/reverse-proxy.nix` - the two tests.

Restricted to `x86_64-linux` rather than `forAllSystems`. Every host is x86_64, and a NixOS test for another system makes `nix flake check` evaluate an entire foreign NixOS closure only to decline to build it.

`ci.yml` gained a step that reports whether `/dev/kvm` exists on the runner. It fails nothing - it exists so that a gate which suddenly got five times slower has an explanation in its own log rather than being a mystery. That is the "verify early" from the risks section, moved into the pipeline instead of being done once by hand and forgotten.

**Secret stubbing went with option two, roughly.** Each test hands `stub-secrets.nix` a name-to-content map; it overrides `sops.secrets.<name>.path` and `sops.templates.<name>.path` to plaintext fixtures in the store, and disables the installer that would otherwise try to decrypt the real file. What it deliberately does not do is delete the module's `sops.secrets.<name>` declarations - those stay, so the wiring between a module and the secret names it consumes is still covered, and only the decryption is replaced. The honest cost is that these tests prove nothing about sops itself. Option three - a throwaway age key committed here with an encrypted fixture - remains available for a test that needs to cover the sops wiring rather than route around it.

One wrinkle worth knowing: sops-nix installs secrets from an activation script or a systemd unit depending on `useSystemdActivation`, and the stub disables both rather than depend on which upstream default is in force.

### Evidence, 2026-08-16

Both tests pass locally, on KVM:

```
vm-test-run-monitoring>      test script finished in 59.81s
vm-test-run-reverse-proxy>   test script finished in 16.61s
```

`monitoring` asserts three things, in increasing order of what they are worth. That Prometheus starts at all with the config `monitoring.nix` assembles - the `alert-rules` check validates one file in isolation and says nothing about the scrape jobs, relabelling or alertmanager block around it. That the rule file is loaded _by the running server_, with `NixosDeployFailed`, `NixosDeployStale` and `NixosVerifyFailed` present in `/api/v1/rules`. And that a deployment metric written by `deploy-metrics.nix` travels the whole chain - `.prom` file, node_exporter's textfile collector, scrape, query - which is four independent pieces whose failure is completely silent, because a broken link means the alerts simply never fire.

`reverse-proxy` asserts that Caddy accepts the generated Caddyfile (it validates at startup and refuses to run on a bad one, so an active unit means every directive parsed, including those reachable only through a rate limit profile), that a request reaches the backend, that the backend sees the `header_up` values `mkProxyHost` sets, and that the `localOnly` branch is the one actually taken - security headers present on the public vhost and absent on the LAN-only one.

**The "done when" is met, and was checked rather than assumed.** `deploy-metrics.nix` line 130 sets `cg.service.monitoring.textfileCollector.enable = true`, overriding a `mkDefault` that would otherwise leave the collector off on `homelab01`; it is a real bug that was really made once. Flipping that `true` to `false`:

```
$ nix build .#nixosConfigurations.homelab01.config.system.build.toplevel
BUILD_EXIT=0                                    # the existing gate is happy

$ nix build .#checks.x86_64-linux.monitoring
!!! Test "deployment metrics reach Prometheus" failed
CHECK_EXIT=1                                    # the new one is not
```

That is the whole argument for item 4 in six lines: a change that builds perfectly, would have merged, would have deployed, and would have silently stopped the deployment pipeline reporting on itself.

### Four things that only show up by running it

All four produced a test that looked right and was not. Recorded because three of them fail _open_.

- **`auto_https off` does not move the listener.** The first attempt at serving the vhosts over plain HTTP set it, on the reasonable-sounding assumption that disabling automatic HTTPS makes a bare-hostname site listen on 80. It does not: Caddy sat on 443 with no certificate and every request failed. The fix was better anyway - `tls internal` through the module's own per-service `extraConfig`, so the sites are served over real TLS by Caddy's own CA and the only thing substituted is the issuer.
- **HTTP/2 lowercases header names.** Asserting `"X-Frame-Options: SAMEORIGIN" in response` fails over TLS. The dangerous half is the neighbouring subtest: `assert "X-Frame-Options" not in response` was passing _for every possible input_, and would have gone on passing after the header was deleted from the module. An absence assertion that can never fail is worse than no assertion, because it is counted.
- **The test driver runs commands under `pipefail`.** `curl -sf … | grep -q x` exits non-zero on a _successful_ match: `grep -q` returns at the first hit, curl takes EPIPE, and the pipeline reports the failure. The symptom is a condition that is already true timing out. Redirect to a file and grep the file.
- **`wait_for_unit` never succeeds for a `Type=oneshot` without `RemainAfterExit`.** `nixos-deploy-metrics` reads `inactive` the moment it succeeds. This is the same trap item 3 documents for `criticalUnits`, met from the other direction.

### The `data-safety` test does not survive contact

It was first on the candidate list, ADR 0003 sharpened the case for it, and it is the one test here that cannot be written as specified. Two reasons, and the second is the one that matters.

**It cannot run in this harness.** `sonarr`, `radarr`, `cross-seed` and `qbittorrent` are all `virtualisation.oci-containers` services pulling `:latest` from a registry with `--pull=newer`. NixOS tests run inside the Nix build sandbox, which has no network, so those containers cannot start. This is not fatal on its own - `dockerTools.pullImage` is a fixed-output derivation and so _is_ allowed to fetch, which would let the images be pinned by digest and loaded into podman offline. That was not attempted here. It costs a pinned digest and hash per image, permanently, in exchange for testing an image that is by construction not the `:latest` the host will run.

**More decisively, the assertion is vacuous.** "A canary file in the shared download root survives service startup" would pass on an empty configuration, because a freshly started arr container with no `/config` does not post-process anything. The loss it models was not a startup behaviour: it was LazyLibrarian's PostProcessor, _configured_ to point at the shared download root, doing post-processing. Reproducing that means driving a service through a real post-processing run with its real settings - and those settings live in a service-managed SQLite database, not in Nix. So the "three lines per service" this plan budgeted buys a green check that would not have caught the incident it was written for, which is strictly worse than an acknowledged gap.

That does not make the property unenforceable, it makes it the wrong shape for this harness. Cheaper things that would have caught the actual incident, in rough order of value per line:

- an assertion over the _evaluated configuration_ - no VM needed - that no service's output or post-processing directory is equal to, or a parent of, `${dataPath}/downloads`. That is the invariant that was violated, it is checkable statically, and it is the one thing ADR 0003 established confinement cannot enforce;
- a periodic canary on the hosts: a sentinel file in the download root, alerting through the existing textfile metrics if it disappears. Detection rather than prevention, but it covers every service including the ones no test will ever drive, and it rides a stack that already exists.

**Decided, 2026-08-16: stop trying to prove the negative.** No test can establish that a service will never be told to do something destructive later, and a suite that implies otherwise is worse than an acknowledged gap - it is the same failure as the vacuous canary, just more expensive. The two items above are worth having on their own merits, one as a static invariant over configuration and one as detection, and neither is dressed up as proof. `data-safety` is struck from the candidate list rather than deferred.

**Also decided: the container services are on their way out.** The intended direction is nixpkgs' own service modules instead of `oci-containers`, for the complexity they add as much as for anything here. That retires the first half of the blocker above on its own schedule, and it changes the arithmetic for `media-stack`: a natively packaged `sonarr` needs no registry, no pinned digest and no `podman load`, so the test that is currently blocked becomes ordinary. Worth knowing before anyone invests in pinning image digests to work around a constraint that is being removed anyway.

**Item 4 is not finished**; what is finished is the harness, the two tests that pay for it, and a candidate list that no longer contains a test which would have passed while the thing it named went on being possible.

### Still outstanding

- ~~`digital-garden`~~ **done** - see below.
- `media-stack` - the largest of the candidates, and now waiting on the migration off `oci-containers` rather than on anything in this harness. Taking it before that migration means pinning image digests that are about to become irrelevant.
### KVM and cost, answered on the first run (#32)

Both open questions from "Cost and risks" are now measured rather than guessed, and both came out well.

**KVM is available on GitHub's standard runners.** The `nix-installer-action` reported `kvm: true` and set `DETERMINATE_NIX_KVM=1` on its own, and the new step confirmed it:

```
##[notice]/dev/kvm present - NixOS tests run accelerated
```

So the plan's worry about GitHub's free runners being inconsistent here does not apply to the current image. No TCG fallback, and no need for a larger runner.

**The tests cost the gate nothing.** They run in parallel, and `flake-check` still finishes inside the slowest host build:

```
flake check      3m18s     reverse-proxy  28.6s
build xps15      4m5s      monitoring     71.0s
build homelab01  2m1s
```

Which answers the auto-merge question the risks section raised: the tests do not delay the nightly lock PR, because a longer job already sets the pace. The number to watch is `flake-check` overtaking `build xps15`, not the absolute runtime.

**One thing to fix before the next test lands:** the per-test timeout is nixpkgs' default of 3600s. Against measured runtimes of under 90 seconds that turns a hung VM into an hour-long job. `digital-garden` is the first candidate with a plausible reason to hang - a Quartz build is real work, not a service waiting on a port - so it should arrive with a tighter timeout. Done: `mkTest` now sets `globalTimeout` to 600s for every test, as a `mkDefault` so a test with a real reason to be slower can raise it and say why.

### `digital-garden`, 2026-08-16

Landed, passing in 28 seconds. `source = "obsidian-sync"` reads the vault from disk instead of cloning it, so the builder runs entirely offline; the sync service that would normally fill that directory is disabled and the vault is staged from a three-note fixture - one published, one not, and one with no frontmatter at all.

The assertions are written the other way round from the obvious ones. A test that checked only that the published note appears would pass just as happily if the filter had copied the whole vault, so the private markers must appear **nowhere** in the served tree - deliberately `grep -r` over all of it rather than over the rendered page, because a leak would most plausibly surface in `static/contentIndex.json` or `index.xml`, which are precisely the two files nobody looks at.

**Every assertion here was checked against a deliberate break**, because on this test more than the others a false pass is the expected failure mode:

| Break                                                    | Host build | Test  | Caught by                                     |
| -------------------------------------------------------- | ---------- | ----- | ---------------------------------------------- |
| `-d ${stateDir}/content` → `-d ${vaultDir}`               | exit 0     | fails | flattening/URL assertions                     |
| fixture note flipped to `publish: true`                   | -          | fails | staging tree, then the leak grep              |
| `cat … >> custom.scss` → `cat … > custom.scss`            | exit 0     | fails | `.flex-component` missing from the served CSS |

Two of those three build perfectly and would have merged, deployed and served.

**The stylesheet assertion had to be rewritten, and the first version was worthless.** It asserted `len(index.css) > 10000`, on the reasoning that a working build produces 59KB. Overwriting `custom.scss` instead of appending - the exact bug the module's own comment warns about - produces **40KB**, because every other component stylesheet still compiles; only base.scss is lost. Any threshold loose enough not to be brittle sits far below 40KB and therefore catches nothing. It now asserts that `.flex-component`, `.desktop-only` and `.table-container` are present in the served CSS, which come from base.scss and nowhere else. That is the second assertion in this suite that looked right, passed, and would have gone on passing after the thing it named broke.

**An unplanned finding: the defence in depth is real.** Pointing Quartz at the vault instead of the staging tree did _not_ leak the unpublished note - Quartz's `explicit-publish` plugin caught what publish-filter.py was no longer catching. The module's header describes the filter as the boundary and the plugin as defence in depth; that relationship was an assumption until this break demonstrated the second layer holding on its own. The break was still caught, by the flattening assertions, because building from the vault also abandons the flat-URL promise.

**Also worth recording:** `digital-garden.nix` adds a Caddy virtual host but never enables Caddy - on a host that arrives via `cg.service.reverse-proxy`. Enabling the garden alone on a host would build a site that nothing serves. Not changed here, since both servers run the proxy, but it is a coupling that is invisible until it bites.

---

### `digital-garden` again, 2026-08-24: the generator changed underneath it

The site moved from Quartz to Hugo, and the test had to be rewritten rather than adjusted - which is the interesting part, because it was the *assertions* that were generator-shaped, not the properties.

**The failure mode the test guards against changed, and shrank.** Under Quartz it was a build that succeeded while producing a featureless site: a plugin that failed to instantiate left an undefined in the component list, and a plugin index regenerated without `dist/` yielded a site that was green all the way through and empty. Hugo removes most of that class - a template that does not resolve is a build error, and there are no plugins to resolve. What remains is narrower and still real: a *missing* template is not an error. Hugo skips the pages it would have rendered and reports success. The first Hugo build of this site emitted the home page and nothing else, and said `Total in 40 ms` while doing it. Every assertion that looked only at the home page passed.

So the stylesheet assertions - `.flex-component`, `.desktop-only`, `.table-container`, chosen because they came from `base.scss` and nowhere else - were retired along with the file they were defending, and replaced by assertions that *every published note became a page*, plus that it is served on the first request rather than after a 308.

**Three assertions were coupled to Quartz's output layout, not to anything the site promises.** `test -f public/index.css` (Hugo fingerprints its CSS, so there is no fixed name), `cat public/on-gates.html` (Hugo writes `on-gates/index.html`), and `url=../on-gates` in the alias redirect (Quartz wrote it relative, Hugo absolute). All three were checking the shape of the output tree, which is the generator's business, when what matters is what a reader receives. They now read the stylesheet URL off the page that links it, request pages over HTTP, and match the redirect target loosely.

**The defence in depth had to be rebuilt, and this time it was tested.** The 2026-08-16 entry recorded an unplanned finding: breaking `publish-filter.py` did not leak the unpublished note, because Quartz's `explicit-publish` plugin caught what the filter no longer did. Hugo has no equivalent, so that layer left with Quartz. It now lives in the builder instead - a `grep` over the staging tree that refuses to build if any staged note is missing `publish: true` - which is a better home, because it no longer depends on which program renders the tree.

Then it was actually broken, twice, to check it holds:

- Making `is_published` return `True` for every note **did not** reach the new guard. The filter has its own pre-write re-check - it re-serialises the frontmatter and drops any note that does not still carry the marker - and that caught it first. Worth recording, because it means the filter is internally two layers, not one, and the obvious way to break it exercises the wrong one.
- Removing that second check as well produced the intended result: `published 3 notes`, then `staged notes are missing 'publish: true'; refusing to build: rates-and-figures.md`, and the unit failed. The unpublished note never reached the generator, the served tree, or the search index.

That is three independent layers between an unmarked note and a reader, and now two of them have been demonstrated rather than assumed.

**A property the test never had, and now does.** Search is Pagefind, which indexes the rendered HTML rather than the markdown. That makes "the index covers the published set" checkable in a way it was not before: the test asserts a page count from `pagefind-entry.json` and that the published marker appears in the decompressed fragments. An index that exists but covers nothing is exactly what a build that skipped its pages leaves behind, and it would otherwise be served with a 200.

## 5. Service confinement _(moved out - see [ADR 0003](../adr/0003-service-confinement-is-bounded-by-hardlinking.md))_

Removed from this plan. It was prevention rather than deployment hardening, and it arrived late in the discussion that produced ADR 0002 - the "decide first" this section used to carry has been decided by moving it out.

It also turned out to be mostly infeasible, for a reason worth knowing before anyone proposes it again. Narrowing a service's view means per-service bind mounts, and the kernel refuses to hardlink across a mount boundary even within one filesystem - measured on both hosts and both filesystems, with identical `st_dev` on each side and `EXDEV` anyway. The wholesale `/data` mount every service gets is therefore load-bearing for hardlinked imports, not conservatism.

What survives is one service and a redirection of effort: `bazarr` never hardlinks and can be narrowed, and the property confinement would have enforced is now something for the `data-safety` test in item 4 to assert instead. That raises item 4's value rather than lowering it - the test covers every service, including the ones confinement cannot reach.

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
