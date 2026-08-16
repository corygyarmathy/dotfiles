# ADR 0002: Protect at activation, not in the rollout

- **Status:** Accepted
- **Date:** 2026-08-16
- **Related Artefacts:**
  - Supersedes: ADR 0001 §1a (staged rollout via `deploy-stable`)
  - Retires: the `deploy-stable` branch and `.github/workflows/promote-stable.yml`
  - Depends on: the deployment metrics in `modules/services/monitoring/deploy-metrics.nix` and the `NixosDeployStale` alert in `modules/services/monitoring/alert-rules.yml`
  - Planned in: `docs/plans/deployment-hardening.md`

## Context

ADR 0001 staged the server rollout by time: `homelab01` follows `deploy` and takes each promoted revision the night it lands, while `homelab02` follows `deploy-stable`, which a scheduled job advances to whatever `deploy` pointed at 24 hours earlier. Two things have become clear since.

The lag has a cost that was not anticipated. A change merged for `homelab02` reaches it a day late, and any deliberate deployment in the meantime is reverted at 04:15 and then re-applied 24 hours later - the reconciler behaving correctly against a ref that lags, but the effect is that the host holding the data is the host least able to receive a considered change. Every attempt to keep the lag and add an expedite path founders on the same fact: promotion is a fast-forward of a ref, so it is all-or-nothing over the whole range between `deploy-stable` and `deploy`, and with `flake.lock` bumps auto-merging nightly there is an unsoaked commit sitting in that range almost every time an expedite would be wanted.

The lag also buys less than it appeared to. ADR 0001 already conceded that `homelab01` runs neither ZFS nor qBittorrent nor the VPN, so the soak only ever exercised the shared base. It measures elapsed time rather than health, and nothing reads the result: a revision was promoted at 03:30 whether or not `homelab01` had survived the night on it. Meanwhile the failure history contains no base-system regression at all. What has actually broken is service configuration - a service wiping a shared directory, a client reaching a peer through the reverse proxy instead of by address, a DNS record pointing at the wrong host. None of that would surface during a soak on a machine that does not run those services, and none of it would be undone by rolling back a generation: a reverted configuration does not restore deleted files.

The pipeline is therefore carrying its most elaborate mechanism against the failure class it has never experienced, while the class it experiences repeatedly is gated only by "it builds".

## Decision

**1. Both servers follow `deploy`.** `deploy-stable` and `promote-stable.yml` are retired. `deploy` remains the fleet contract - CI fast-forwards it only after every host configuration builds - and both servers reconcile to it nightly. A merged change reaches every host the same night, and there is no longer a state in which a host is deliberately behind the ref it follows.

**2. Protection moves from the rollout to activation, on the machine being changed.** Staging protected `homelab02` by delaying it. Instead, each host defends itself at the moment it switches, against three failure modes that need three different answers:

- _Does not boot._ systemd's Automatic Boot Assessment, via `boot.loader.systemd-boot.bootCounting`. A new entry carries a counter, systemd-boot decrements it each attempt, and an entry that never reaches `boot-complete.target` is skipped in favour of an older generation. This is the native answer to the unattended kernel bump that motivated the staged rollout, it works with nobody present, and it protects the storage node directly rather than by proxy.
- _Boots, services broken._ The upgrade verifies the system after switching and rolls back to the previous generation if it does not come up clean. This is the case the 24h soak was least able to catch and the one that occurs most often.
- _Boots, network broken._ Not automated. An on-host check cannot detect that it has lost its own network, and the established remedy is push-based deployment with a remote confirmation, which would reintroduce the dependency on an operator's machine that the pull model exists to avoid. Accepted as a known gap, with the interactive path in decision 4 as its remedy.

**3. The pre-deploy gate becomes behavioural, not only compilable.** NixOS VM tests per service module, exposed as flake `checks` so the existing gate picks them up without workflow changes. This is where new effort goes, because it is the only gate that stops a bad service configuration before it reaches any host, and service configuration is what actually breaks. ADR 0001 named this as its largest known weakness and deferred it; it is no longer deferred.

