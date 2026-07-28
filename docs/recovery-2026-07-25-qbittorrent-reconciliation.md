# qBittorrent ↔ Library Reconciliation — Recovery Plan

**Created:** 2026-07-25 · **Status:** executed 2026-07-26, **undone 2026-07-27**, re-executed
2026-07-28 · **Owner:** coryg

> **The root cause in §1 is WRONG.** It was never orphan-cleanup racing
> qBittorrent's startup. Both mass deletions were **LazyLibrarian's
> PostProcessor**, pointed at the shared downloads root. See §10. The
> `f24aa80` readiness gate guarded a mechanism that was not firing, which is
> why the same loss recurred on 2026-07-27 and wiped out this document's
> entire 2026-07-26 recovery.

Self-contained brief for a fresh session. Everything needed to start is below; you
should not need the conversation that produced it.

> **Read §9 before re-using this plan.** Executing it turned up five factual
> errors in §4–§6 (wrong trigger state, wrong API endpoints, wrong hardlink
> destination, and a verification strategy that could start unwanted
> downloads). §9 records what actually happened and what the corrected
> procedure is.

---

## 1. Background — what happened

On **2026-07-25**, shortly after a reboot+update, roughly **466–777 completed
torrent downloads (~1.1 TB)** were deleted from `/srv/media/downloads/complete`
on **homelab02**.

- **Root cause:** qBittorrent's WebUI accepts logins *before* it finishes loading
  torrents on startup, so `/api/v2/torrents/info` briefly returned an empty list.
  The hardlink-based cleanup logic (`orphan-cleanup` / `private-torrent-cleanup`)
  then treated every not-yet-loaded torrent's data as "orphaned" and deleted it.
  The exact invocation was never captured in logs (ran as `coryg`, who owns the
  files), but the behaviour is an exact match.
- **Already fixed** (commit `f24aa80` on `master`): both cleanup scripts now wait
  for qBittorrent to report at least as many torrents as there are `.torrent`
  files in `BT_backup` before deleting anything, and abort otherwise. The NFS
  export was also tightened (`root_squash`, scoped to `10.20.2.85/32`).
  **Confirm this is deployed** (`nixos-rebuild switch` on homelab02) before
  trusting any cleanup timer again.
- **The Jellyfin library was NOT touched** — `/srv/media/tv` (~4.1 TB),
  `/srv/media/movies` (~723 GB), books/manga/etc. are all intact. No
  re-downloading is needed for Jellyfin.

## 2. Current state

- **qBittorrent** (on homelab02, inside the gluetun netns; WebUI reachable at
  `http://localhost:8080` **from homelab02**) still holds **~594 torrents**, most
  now in **missing-files / errored** state ("No such file or directory").
- `/srv/media/downloads/complete` is **empty**.
- **No ZFS snapshots and no recycle bin** exist → deleted data is only recoverable
  if a **byte-identical** copy still lives in the library.
- Imports are **hardlink-based** (library files normally show `2 links`). The
  deleted downloads were link-count-1 (hardlink already broken by a later
  re-import/upgrade), which is why they were swept.
- **Manifest of deleted items:** `/srv/arr/deleted_downloads_manifest_2026-07-25.txt`
  on **homelab01** (466 unique top-level names).

## 3. Goal (desired end state)

1. Every torrent whose content **still exists byte-identically in the library**
   is **re-hardlinked** into the path qBittorrent expects and **resumes seeding**.
2. Torrents whose content is **unrecoverable** (different release/upgrade, or never
   imported) are **deleted** from qBittorrent (torrent + stub folder).

## 4. Approach

Per-torrent reconciliation, **using qBittorrent's own recheck as the verifier** —
never trust a filename or size guess:

| Case | Action |
|---|---|
| Library holds a byte-identical copy | hardlink it → exact expected download path → force **recheck** → **resume** |
| Recheck fails / no candidate | remove the stray hardlink(s) (library inode untouched), **delete** the torrent |

**Why not cross-seed:** cross-seed finds *new* cross-seed matches and would create
*duplicate* torrents; it does not repair the existing errored ones. A small
purpose-built pass is the right tool. Reuse the qBittorrent-readiness gate pattern
already added in `modules/services/media-stack/orphan-cleanup.nix`.

