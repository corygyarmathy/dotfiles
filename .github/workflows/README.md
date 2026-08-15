# The deployment pipeline

How a commit becomes a running machine, what runs on a schedule, and what to do when the pipeline jams.

This document describes _behaviour_. The reasoning - what was rejected, and why the design looks like this - is [ADR 0001](../../docs/adr/0001-gitops-deployment-with-a-promoted-ref.md); the gaps it does not yet close are in [the hardening plan](../../docs/plans/deployment-hardening.md). Each workflow file also carries a header comment explaining why _that file_ is shaped the way it is. Anything spanning more than one workflow belongs here instead.

## The refs

`master` is the integration branch and may be red. Nothing follows it.

**`deploy` is the fleet's contract.** CI fast-forwards it to `master` only after every host configuration builds, so a host can never fetch a revision that fails to build for it. `deploy-stable` trails `deploy` by 24 hours.

| Ref             | Followed by      | Takes a revision         |
| --------------- | ---------------- | ------------------------ |
| `deploy`        | homelab01, xps15 | the night it is promoted |
| `deploy-stable` | homelab02        | 24 hours later           |

The servers are not interchangeable. homelab02 holds the ZFS pool and exports the NFS storage homelab01 mounts, so it is the host whose failure cascades - it therefore takes each revision a day after homelab01 has been running it. A kernel that fails to boot takes out the compute node while the data node keeps serving.

Neither ref ever holds a commit that is not already on `master`. They are markers pointing into `master`'s history, and each one's position _is_ the deployment policy. The native operation on them is therefore `git push <sha>:refs/heads/<ref>` - moving a pointer to a deliberately chosen commit - never a merge or a rebase, which would answer "as far forward as possible" and collapse the soak.

The laptop follows `deploy` too, but never switches on its own: it builds in the background and waits to be told, via a waybar indicator.

## The workflows

| Workflow             | When                        | Does                                                               |
| -------------------- | --------------------------- | ------------------------------------------------------------------ |
| `ci.yml`             | every PR and push to master | builds all three hosts, `nix flake check`, fast-forwards `deploy`  |
| `flake-update.yml`   | daily, 15:00 UTC            | `nix flake update`, per-host closure diff, PR, auto-merge on green |
| `promote-stable.yml` | daily, 19:30 UTC            | advances `deploy-stable` to what `deploy` held 24h ago             |
| `package-update.yml` | Mondays, 03:00 UTC          | runs each package's own updater, one PR per package                |

