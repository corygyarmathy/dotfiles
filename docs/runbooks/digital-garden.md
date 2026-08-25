# Digital garden

The garden is a published subset of the Obsidian vault, rebuilt on vault
changes and served by homelab01. Two failure modes hide behind a healthy
200: the builder failing (site ages silently) and sync stopping delivering
(same effect, different layer). Each has a positive-signal alert for exactly
that reason. See the comments in `alert-rules.yml` for the full story.

## DigitalGardenBuildFailed

**Severity:** warning · **Fires when:** `digital-garden-build.service` has
been failing 15+ minutes - Caddy keeps serving the last good build meanwhile.

### Do now

- `ssh homelab01 journalctl -u digital-garden-build -n 100`
- Usually a renderer error from specific note content (a construct the parser
  chokes on). The log names the offending file.

### Fix

- Fix or temporarily unpublish (`publish: false`) the offending note; if it
  was a legitimate content pattern, that is a renderer bug to fix in
  `modules/services/digital-garden/`.

## DigitalGardenSyncStale

**Severity:** warning · **Fires when:** no completed sync cycle logged for
6+ hours - the site serves its last good build while edits pile up unpushed.

### Do now

- `ssh homelab01 journalctl -u digital-garden-sync -n 100` -
  `obsidian-headless` logs "Fully synced" per completed cycle; its absence
  plus errors here says why.
- Auth token expiry (Obsidian account) and network are the usual suspects.

### Fix

- Re-auth if the token expired; restart the unit after fixing the cause.
- Confirm recovery by watching one "Fully synced" then a successful build.
