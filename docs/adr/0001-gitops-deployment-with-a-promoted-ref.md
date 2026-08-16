# ADR 0001: GitOps deployment with a promoted ref

- **Status:** Accepted, except §1a - superseded by [ADR 0002](0002-protect-at-activation-not-in-the-rollout.md)
- **Date:** 2026-08-15
- **Related Artefacts:**
  - Superseded in part by: ADR 0002 (§1a, the staged rollout)
  - Implemented by: `.github/workflows/ci.yml` (build gate + promotion), `.github/workflows/flake-update.yml` (lock updates), `system.autoUpgrade` on each host
  - Supersedes: the flake-update and apply logic in `packages/nixos-upgrade-scripts`
  - Depends on: the `protect-main` repository ruleset, the `corygyarmathy-dotfiles` Cachix cache

## Context

Three machines run this flake: two servers (`homelab01`, `homelab02`) and one laptop (`xps15`). Keeping them current has been split across two mechanisms that do not know about each other.

The servers pull. `system.autoUpgrade` fetches `github:corygyarmathy/dotfiles#hostname` nightly and rebuilds. This works and needs no inbound access, but it follows `master` unconditionally: CI runs on push, so a commit that fails to build is already what the servers will fetch at 04:00. The build result and the deployment are racing, and nothing enforces the ordering.

The laptop pushes. `packages/nixos-upgrade-scripts` is 1834 lines of Python that runs `nix flake update`, builds in the background, drives a waybar indicator, applies on confirmation, and commits the result. It conflates two jobs: deciding what the _fleet_ should run, which is a repository-wide question, and presenting an upgrade to an interactive user, which is genuinely local. Because the first job lives on the laptop, `flake.lock` only moves when the laptop is on - so server package versions are gated on a machine that has nothing to do with them.

Neither path reports. A failed rebuild, a service that does not come back, or a host that quietly stops upgrading altogether are all invisible until noticed by hand. This is the gap that matters most: the failure mode of an automated deploy pipeline is not a loud error, it is silence.

A Prometheus + blackbox + Alertmanager stack already runs on both servers, with HTTP probes on every public service and an alert on failed systemd units. The reporting primitives exist; they are simply not connected to deployment.

## Decision

Keep the pull model - it is correct for hosts with no inbound access and no dependency on an operator's machine - and add the two things it lacks: a gate and a report.

**1. Hosts follow a promoted ref, not `master`.** A `deploy` branch is fast-forwarded to `master` by CI, and only after every host configuration builds. `system.autoUpgrade` points at `github:corygyarmathy/dotfiles/deploy#hostname`. A host can therefore only ever fetch a revision proven to evaluate and build _for that host_. `master` stays the integration branch and may be red; `deploy` is the fleet's contract.

**1a. The servers roll out in stages.** _Superseded by ADR 0002: both servers now follow `deploy`, and the protection this section sought is provided at activation instead._ `homelab01` follows `deploy` and takes each promoted revision the night it lands. `homelab02` follows `deploy-stable`, which a scheduled job advances to whatever `deploy` pointed at 24 hours earlier. The two servers are not interchangeable: `homelab02` holds the ZFS pool and exports the NFS storage `homelab01` mounts, so it is the host whose failure cascades. Staging the rollout means a kernel or systemd bump that fails to boot takes out the compute node while the data node keeps serving.

The soak is worth less than it looks for host-specific packages - a regression in ZFS or qBittorrent will not surface on `homelab01`, which runs neither - but the shared base (kernel, systemd, nix, glibc) is where an unattended update does catastrophic rather than annoying damage, and that is exactly what a day of uptime on another machine exercises.

The lag is measured in elapsed time, not health: it establishes that `homelab01` has _had_ the revision for a day, not that `homelab01` is well. Closing that gap needs the deployment metrics below, at which point the same job can gate on them.

**2. `flake.lock` updates move to CI.** A scheduled workflow builds every host toplevel, runs `nix flake update`, builds again, and opens one pull request carrying the per-host `nix store diff-closures` output in the commit body. It auto-merges on green. Lock freshness stops depending on the laptop being awake, and server packages update on the same cadence as everything else.