CI builds are pushed to a [Cachix](https://cachix.org) cache that the hosts substitute from, so a closure is built once rather than once per machine.

Lock updates auto-merge when green. Package updates do not - they cross an upstream release boundary, where "it built" is the weakest form of evidence.

### How a night runs

All times Perth (UTC+8), which is what the hosts are set to. Both hosts add up to 10 minutes of jitter.

| Perth | UTC   | Event                                                                                                                      |
| ----- | ----- | -------------------------------------------------------------------------------------------------------------------------- |
| 23:00 | 15:00 | `flake-update` opens its PR; on green it auto-merges, and that push to `master` triggers `ci.yml`, which promotes `deploy` |
| 03:30 | 19:30 | `promote-stable` advances `deploy-stable` to what `deploy` pointed at 24h earlier                                          |
| 04:00 | 20:00 | homelab01 fetches `deploy` and rebuilds                                                                                    |
| 04:15 | 20:15 | homelab02 fetches `deploy-stable` and rebuilds                                                                             |

The ordering is what produces the soak. `deploy-stable` moves _before_ either host wakes, to the revision `deploy` held at 03:30 the previous night - which is the revision homelab01 took at 04:00 that same previous night. homelab02 therefore lands on a revision homelab01 has been running for a little over 24 hours.

## Invariants that will bite you

**The gate job name is a required status check.** `nixos ci` in `ci.yml` is the context named by the `protect-main` ruleset. Rename the job and every merge blocks, with no bypass, until the ruleset is updated to match. Treat the two as a pair.

**Never create a branch under `deploy/` or `deploy-stable/`.** Git stores refs as paths, so `deploy/my-branch` turns `refs/heads/deploy` into a directory and promotion fails with `directory file conflict` for as long as that branch exists. The `reserve-deploy-namespace` ruleset blocks this at the server; the failure is obscure enough to be worth naming twice.

**`deploy` and `deploy-stable` reject non-fast-forward pushes, with zero bypass actors.** Not even an admin or `GITHUB_TOKEN` can force-push or delete them. This is deliberate, and it means the recovery below requires temporarily relaxing a ruleset - there is no way around it from the client side.

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

**Symptom.** The `promote to deploy` job fails with a non-fast-forward rejection. The morning after, `promote-stable` fails too, with `<sha> and <sha> have diverged - refusing to move deploy-stable`.

**Cause.** Almost always a force-push to `master`. Rewriting history does not edit commits, it creates new ones with new SHAs; `deploy` still points at the old objects. The changes are identical, but Git only reasons about ancestry, and the old tip is no longer an ancestor of the new one, so a fast-forward is impossible by definition.

**First, confirm nothing is being thrown away.** Both refs should hold only commits that already exist on `master` under a different SHA:

```bash
git fetch origin --prune
git cherry origin/master origin/deploy        | grep '^+'   # expect no output
git cherry origin/master origin/deploy-stable | grep '^+'   # expect no output
```

Any `+` line is a commit that exists _only_ on the deployment ref - stop and work out where it came from, because realigning would discard it.

**Then pick the target commit for each ref.** This is a judgement call, not a mechanical repair, and it is the step worth slowing down for.

- `deploy` → `origin/master`, since that is what it would have been fast-forwarded to anyway.
- `deploy-stable` → **the rewritten equivalent of the commit it currently holds**, not the tip. Moving it to the tip would jump homelab02 forward to the newest revision, collapsing the 24h lag to zero and putting the storage node on an untested revision the same night as the compute node. Find the equivalent by matching subjects with `git log --oneline --cherry-mark --left-right origin/deploy-stable...origin/master`, and confirm the trees are identical:

  ```bash
  git rev-parse <old-sha>^{tree} <new-sha>^{tree}   # the two hashes must match
  ```

**Relax the rulesets.** GitHub → Settings → Rules → Rulesets → `protect-deploy` → Enforcement status → Disabled, and the same for `protect-deploy-stable`. Prefer the UI: the API equivalent is a `PUT`, which replaces the whole ruleset, so a mistyped call is a rewrite rather than a toggle. `gh api repos/corygyarmathy/dotfiles/rulesets` lists them if you want the IDs.

**Push both refs, with an explicit lease** so the push aborts if the remote is not where you think it is:

```bash
git push --force-with-lease=deploy:<old-deploy-sha>               origin <new-tip>:refs/heads/deploy
git push --force-with-lease=deploy-stable:<old-deploy-stable-sha> origin <equivalent>:refs/heads/deploy-stable
```

**Re-enable both rulesets immediately.** An unprotected `deploy` is the real risk in this procedure, and it is the step easiest to forget once the pipeline goes green.

**Verify:**

```bash
git fetch origin --prune
git merge-base --is-ancestor origin/deploy origin/master        && echo "deploy fast-forwards"
git merge-base --is-ancestor origin/deploy-stable origin/deploy && echo "deploy-stable can advance"
```

**Expect one benign symptom.** Rewritten commits carry the committer date of the rewrite, so for the first night afterwards nothing on `deploy` is yet 24 hours old. `promote-stable` walks back past the cutoff, finds a commit older than `deploy-stable`, and logs `already at or ahead of <sha>; nothing to do` before exiting zero. That is the guard working, not a second failure - it resolves on its own once the new commits age past 24 hours.

**Prevention.** Don't force-push `master`. `protect-main` blocks it directly, so this only happens when the ruleset is deliberately relaxed - and the cost is this whole procedure plus a day of lost soak.

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
