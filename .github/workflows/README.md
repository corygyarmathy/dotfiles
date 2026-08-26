# The deployment pipeline

How a commit becomes a running machine, what runs on a schedule, and what to do when the pipeline jams.

This document describes _behaviour_. The reasoning - what was rejected, and why the design looks like this - is [ADR 0001](../../docs/adr/0001-gitops-deployment-with-a-promoted-ref.md); the gaps it does not yet close are in [the hardening plan](../../docs/plans/deployment-hardening.md). Each workflow file also carries a header comment explaining why _that file_ is shaped the way it is. Anything spanning more than one workflow belongs here instead.

## The refs

`master` is the integration branch and may be red. Nothing follows it.

**`deploy` is the fleet's contract, and the only promoted ref.** CI fast-forwards it to `master` only after every host configuration builds, so a host can never fetch a revision that fails to build for it.

| Ref      | Followed by                | Takes a revision         |
| -------- | -------------------------- | ------------------------ |
| `deploy` | homelab01, homelab02, xps15 | the night it is promoted |

There used to be a second ref, `deploy-stable`, which trailed `deploy` by 24 hours and which homelab02 followed so that the storage node soaked each revision on homelab01 first. [ADR 0002](../../docs/adr/0002-protect-at-activation-not-in-the-rollout.md) retires it: the lag measured elapsed time rather than health, nothing read the result, and it made the host holding the data the host least able to receive a considered change. Protection now happens at activation on each host instead.

`deploy` never holds a commit that is not already on `master`. It is a marker pointing into `master`'s history, and its position _is_ the deployment policy. The native operation on it is therefore `git push <sha>:refs/heads/deploy` - moving a pointer to a deliberately chosen commit - never a merge or a rebase.

The laptop follows `deploy` too, but never switches on its own: it builds in the background and waits to be told, via a waybar indicator.

## The workflows

| Workflow             | When                        | Does                                                               |
| -------------------- | --------------------------- | ------------------------------------------------------------------ |
| `ci.yml`             | every PR and push to master | builds all three hosts, `nix flake check` (incl. the VM tests in `checks/`), fast-forwards `deploy` |
| `flake-update.yml`   | daily, 15:00 UTC            | `nix flake update`, per-host closure diff, PR, auto-merge on green |
| `package-update.yml` | Mondays, 03:00 UTC          | runs each package's own updater, one PR per package                |
| `dependabot-auto-merge.yml` | every Dependabot PR  | schedules the merge; `nixos ci` is still the gate                  |