`nix flake update` runs exactly once, and every host is diffed against that one lock. Updating per-host would race - nixpkgs moves between jobs, and the hosts would end up proposing different revisions of the same update. The per-host builds are split across runners because computing a delta means holding two complete system closures at once, and three hosts times two closures does not fit on one.

If every host's closure is identical afterwards, no pull request is opened: the update moved only lock metadata (`rev`, `narHash`) without changing a single package, so there is nothing to review and nothing worth recording in `git log`.

**3. Pinned packages update through `passthru.updateScript`.** Packages that cannot move via `nix flake update` - an upstream tag, an npm release - declare their own updater, and a workflow discovers and runs them. `nix-update` covers the common cases; bespoke scripts handle the rest. Attaching the updater to the package rather than listing packages in YAML means adding a package does not mean editing CI.

Participation is an explicit `passthru.autoUpdate` flag rather than the presence of `updateScript`, because nixpkgs' `buildPythonApplication` sets a default `updateScript` of its own. Inferring from that swept up three packages that are our own code, with no upstream to track at all.

Every updater obeys one contract: an argv list, run from the repository root, mutating the working tree, silent when already current, and on a change printing a one-line summary first. `nix-update` does not satisfy that by itself - it narrates to stdout unconditionally, which on a real update would become the pull request title - so it is wrapped.

Only three packages qualify. `comskip` tracks an upstream tag and `obsidian-headless` an npm release; `quartz` has ~42 npm-pinned plugins that nothing else would ever move. The remaining packages are our own code, where the version string tracks nothing. `argtable2` is deliberately left out: upstream last moved in 2024 and its tag namespace contains `vjonathanmarvens-0.1.1`, so an automated updater has more ways to go wrong than right.

Quartz's own release is _not_ automated, only its plugins. Its derivation carries a page of workarounds tied to how v5 resolves plugins, and getting that wrong produces a build that succeeds and a site that is silently featureless - precisely the failure the CI gate cannot see.

These pull requests are not auto-merged, unlike lock bumps. Crossing an upstream release boundary is where "it built" is weakest as evidence.

**4. Reporting rides the monitoring stack that already exists.** Hosts export deployment state as node_exporter textfile metrics, recorded from `nixos-upgrade.service`'s `ExecStopPost` where `SERVICE_RESULT` is available - the same mechanism the restic backup metrics already use. No new services; the existing `probe_success` and `node_systemd_unit_state` rules already cover "the service did not come back".

Three alerts, in ascending order of how badly they are needed:

- `nixos_deploy_last_run_success == 0` - the upgrade failed. Largely redundant with the existing failed-unit alert, but explicit and survives a restart of the unit.
- `nixos_deploy_last_run_timestamp_seconds` older than 48h - **the host stopped upgrading**. Nothing else catches this: no unit has failed, no probe is down, the machine is simply falling behind in silence. This is the alert the whole exercise is for.
- `nixos_deploy_pending_reboot == 1` with a staged timestamp older than 26h - a generation is built and staged but never activated.

That third one exists because of what `nixos-upgrade` actually does. It runs `nixos-rebuild boot` first, then reboots only if the kernel changed _and_ the clock is still inside the reboot window. A build that runs long - entirely plausible for a large nixpkgs bump on this hardware - pushes the clock past the window, at which point the unit prints `Outside of configured reboot window, skipping.` and **exits zero**. A host can sit on an unactivated kernel indefinitely while reporting success every night. Nothing in the original plan would have caught that.

The duration is carried in a staged-timestamp metric rather than a long Prometheus `for:` clause, because Prometheus restarts on every deploy and a restart resets a pending alert's timer - a `for: 26h` on a daily-deploying host would never mature.

Alert rules are validated by `promtool check rules` as a flake check, so a malformed rule fails the CI gate. Building a host proves its Nix evaluates, not that the config files it ships are valid; a bad rule builds perfectly and then takes Prometheus down on activation.

**5. CI builds are shared through a binary cache.** CI pushes to Cachix; hosts substitute from it. Without this, the same closure is built four times - once in CI and once per host - on hardware chosen for storage and transcoding rather than compilation.