**Why this is safe:** we only ever create hardlinks into `downloads/complete` and
`rm` hardlinks we ourselves created. Removing one name of a hardlinked file leaves
the library's copy fully intact. No `cp`, so no extra disk use.

## 5. Key facts / handles

- **Hosts:** homelab02 = `10.20.2.130` (NAS, ZFS pool `tank` at `/srv/media`,
  qBittorrent, storage). homelab01 = `10.20.2.85` (arr stack; NFS client mounting
  homelab02:/srv/media at `/srv/media`).
- **Run the recovery ON homelab02** (qBittorrent is localhost there; files are
  local ZFS, not NFS — faster and avoids the NFS root-squash we just enabled).
- **qBittorrent creds (sops):** `media-stack/qbittorrent/username` /
  `media-stack/qbittorrent/password`. Login: `POST /api/v2/auth/login`
  (returns **204** on ≥5.2.0; use a cookie jar — see existing scripts for the
  exact pattern).
- **Paths:** host `/srv/media/downloads/complete` == container `/data/downloads/complete`.
  The API's `content_path` uses the **container** prefix — translate to host.
- **BT_backup:** `/srv/arr/qbittorrent/qBittorrent/BT_backup` (`*.torrent` per torrent).
- **Library search roots:** `/srv/media/tv`, `/srv/media/movies` (add
  `manga`, `books`, `doujin`, `audiobooks` only if the manifest warrants).
- **Useful qBit API endpoints:**
  `GET /api/v2/torrents/info` (has `state`, `content_path`, `hash`, `save_path`),
  `GET /api/v2/torrents/files?hash=…` (per-file name + size),
  `POST /api/v2/torrents/recheck` (`hashes=`),
  `POST /api/v2/torrents/resume` (`hashes=`),
  `POST /api/v2/torrents/delete` (`hashes=`, `deleteFiles=true`).
  Errored torrents: filter `info` on `state` in {`missingFiles`, `error`}.

## 6. Steps

### Phase 0 — prerequisites
- Confirm `f24aa80` (readiness gate + NFS hardening) is **deployed** on homelab02.
- Confirm qBittorrent is **fully loaded** (API torrent count == `.torrent` count in
  BT_backup). Do nothing until it is.
- Snapshot a safety net: `zfs snapshot tank@pre-recovery-$(date +%Y%m%d)` so any
  mistake during recovery is reversible (there were no snapshots before — fix that).

### Phase 1 — read-only analysis (no changes)
For each errored torrent, list its files (name + size) and check whether a
**same-size** candidate exists under the library roots. Produce a report:
- count of torrents fully matchable (all files have a size candidate) → *likely re-linkable*
- count partially matchable
- count with no candidates → *likely delete*
- total bytes in each bucket
This gives real recoverable-vs-not numbers before building anything.

### Phase 2 — reconciliation script (dry-run first)
Write it (bash, mirror the style/safety of the existing cleanup modules; or as a
throwaway script — does not need to be a Nix module). Logic per errored torrent:
1. Get expected files (path relative to `content_path`, + size).
2. For each file, find library file(s) of identical size; if >1 candidate, verify
   by comparing a hash of the first + last few MB (cheap) before choosing.
3. `--dry-run`: log the planned hardlink (`src library file → dst expected path`),
   don't touch anything.
Review the dry-run output.

### Phase 3 — execute re-link
For matched torrents: create parent dirs, `ln` (hardlink) library file → expected
path, then `POST /torrents/recheck`. Wait for recheck to settle, then:
- if progress == 100% → `POST /torrents/resume` (seeding restored)
- if not → remove the hardlink(s) we just made (library safe), mark torrent for
  deletion.
Work in **small batches** and re-verify between batches.

### Phase 4 — delete the unrecoverable
Torrents with no matches (or that failed recheck): `POST /torrents/delete` with
`deleteFiles=true` (removes the stub folder too). Log every deletion.