**4. `deploy-rs` is adopted for interactive and recovery deployment only.** Iterating on a service, and recovering a host that the automated path cannot reach, both need a human-driven push. `deploy-rs` does that better than raw `nixos-rebuild --target-host` because its magic rollback covers exactly the network case decision 2 leaves open. It is explicitly _not_ the fleet mechanism: the servers keep pulling.

The pull model, a gate, and a report - ADR 0001's own framing - all stand. The correction is that the gate belongs before the merge and at activation, not in the shape of the rollout.

## Consequences

**Positive**

- A merged change reaches both servers the same night, so there is no window in which a deliberate configuration change is reverted and then reinstated.
- Protection is exercised on the host that matters instead of inferred from a machine with a different workload. Boot counting tests the storage node's own kernel on its own hardware; the soak never did.
- The fleet has one promoted ref again. `deploy-stable`, the promotion job, its 24h cutoff, its divergence guard, and the whole question of when a change deserves to skip the queue all disappear.
- Effort moves to the failure class that has actually caused outages here.
- Rollback becomes a real signal rather than a proxy: a host that reverts says so, instead of a promotion job silently not advancing.

**Negative**

- Both servers now take a bad revision on the same night. The blast radius of a base-system regression is the whole fleet rather than one node, and the mitigation is per-host recovery rather than an unaffected survivor. This is the deliberate trade: an automated check at activation in place of an unread day of elapsed time.
- Nothing covers a host that boots and serves but has lost its network. It remains a trip to the machine, or a push deployment initiated by hand.
- An over-eager health check can revert a good deployment. A rollback loop is worse than the degradation it protects against, so the verification must be conservative and must alert loudly when it fires.
- VM tests are a standing maintenance cost, and a flaky one trains you to re-run the gate rather than read it.
- Boot counting changes how boot loader entries are named on the ESP and migrates existing entries on the next `nixos-rebuild boot`. Low risk, but it touches the boot path of the host holding the pool.

## Alternatives considered

- **Keep the staged rollout and add an expedite path.** Either a manual promotion to a chosen revision, or a path-based fast-track that promotes immediately when the pending range touches only host or service configuration. Rejected because a ref advance carries everything before it: with nightly lock bumps auto-merging, the range is almost never clean, so the fast-track would rarely fire and the manual path would mean routinely pulling unsoaked base-system changes forward by hand while believing otherwise.
- **Slow the `flake.lock` cadence to weekly so the fast-track could fire.** Rejected: it makes behaviour depend on the day of the week, delays security fixes by up to a week, and enlarges each batch so that attributing a regression gets harder. It changes when risk arrives without reducing it.
- **Health-gate the promotion instead of retiring it** - advance `deploy-stable` only when the deployment metrics show `homelab01` well on the target revision. This was the previous plan's highest-value item. Rejected because it needs Prometheus reachable from CI, which reintroduces inbound access to the homelab, and because once activation-time verification exists the canary's remaining value is small - it never exercised the storage node's own workload in the first place.
- **Mutual push with `deploy-rs`: each server deploys the other.** Genuinely attractive, because the deployer is then never the machine being changed, which is the condition magic rollback requires. Rejected as over-built for two hosts: it creates a control plane with no root of authority, two timers that can overlap with each other and with a manual deployment with no locking, and a credential cycle in which each host is effectively root on the other. Most of what it offers is available on-host, and it gives up the pull model's self-healing after downtime.
- **`comin`.** A pull-mode GitOps operator for NixOS - polls git remotes, deploys by hostname, exports Prometheus metrics, supports testing branches. The closest thing to prior art for what this repository has built by hand, and worth tracking. Not adopted: it does not cover home-manager or unattended reboots, and it does not advertise rollback on a failed deployment, so it would replace a working mechanism without closing the gaps that motivated this ADR.
- **Stop updating the storage node automatically.** The conservative option for a host with irreplaceable data. Rejected for now because `homelab02` is a second server that happens to hold storage rather than a dedicated appliance, the data on it is largely re-downloadable, and there is no parity disk to protect in the first place. Revisit if its role narrows or the array gains redundancy.