CI builds are pushed to a [Cachix](https://cachix.org) cache that the hosts substitute from, so a closure is built once rather than once per machine.

Lock updates auto-merge when green. Package updates do not - they cross an upstream release boundary, where "it built" is the weakest form of evidence.

### Dependabot

`.github/dependabot.yml` covers the actions pinned inside these workflows - the one dependency surface the two Nix updaters cannot reach. It has no Nix ecosystem, so it never touches `flake.lock` and cannot compete with `flake-update.yml`. A second, dormant entry watches `packages/project-launcher`, which is stdlib-only today.

Action bumps auto-merge without being read, which is a deliberate trade rather than laziness: the diff is a SHA, so review conveys nothing, and the safety comes from a 7-day `cooldown` instead - long enough that the ecosystem finds a compromised release before this repo consumes it, and short enough that nothing rots. Security updates bypass the cooldown by design. Majors are split into their own PR so a break is attributable to one action rather than a batch of six.

That last point matters more here than it looks. `ci.yml` only ever runs three of the six pinned actions, so a bump to `upload-artifact`, `download-artifact` or `create-pull-request` goes green from a workflow that never executed it - see the invariant below.

### Code scanning

CodeQL runs on every PR and weekly, over `actions`, `go` and `python`. It is **not** in this directory: it uses GitHub's _default setup_, so the workflow is generated and versioned server-side rather than committed here. Reading `.github/workflows/` therefore does not tell you the whole CI story. The config is still inspectable from the CLI, which is the intended way to audit it:

```
gh api repos/{owner}/{repo}/code-scanning/default-setup
```

Default setup rather than advanced is deliberate. Advanced setup would put a generated `codeql.yml` here - satisfying the same config-as-code instinct as the rest of the repo - at the cost of three more SHA-pinned actions for Dependabot to bump and ownership of keeping the CodeQL bundle current. It buys custom queries, `paths-ignore` and custom build steps, none of which this repo needs. The two settings that actually matter, `query_suite` and `threat_model`, are configurable in default setup anyway.

**`query_suite` is `extended`, `threat_model` is `remote`.** The threat model is the interesting one, and it is set that way from evidence rather than by default. `remote_and_local` was tried on 2026-08-17: it marks local files, argv and environment variables as tainted, which sounds right for a repo whose Python is almost entirely local-input CLI tools. It produced 54 alerts, all of them false positives:

- two `py/command-line-injection` rated _critical_, both at a `subprocess.run` taking an argv **list** with no `shell=True`. There is no shell to inject into. (A real but much smaller nit does live there: no `--` separator, so a filename starting with `-` would be read as an `ffprobe` flag.)
- around fifty `py/path-injection`, mostly in `publish-filter.py`, where every write goes through `Path.name`. That discards all directory components, so traversal is structurally impossible - CodeQL simply cannot see `.name` as a sanitizer.

The reason it is all noise is that `remote_and_local` assumes an attacker who controls local files, argv or env, and for these tools the operator supplying those paths is a systemd unit with fixed arguments. There is no privilege boundary for the taint to cross. Reverting to `remote` returns the repo to zero alerts while `extended` keeps the broader non-taint queries. A permanently noisy Security tab is worse than a quiet one, because it is the one you stop reading.

**Do not expect CodeQL to protect `publish-filter.py`.** Its failure mode is publishing a note that was never marked for publication, which is a logic property, not a taint path. The VM test in `checks/` is the only real control there, and the `remote_and_local` experiment above is evidence for that rather than against it.

### How a night runs

All times Perth (UTC+8), which is what the hosts are set to. Both hosts add up to 10 minutes of jitter.

| Perth | UTC   | Event                                                                                                                      |
| ----- | ----- | -------------------------------------------------------------------------------------------------------------------------- |
| 23:00 | 15:00 | `flake-update` opens its PR; on green it auto-merges, and that push to `master` triggers `ci.yml`, which promotes `deploy` |
| 04:00 | 20:00 | homelab01 fetches `deploy` and rebuilds                                                                                    |
| 04:15 | 20:15 | homelab02 fetches `deploy` and rebuilds                                                                                    |

Both servers land on the same revision the same night. The 15 minute offset is not a soak and is not load-bearing - homelab01 mounts NFS from homelab02, and two servers rebooting into a new kernel simultaneously is worth avoiding for its own sake.

## Invariants that will bite you

**The gate job name is a required status check.** `nixos ci` in `ci.yml` is the context named by the `protect-main` ruleset. Rename the job and every merge blocks, with no bypass, until the ruleset is updated to match. Treat the two as a pair.

**A PR must be up to date with `master` before it can merge.** `protect-main` sets `strict_required_status_checks_policy`, so GitHub will not merge a branch whose base has moved since its last green run. This costs an "Update branch" click whenever two PRs are in flight at once, and it buys the thing the gate is supposed to guarantee: a PR builds `refs/pull/N/merge`, its head merged into `master` _as of that run_, so without the strict policy two independently-green PRs can merge minutes apart and produce a `master` tree that nothing ever built. That happened on 2026-08-16 - #24 and #25 landed 33 seconds apart, and #24's CI run started before #25 existed.

**The master build is not the PR build run twice.** `self.rev` is baked into `system.configurationRevision`, so the toplevel store path is a function of the commit SHA, and a squash merge always mints a new one. Master's toplevel has never been built at PR time even when the tree is identical - the run substitutes the closure and builds the rev-dependent tail on top. It is what puts the promoted closure in Cachix, so it stays even though the strict policy above already settled which _tree_ lands.

**`flake-check` boots VMs now, and its runtime depends on KVM.** `nix flake check` runs the behaviour tests in `checks/`, which are NixOS VM tests (five of them, booting concurrently via `--max-jobs 5`). With `/dev/kvm` they are bounded by the slowest test (`upgrade-verify`, ~2.5m) rather than by the number of tests; without it QEMU falls back to TCG emulation and the same tests take long enough to matter for a job that also has to promote. The job logs which case it is in rather than failing either way, so a gate that suddenly got slow says why in its own output. Adding a test that needs several minutes is a decision about the nightly lock PR's auto-merge latency, not just about coverage. The `monitoring` test shortens the warning route's production `group_wait` via `warningGroupWait` rather than waiting out five minutes; the `5m` value itself is pinned structurally by the `amtool` check.

**Never create a branch under `deploy/`.** Git stores refs as paths, so `deploy/my-branch` turns `refs/heads/deploy` into a directory and promotion fails with `directory file conflict` for as long as that branch exists. The `reserve-deploy-namespace` ruleset blocks this at the server; the failure is obscure enough to be worth naming twice.

**`deploy` rejects non-fast-forward pushes, with zero bypass actors.** Not even an admin or `GITHUB_TOKEN` can force-push or delete it. This is deliberate, and it means the recovery below requires temporarily relaxing a ruleset - there is no way around it from the client side.

**Promotion is deliberately not a force push.** `ci.yml` pushes without `--force`, so a `deploy` that has diverged fails the job loudly rather than silently discarding whatever is there. A red promote step is the pipeline working.

**`flake.lock` is CI's to move.** Running `nix flake update` by hand only creates a conflict with the nightly PR.

**`flake-update.yml` checks out and opens its PR with `FLAKE_UPDATE_TOKEN`, not `GITHUB_TOKEN`.** GitHub suppresses workflow events on PRs opened by `GITHUB_TOKEN`, so `ci.yml` would never run, the required check would never arrive, and the PR would be unmergeable forever.

**`dependabot-auto-merge.yml` needs `FLAKE_UPDATE_TOKEN` in _Dependabot_ secrets, not Actions secrets.** Workflow runs triggered by Dependabot read from a separate secret store and get a read-only `GITHUB_TOKEN`; the same name set under Actions resolves to empty there. The workflow fails with an explicit message rather than an opaque `gh` auth error, and it is not a required check, so the PR just sits unmerged. Note this is also why Dependabot PRs run without `CACHIX_AUTH_TOKEN` - harmless, because both `cachix-action` steps are `skipPush` against a public cache and the one real push is `continue-on-error`. They build slower, not wrong.

**Auto-merge must be enabled by the PAT, for the same reason the PR is opened by it.** An auto-merge inherits the actor that enabled it, so a `GITHUB_TOKEN` merge lands on `master` without triggering `ci.yml` - `promote` never runs and `deploy` silently stops tracking `master`. An actions-only bump changes no host's closure, so nothing would look broken until an unrelated merge fast-forwarded past it.

**Not every check on a PR comes from this directory.** CodeQL runs as GitHub default setup, configured server-side, so `Analyze (actions|go|python)` and `CodeQL` appear on every PR with no corresponding file here. They are not required checks and cannot block a merge; `nixos ci` is still the only gate. See "Code scanning" above for how to read the config.

**`nixos ci` passing does not mean a bumped action works.** `ci.yml` runs only `checkout`, `nix-installer-action` and `cachix-action`. `upload-artifact`, `download-artifact` and `create-pull-request` appear exclusively in `flake-update.yml` and `package-update.yml`, which are `schedule` + `workflow_dispatch` and never fire on a pull request. A green gate on those three is a check that tested something else. Expect the failure at 15:00 UTC the next day, and revert rather than debug forward.

## Knowing whether it worked

Hosts export deployment state as node_exporter textfile metrics from `nixos-upgrade.service`'s `ExecStopPost` (see `modules/services/monitoring/deploy-metrics.nix`), alerted through the Prometheus and Alertmanager stack that already runs on both servers.

| Alert                | Catches                                                  |
| -------------------- | -------------------------------------------------------- |
| `NixosDeployFailed`  | the upgrade ran and failed                               |
| `NixosDeployStale`   | **no upgrade has run in 48 hours**                       |
| `NixosRebootPending` | a generation is staged but never activated               |
| `NixosVerifyFailed`  | the upgrade succeeded and the generation came up broken  |
| `NixosRolledBack`    | a host reverted itself, and is no longer tracking `deploy` |

The middle one is the point of the exercise. A host that stops upgrading raises nothing else - no unit fails, no probe drops, it simply falls behind in silence.

The last one exists because `nixos-upgrade` runs `nixos-rebuild boot` and then reboots _only_ if the kernel changed and the clock is still inside the reboot window. A build that runs long pushes it past that window, and the unit reports success while the new kernel never activates.

The last two come from `modules/nixos/upgrade-verify.nix`, which checks a newly activated generation against the set of units that were already failing before the upgrade started, so it reports on the new generation specifically rather than on the host's general health. Rollback is currently off — it reports and alerts, and reverting is a one-line change once there is evidence about how often it would fire on a host that is actually fine.

Services that fail to come back and endpoints that stop responding are already covered by the existing `node_systemd_unit_state` and `probe_success` rules; those describe the host, these describe the deployment.

## Recovery

### `deploy` has diverged from `master`

**Symptom.** The `promote to deploy` job fails with a non-fast-forward rejection.

**Cause.** Almost always a force-push to `master`. Rewriting history does not edit commits, it creates new ones with new SHAs; `deploy` still points at the old objects. The changes are identical, but Git only reasons about ancestry, and the old tip is no longer an ancestor of the new one, so a fast-forward is impossible by definition.

**First, confirm nothing is being thrown away.** `deploy` should hold only commits that already exist on `master` under a different SHA:

```bash
git fetch origin --prune
git cherry origin/master origin/deploy | grep '^+'   # expect no output
```

Any `+` line is a commit that exists _only_ on the deployment ref - stop and work out where it came from, because realigning would discard it.

**Relax the ruleset.** GitHub → Settings → Rules → Rulesets → `protect-deploy` → Enforcement status → Disabled. Prefer the UI: the API equivalent is a `PUT`, which replaces the whole ruleset, so a mistyped call is a rewrite rather than a toggle. `gh api repos/corygyarmathy/dotfiles/rulesets` lists them if you want the IDs.

**Push the ref, with an explicit lease** so the push aborts if the remote is not where you think it is. The target is `origin/master`, since that is what it would have been fast-forwarded to anyway:

```bash
git push --force-with-lease=deploy:<old-deploy-sha> origin origin/master:refs/heads/deploy
```

**Re-enable the ruleset immediately.** An unprotected `deploy` is the real risk in this procedure, and it is the step easiest to forget once the pipeline goes green.

**Verify:**

```bash
git fetch origin --prune
git merge-base --is-ancestor origin/deploy origin/master && echo "deploy fast-forwards"
```

**Prevention.** Don't force-push `master`. `protect-main` blocks it directly, so this only happens when the ruleset is deliberately relaxed.

### A host has stopped upgrading

`NixosDeployStale` fires after 48 hours. Pull the promoted revision immediately rather than waiting for the next window:

```bash
ssh homelab01 sudo systemctl start nixos-upgrade.service
journalctl -u nixos-upgrade.service -n 50   # on the host
```

If it fails to build, the same revision will fail identically in CI - reproduce it locally with `nixos-rebuild build --flake .#homelab01` rather than debugging on the host.

## Changing the pipeline

**Adding a host** means adding it to the `build` matrix in `ci.yml`. A host that CI does not build is a host the gate does not protect.

**Adding an auto-updating package** means editing the package, not `package-update.yml`, which discovers anything declaring `passthru.autoUpdate`. The updater contract is in that workflow's header comment.