### Phase 5 — verify
- qBittorrent: 0 torrents left in `missingFiles`/`error`; recovered ones seeding.
- `zfs list tank` — space used should rise by the re-linked amount only if imports
  had been copies (with hardlinks it stays ~flat; that's expected and correct).
- Once satisfied, keep or drop the `tank@pre-recovery-*` snapshot.

## 7. Edge cases / cautions
- **Season packs / multi-file torrents:** only re-link if *all* files match;
  a partial pack won't recheck to 100%.
- **Renames:** library names differ from torrent names (Sonarr/Radarr rename on
  import) — match on **size + content hash**, never on name.
- **Adult content (Radarr-managed):** may not live under `tv`/`movies` at all;
  check the manifest and decide whether it's worth recovering or just delete.
- **Private trackers / hit-and-run:** prioritise re-linking private-tracker
  torrents (ratio/H&R exposure); public ones matter less.
- Do **not** run the old cleanup timers during recovery.

## 8. Pointers
- Deleted-items manifest: `homelab01:/srv/arr/deleted_downloads_manifest_2026-07-25.txt`
- Fix commit: `f24aa80` — readiness gate + NFS hardening
- Cleanup modules (reference for API/login/hardlink patterns):
  `modules/services/media-stack/orphan-cleanup.nix`,
  `modules/services/media-stack/private-torrent-cleanup.nix`

---

## 9. Execution record — 2026-07-26

Run from the workstation against homelab02 over ssh. Working directory and all
artefacts: `homelab02:~/qbt-recovery/`.

### 9.1 Outcome

| | torrents | size |
|---|---|---|
| broken at start | 595 | 4.55 TiB |
| **recovered** (proven byte-identical, re-linked) | **524** | **3.65 TiB** |
| deleted as unrecoverable | 66 | 0.89 TiB |
| kept: in-progress downloads, not lost seeds | 5 | — |
| held for manual review (need real downloads) | 8 | 134 GiB to fetch |

Final qBittorrent state: **529 torrents, 512 seeding (3.23 TiB), 7 fetching a
small remainder, 10 stopped (8 held + 2 pre-existing), 0 in
`missingFiles`/`error`** — the §6 Phase 5 exit condition.

**88% of torrents and 80% of bytes recovered without downloading anything.**
The library was never modified: file count went 27033 → 27036 (unrelated
growth), `tank` stayed at 4.93T, 6597 hardlinks now live under `downloads/`.
Total session download was ~3 GiB, essentially all of it the single torrent
that was mis-targeted before the `content_path` bug (§9.2 item 4) was found.

Of the 0.89 TiB deleted, only ~250 GiB is genuinely lost media — mostly
superseded Attack on Titan S04 REMUXes and HotD/Boys releases already upgraded
in the library. The remaining 638 GiB is two download-only adult titles that
were never imported anywhere, so no library copy could ever have existed.

Of the 0.89 TiB deleted, 638 GiB is two adult titles (`Polly_Yangs_4K`,
`Lana_Rhoades_x265`) that were download-only and never imported to a library —
so they had no recoverable copy by construction. `whisparr`/`comics` are empty.

### 9.2 Corrections to this plan

Five things in §4–§6 were wrong. Fix them before re-using this document.

1. **§5/§6 — the trigger state never fires.** After a qBittorrent restart no
   torrent is in `missingFiles`/`error`; all 595 reported `stalledUP` at
   progress 1 from stale resume data despite empty storage. The correct
   discriminator is **`content_path` does not exist on disk**.

2. **§5 — the API endpoints are wrong for 5.2.3 / WebAPI 2.15.1.**
   `POST /torrents/resume` and `/torrents/pause` return **404**; they are
   `/torrents/start` and `/torrents/stop`.

3. **§6 Phase 3 — recheck is a silent no-op on a stopped torrent.**
   `POST /torrents/recheck` returns HTTP 200 and does nothing unless the
   torrent is started. Order must be **start → recheck**, not stop → recheck.

4. **§4 — hardlink destination must derive from `content_path`, not
   `save_path`.** `Session\TempPathEnabled=true`, so a torrent qBittorrent
   considers incomplete reads from `downloads/incomplete/`, not
   `downloads/complete/`. Linking by `save_path` puts files where it will never
   look. Use `dirname(content_path)` as the layout root. (A recheck resets
   progress to 0, which itself flips a torrent to the temp path — so this bites
   on the second attempt even when the first looked fine.)

5. **§4 — "use qBittorrent's recheck as the verifier" is the wrong tool.**
   A recheck is a slow oracle with a bad failure mode: when the guess is wrong
   the torrent starts **downloading** the real data. One mis-verified torrent
   pulled ~1.1 GiB before it was caught. Instead, verify locally against the
   torrent's own SHA-1 piece hashes, read straight out of the `.torrent` files
   in `BT_backup`. That is definitive, takes milliseconds, and cannot download
   anything.

   Two further traps in the progress numbers:
   - `progress` is measured against `total_size`, which **includes deselected
     (`priority=0`) files** — typically `.nfo` sidecars. A fully recovered
     torrent therefore reports ~0.99996, not 1.0. Use `amount_left == 0`.
   - During a check, `progress` reports **scan position**, not verified
     fraction. It climbs to ~1.0 and then drops to the real value. Never
     sample it mid-check.

### 9.3 Corrected procedure

1. Snapshot `tank`; stop the cleanup timers; archive `BT_backup` (it is on the
   root NVMe, *not* on `tank`, so the ZFS snapshot does not cover it).
2. Index the library by file size (`size, inode, nlink, path`).
3. Per torrent, assign a same-size library candidate to each file, preferring
   the library directory that already accounts for most of that torrent's files
   — this is what disambiguates image sets where many files share a size.
4. **Verify with piece hashes before creating any link.** A piece is usable if
   every file overlapping it is mapped (BEP-47 padding counts as zeros).
   Requiring a piece to sit wholly inside one file cannot verify torrents made
   of many small files.
5. Link only proven matches, into `dirname(content_path)`.
   **Skip files too small to be covered by any piece** — an unproven size match
   on a 1 KB `.nfo` can pick up junk (a stray `/srv/media/tv/test-write-permission`
   was matched this way). 76 such links, 2.4 MiB total; let peers supply them.
6. Start, then recheck, in batches. `max_active_checking_torrents=1` means
   rechecks serialise — a full 3.65 TiB pass takes hours.
7. Guard against runaway downloads: after each batch, stop anything whose
   `amount_left` exceeds a small threshold instead of letting it fetch.

### 9.4 Scripts

In `homelab02:~/qbt-recovery/` (throwaway, not Nix modules):

- `verify_pieces.py` — bencode parser + SHA-1 piece verification. The core tool.
- `relink.py` — verify-first matching and hardlink creation.
- `finalize.py` — start + recheck in batches, with the download guard.
- `delete_unrecoverable.py` — Phase 4, `--exclude-file` to keep in-progress torrents.
- `verify_results.tsv`, `linked.tsv`, `deleted.tsv`, `hold_for_review.tsv` — audit trail.

Superseded by the above but kept for reference: `reconcile.py`, `run_batch.py`
(the original size-match + recheck-as-oracle approach).

### 9.5 Follow-ups

- [ ] 8 held torrents in `hold_for_review.tsv` — decide whether to fetch 134 GiB.
      They are **stopped**. They had to be stopped explicitly: qBittorrent still
      reported them `stalledUP` at progress 100% from stale resume data, so they
      would have advertised 134 GiB they do not have. Anything left unresumed by
      this procedure needs the same treatment.
- [ ] Re-enable the cleanup timers once seeding has settled
      (`systemctl start orphan-cleanup.timer private-torrent-cleanup.timer`).
      Note `systemctl mask` does not work on these NixOS units — they are
      already symlinks in `/etc/systemd/system`, so mask reports `linked`.
- [ ] Drop `tank@pre-recovery-20260726` when satisfied.
- [ ] Delete the stray zero-byte `/srv/media/tv/test-write-permission`.
- [ ] Consider raising `max_active_checking_torrents` above 1 for future bulk work.

---

## 10. Actual root cause — LazyLibrarian (found 2026-07-28)

§1 blamed the hardlink cleanup scripts racing qBittorrent's startup. That was
wrong. Both mass deletions were **LazyLibrarian's PostProcessor**.

### 10.1 The mechanism

`/srv/arr/lazylibrarian/config.ini` had:

```
download_dir = /data/downloads/complete
```

— the *shared* qBittorrent completed-downloads root. LazyLibrarian's
PostProcessor job runs **every 10 minutes**, enumerates every entry in
`download_dir` as one of its own book downloads, and then removes and recreates
the tree, logging `Created new Download folder: /data/downloads/complete`
(`filesystem.py:562`). It spares only the ~9 torrents it tracks itself
(`Seeding 9`).

It runs as the media-stack user (uid 1000), which **owns** those files, so the
`root_squash` NFS hardening from `f24aa80` never applied to it.

### 10.2 Evidence

Event 1 — the original loss. homelab01 rebooted 11:44:47; the job's first run was
two minutes later:

```
Jul 25 11:46:42  Compiled 779 total items from 1 download directory
Jul 25 11:50:41  (run ends — ~4 min of deleting)
Jul 25 11:56:52  Compiled 2 total items from 1 download directory
Jul 25 11:56:53  Created new Download folder: /data/downloads/complete
```

779 → 2. §1's "466–777 downloads / ~1.1 TB" is this.

Event 2 — the 2026-07-26 recovery undone:

```
Jul 27 11:56:42  Running job "PostProcessor"
Jul 27 11:56:42  Compiled 542 total items from 1 download directory
Jul 27 11:58:15  Created new Download folder: /data/downloads/complete
Jul 27 11:58:16  Job "PostProcessor" executed successfully
```

Corroborated independently on homelab02: **6416 library inodes have a `ctime` in
11:56–11:58** that day (271 at 11:56, 5531 at 11:57, 612 at 11:58) — the
signature of a second link being unlinked. Nothing else could have done it: no
systemd unit ran in that window, neither host had an interactive login all day,
qBittorrent logged no deletions, and `orphan-cleanup` reported
`Files to remove: 0` on both its runs either side (`Skipped (hardlinked): 6367`
on Jul 27 04:18 → `0` by Jul 28 00:44).

### 10.3 Diagnostic that generalises

Free space does **not** move when hardlinks are deleted — the library still
holds the inode. "Disk usage unchanged" is therefore *not* evidence that files
survived. Use instead:

```sh
# how many linked names exist in total -- this counts BOTH names of each pair
# (library + download side), so it is ~2x the number of linked torrent files:
# 13198 total = 2 x 6599 pairs. Do not read it as a download-side count.
find /srv/media -type f -links +1 | wc -l          # 6597 healthy -> 250 after

# when links were removed: ctime on the surviving library name
find /srv/media/tv /srv/media/movies /srv/media/doujin /srv/media/books \
     -type f -printf '%CY-%Cm-%Cd %CH\n' | sort | uniq -c
```

Note `find -newermt` filters **mtime**; for this you need `-newerct`.

### 10.4 The fix

- `config.ini`: `download_dir = /data/downloads/complete/books`
- qBittorrent `books` category `save_path = /data/downloads/complete/books`
  (all categories previously had `save_path: ""`, i.e. everything landed flat in
  `complete/`, which is why LazyLibrarian had to be pointed at the whole root to
  find its own downloads)
- `modules/services/media-stack/lazylibrarian.nix` — setup instructions said to
  use the shared root; corrected, with this history recorded inline.

`download_dir` is **runtime state, not Nix** — a rebuild will not restore it.
Verify it after any config restore.

## 11. Re-execution record — 2026-07-28

LazyLibrarian stopped first, then the fix applied, then §9.3 re-run. The stale
`torrents.json`/`files/` inputs from 2026-07-26 were **regenerated from live
state** first — 16 torrents had moved `incomplete/` → `complete/` in the
meantime, and linking by the stale `content_path` would have put their files
where qBittorrent no longer looks (the §9.2(4) trap, second-order).

| | torrents | note |
|---|---|---|
| broken at start | 537 | 3.68 TiB, 529 in `missingFiles` |
| verified byte-identical | 528 | vs 524 on 07-26 (library grew slightly) |
| links created | 6542 | |
| held (need real downloads) | 8 | same 134 GiB set as 07-26 |
| unrecoverable | 9 | 8 no-candidate + 1 unverifiable |

### 11.1 Final state (from qBittorrent, not the scripts)

Three passes were needed; the numbers below are `/torrents/info` at the end, not
script counters — see 11.2 for why the counters cannot be trusted.

| | torrents |
|---|---|
| total | 538 |
| complete (`amount_left == 0`) | 511 |
| actively seeding | 507 |
| complete but stopped (pre-existing, left alone) | 4 |
| incomplete — `missingFiles` (the 8 holds + 2 HotD) | 10 |
| incomplete — small remainders, allowed to fetch | 17 |

Total pulled from peers across the whole recovery: **5.7 GiB** (the one genuine
runaway, §11.3) plus ~0.4 GiB of Casualty remainders. The 41 GiB of
`downloaded_session` visible at the end was ordinary Sonarr activity — a 36 GiB
Gachiakuta grab and similar — not recovery traffic.

### 11.2 The scripts' own counters are wrong

`finalize.py`'s summary counts only the torrents whose batch *settled* inside the
timeout. Pass 2 reported `seeding 47` when the live figure was ~484. Always
audit from `/torrents/info`.

Related traps hit this run:

- **Session expiry.** The WebUI cookie dies after ~1h and `curl -sf` reports the
  403 with a *non-zero exit and empty stderr*, so the traceback is bare.
  `relink.api()` now re-logins once and retries.
- **No resume.** Re-running `finalize.py` re-rechecked everything; rechecks
  serialise, so that costs hours. It now skips `amount_left == 0`.
- **`wait_settled()` is unsound**: it marks a torrent "seen" if
  `state in CHECKING` *or* `progress > 0`, so a torrent with stale resume data is
  judged without ever being rechecked.
- **The log is appended across runs.** Monitoring from the top of the file
  double-counts batches and resurfaces the *previous* run's traceback — this
  produced one false alarm. Slice from the last `=== finalize [EXECUTE] ===`.
- `max_active_checking_torrents` was raised 1 → 3 to stop batches timing out.
  It is a live preference, not in Nix.

### 11.3 Judging a runaway: use `downloaded_session`

A recheck reports a **non-zero `dlspeed`** while it scans, and `amount_left` is
still falling toward its true value. Judging either mid-check gives a false
positive. The first guard used `dlspeed > 0 and amount_left > 200 MiB` and
stopped Gattaca at 10.2% of its recheck having fetched **0 bytes** — aborting a
healthy verification. Only `downloaded_session` proves data came from peers.

Corollary: such a guard cannot distinguish a runaway from a legitimate new
Sonarr/Radarr grab, so **remove it once the recovery is done**.

### 11.4 Links placed one directory too deep

For a single-file-in-a-folder torrent, `content_path` *already* includes the
folder; joining it with the torrent's relative path (which also includes the
folder) duplicates the name:

```
incomplete/<name>/<name>/file.mkv   # where the link went
incomplete/<name>/file.mkv          # where qBittorrent looks
```

qBittorrent then sees only its own stale partial and starts downloading for
real — this, not the §9.2(4) temp-path flip, caused the Matrix Revolutions
runaway (5.7 GiB). It affected 3 directories across 2 torrents. Find them with:

```sh
find /srv/media/downloads/{complete,incomplete} -mindepth 2 -maxdepth 2 -type d \
  | while read -r d; do
      [ "$(basename "$(dirname "$d")")" = "$(basename "$d")" ] && echo "$d"
    done
```

The library data was never at risk: qBittorrent wrote into its own `nlink == 1`
partial, while the library kept the shared inode. `relink.py`'s rule — replace a
destination only when `st_nlink == 1`, never a library link — is what held.
Repair script: `~/qbt-recovery/fix_nested.py` (asserts inode/nlink before every
removal).

### 11.5 Left for the user

- **LazyLibrarian is still stopped** — start it once seeding settles.
- The 9 unrecoverable and the 8 holds (134 GiB) await a keep-or-delete decision.
- `max_active_checking_torrents` left at 3; restore to 1 if preferred.
- The `/srv/media/tv/test-write-permission` stray (§9.5) still size-matches tiny
  `.nfo` files; the link attempts failed `EPERM`, which is the desired outcome,
  but delete it to stop the noise.
