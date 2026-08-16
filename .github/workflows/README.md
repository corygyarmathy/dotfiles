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
| `ci.yml`             | every PR and push to master | builds all three hosts, `nix flake check`, fast-forwards `deploy`  |
| `flake-update.yml`   | daily, 15:00 UTC            | `nix flake update`, per-host closure diff, PR, auto-merge on green |
| `package-update.yml` | Mondays, 03:00 UTC          | runs each package's own updater, one PR per package                |

CI builds are pushed to a [Cachix](https://cachix.org) cache that the hosts substitute from, so a closure is built once rather than once per machine.

Lock updates auto-merge when green. Package updates do not - they cross an upstream release boundary, where "it built" is the weakest form of evidence.

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

**Never create a branch under `deploy/`.** Git stores refs as paths, so `deploy/my-branch` turns `refs/heads/deploy` into a directory and promotion fails with `directory file conflict` for as long as that branch exists. The `reserve-deploy-namespace` ruleset blocks this at the server; the failure is obscure enough to be worth naming twice.

**`deploy` rejects non-fast-forward pushes, with zero bypass actors.** Not even an admin or `GITHUB_TOKEN` can force-push or delete it. This is deliberate, and it means the recovery below requires temporarily relaxing a ruleset - there is no way around it from the client side.

**Promotion is deliberately not a force push.** `ci.yml` pushes without `--force`, so a `deploy` that has diverged fails the job loudly rather than silently discarding whatever is there. A red promote step is the pipeline working.

**`flake.lock` is CI's to move.** Running `nix flake update` by hand only creates a conflict with the nightly PR.

**`flake-update.yml` checks out and opens its PR with `FLAKE_UPDATE_TOKEN`, not `GITHUB_TOKEN`.** GitHub suppresses workflow events on PRs opened by `GITHUB_TOKEN`, so `ci.yml` would never run, the required check would never arrive, and the PR would be unmergeable forever.

## Knowing whether it worked

Hosts export deployment state as node_exporter textfile metrics from `nixos-upgrade.service`'s `ExecStopPost` (see `modules/services/monitoring/deploy-metrics.nix`), alerted through the Prometheus and Alertmanager stack that already runs on both servers.

| Alert                | Catches                                    |
| -------------------- | ------------------------------------------ |
| `NixosDeployFailed`  | the upgrade ran and failed                 |
| `NixosDeployStale`   | **no upgrade has run in 48 hours**         |
| `NixosRebootPending` | a generation is staged but never activated |

The middle one is the point of the exercise. A host that stops upgrading raises nothing else - no unit fails, no probe drops, it simply falls behind in silence.

The last one exists because `nixos-upgrade` runs `nixos-rebuild boot` and then reboots _only_ if the kernel changed and the clock is still inside the reboot window. A build that runs long pushes it past that window, and the unit reports success while the new kernel never activates.

Services that fail to come back and endpoints that stop responding are already covered by the existing `node_systemd_unit_state` and `probe_success` rules.

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
