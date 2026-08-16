# ADR 0003: Service confinement is bounded by hardlinking

- **Status:** Proposed
- **Date:** 2026-08-16
- **Related Artefacts:**
  - Removes: item 5 from `docs/plans/deployment-hardening.md`
  - Informs: the `data-safety` test, item 4 of that plan
  - Evidence: `docs/recovery-2026-07-25-qbittorrent-reconciliation.md` §10

## Context

Two mass deletions of the shared download root, on 2026-07-25 and 2026-07-27, cost 3.68 TiB across 537 torrents. Both were LazyLibrarian's PostProcessor, which had `download_dir = /data/downloads/complete` — the _shared_ completed-downloads root rather than its own subdirectory. Every ten minutes it enumerated the root as its own, then removed and recreated the tree, sparing only the nine torrents it tracked.

The proposal was to prevent a recurrence declaratively: narrow each service's view of the media tree so that a service which cannot see the shared root cannot destroy it.

Two things shape what that can look like.

**Permissions are not the lever.** LazyLibrarian ran as uid 1000, which _owns_ those files, which is why the `root_squash` NFS hardening never applied to it. Nor was it acting outside its configured scope — it was doing exactly what it was told, to the wrong directory. Any defence has to work by _visibility_: the shared root should not exist inside the service's mount namespace, so that a misconfiguration naming it finds nothing rather than everything. That property is also independent of the application's own config, which is where the fault was.

**The media stack is podman, not native units.** `sonarr.service` and friends are container wrappers with `MainPID=0`; `ProtectSystem=strict` and `ReadWritePaths` on those units constrain the podman client, not the workload. The genuinely native services are already hardened by nixpkgs — `caddy` has `ProtectSystem=full`, `ProtectHome=yes`, `ReadWritePaths=/var/lib/caddy`; `jellyfin` has `ProtectSystem=yes`, `PrivateTmp`, `NoNewPrivileges`. So confinement here means narrowing bind mounts, and nothing else.

## The measurement

`modules/services/media-stack/media-stack.nix` mounts the whole tree into every service as `/data`, with the comment "All child services mount this as `/data` for hardlink support". The narrowing proposal assumed this was conservatism, and that per-service mounts of subdirectories would preserve hardlinking because they share one filesystem.

That was tested rather than assumed, with the production images and uid:

| Setup                                             | Result           |
| ------------------------------------------------- | ---------------- |
| same filesystem, no container, two subtrees       | ✅ `links=2`     |
| two separate bind mounts, NFS (`homelab01`)        | ❌ `EXDEV`       |
| two separate bind mounts, ZFS (`homelab02`)        | ❌ `EXDEV`       |
| **single** parent bind mount, ZFS                  | ✅ `links=2`     |

The assumption is wrong, and instructively so. Both mounts report an identical `st_dev` — 107 on the NFS host, 46 on the ZFS host — and `link()` still fails. The kernel refuses to link across a **mount boundary**, not merely across a filesystem, so `st_dev` is the wrong thing to reason from. Splitting `/data` into per-service mounts breaks hardlinked imports on both hosts and both filesystems.

The wholesale mount is therefore load-bearing, not an oversight.

## Decision

Proposed, not yet accepted; this records the constraint so the question is not re-litigated from first principles.

1. **Keep the wholesale `/data` mount for any service that hardlinks.** Today: `sonarr`, `radarr`, `cross-seed`. There is no arrangement of bind mounts that narrows their view and preserves imports.
2. **Narrow only services that never hardlink.** Today that is `bazarr` alone, which writes subtitles alongside media and never touches `downloads` — it can take `tv` and `movies` and drop the rest.
3. **Treat "a service does not touch data outside its scope" as a property to assert in tests, not one to enforce structurally.** That is the `data-safety` test in item 4 of the hardening plan, whose value rises considerably given prevention is unavailable.
4. **Do not restructure the media tree or split service uids for this.** See alternatives.

Most of the stack is already narrow, which is why the residual scope is one service. `prowlarr`, `huntarr`, `maintainerr`, `seerr` and `wizarr` mount no data at all; `qbittorrent`, `cleanuparr` and `shelfmark` mount only `downloads`; `grimmory` already mounts per-library — `books`, `comics`, `manga`, `doujin`, `lightnovels`, `audiobooks`, `bookdrop` — and is the in-repo precedent for the pattern where it is available.

## Consequences

**Positive**

- The constraint is measured and written down, so the next attempt starts from evidence rather than from the same wrong assumption about `st_dev`.
- Hardlinked imports keep working. Losing them would double storage consumption on a 2×4TB pool, which is a considerably worse outcome than the risk being mitigated.
- `bazarr` is a real reduction: from the entire media tree to two library directories.
- Effort is redirected to the `data-safety` test, which covers every service including the ones confinement cannot reach.

**Negative**

- **The failure class that actually happened remains structurally possible** for `sonarr`, `radarr` and `cross-seed`. A service pointed at the shared root can still destroy it.
- The remaining defence is detection, not prevention — a test that fails in CI, and an alert afterwards, rather than an `EACCES` at the moment of the mistake.
- It continues to rest on each application's own configuration being right, and that config is runtime state rather than Nix. The recovery doc already flags this: `download_dir` is not restored by a rebuild and must be verified after any config restore.
- This is the one item that would have prevented the incident outright, and it is being deliberately given up. Worth revisiting if the stack grows another service that wants a download root.

## Alternatives considered

- **Per-service bind mounts for everything.** Measured above; fails with `EXDEV` on both hosts. This was the original proposal.
- **Restructure the tree so each service has a narrow common ancestor.** A hardlinking service needs its download directory and its library directory inside one mount, so the mount must be their common ancestor — which, given the current layout, is the tree root by construction. Fixing that means a per-library download root and a data migration of several TB, to protect against a class of mistake that has occurred once.
- **Per-service uids and ACLs instead of visibility.** Abandons the shared-ownership model the whole stack is built on. It also would not have helped: the deletion was performed by the uid that owned the files, so this needs per-service ownership of every file in the tree, not merely per-service accounts.
- **systemd hardening directives on the units.** Near-useless here, as measured: the units are podman wrappers, and the native services are already hardened by nixpkgs.
- **Copy instead of hardlink on import.** Removes the constraint entirely and is the only option that makes full confinement possible. Rejected on storage: the pool is 2×4TB and the library is already 3.68 TiB in torrents alone.