**6. Interactive deployment stays out of the pipeline.** Iterating on a service is not a deployment; requiring a commit, a push, and a CI round-trip to test a config change would make the pipeline something to route around. `nixos-rebuild --target-host` from the working tree remains the supported path for that, and the nightly pull reconciles the host afterwards.

The laptop keeps a reduced build-and-notify unit, because `system.autoUpgrade` has no notify-then-confirm mode and interrupting an interactive session to switch generations is not acceptable. Everything else it currently does - updating the lock, committing, deciding what to build - belongs to CI and is removed.

## Consequences

**Positive**

- A broken `master` cannot reach a host. The gate is structural rather than a matter of timing.
- Lock updates no longer depend on any particular machine being online, and server packages track the same lock as everything else.
- `deploy` is a single, inspectable answer to "what is the fleet supposed to be running", and holding a deployment back is just declining to promote.
- Silent failure becomes loud: a host that stops upgrading alerts on staleness, which is the failure this pipeline is otherwise most likely to hide.
- `packages/nixos-upgrade-scripts` loses most of its reason to exist.

**Negative**

- **Building is the only pre-deploy gate, and building is not working.** A package that compiles and then fails at runtime will auto-merge and deploy. Mitigated after the fact by the alert rules, and to be narrowed by NixOS VM tests added per service module. Accepted deliberately: the alternative is manual review of every nixpkgs-unstable bump, which is the status quo that does not happen.
- Unattended nixpkgs-unstable now reaches servers without a human ever looking. This is the point, but it is a real change in posture.
- A required status check whose name no longer matches the CI job blocks every merge with no bypass. Renaming the gate job means updating the ruleset in lockstep - the gate job exists partly to make that a one-line, rarely-touched name.
- The laptop's auto-upgrade follows the promoted ref, so uncommitted local config is no longer picked up automatically. Deliberate - the laptop should not silently run a configuration CI never saw - but it is a behaviour change to get used to.
- Cachix is an external dependency in the deploy path. Hosts degrade to building from source if it is unreachable, so it is a performance dependency rather than a correctness one.

## Alternatives considered

- **Push-based deployment with `deploy-rs` or `colmena`.** Better ergonomics for many hosts, and `deploy-rs` adds magic rollback, which is real insurance against locking yourself out with a firewall or network change. Rejected as the _primary_ mechanism because it inverts the connectivity requirement: something must reach the hosts, which means either the laptop is online - the constraint being removed - or CI gets inbound access to the homelab. Worth revisiting for the rollback alone if a host is ever bricked, or past roughly four machines.
- **Keep hosts on `master` and rely on CI running first.** No new branch, no promotion job. Rejected: it is a race, not a gate. CI usually finishes before 04:00, and "usually" is the whole problem.
- **Per-host promotion branches (`deploy/homelab01`).** A _different_ idea to the staged rollout in 1a: there, both servers traverse the same sequence of revisions at different times; here, each host would advance independently so one host's build failure could not block another's deployment. Rejected as premature at two servers, and it trades a fleet that is consistent by construction for one that can drift arbitrarily. Reconsider when hosts diverge enough that one failing build routinely blocks unrelated hosts.
- **Staggering the servers by time of day instead of by revision.** Moving `homelab02`'s upgrade a few hours after `homelab01`'s needs no second ref. Rejected because it is not a soak: in a pull model both hosts fetch whatever the ref points at when they wake, so a later hour gets the _same_ revision the same night, and the failure it is meant to catch happens at 3am with nobody watching either way.
- **`DeterminateSystems/update-flake-lock` for the lock workflow.** Well-maintained, and its PR body lists input revision changes. Rejected because it does not build what it proposes and reports input revisions rather than package deltas; `nix store diff-closures` per host answers "what actually changes on my machines", which is the question worth asking.
- **Self-hosted Attic instead of Cachix.** No external dependency and full control. Rejected for now: CI can only push to it if the homelab is reachable from GitHub, which reintroduces the inbound-access problem the pull model exists to avoid. Cachix is free for a public repository and needs no such exposure.
