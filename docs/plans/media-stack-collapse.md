# Plan: collapse the media-stack container template

Status: proposed 2026-09-06. Decisions taken the same day in a design session against
the code; see _Decisions, 2026-09-06_ below. Nothing has landed yet. Scope is
`modules/services/media-stack/`. This is the brief for the collapse session and
the record of the decisions behind it; the structural-cleanup plan deliberately
declined to split `monitoring.nix` and `digital-garden.nix`, and this is not
that. This is a shallowness problem in the media stack's container modules, and
the plan the structural-cleanup plan's "not this plan" list was pointing at.

## The short version

Ten modules in `modules/services/media-stack/` are the same ~85-line template
with name, image, port and a few facts swapped. `sonarr.nix` and `radarr.nix`
differ in six lines. Each module re-declares the same blocks: the
`stack.enable` assertion, the tmpfiles config-dir rule, the podman container
definition with its PUID/PGID/TZ/UMASK env, the `podman-<name>` after/requires
on `podman-network-arr.service`, the firewall line, and the `cg.publish` entry.
That is a shallow module: the interface (options) is nearly as large as the
implementation, and none of the shared wiring is tested anywhere.

The collapse turns those ten into one deep module, `media-service.nix`, with a
small fact-registry interface (`cg.media.<name>`). The shared wiring moves into
its implementation, where it is written once and can be asserted through one
seam. The four genuinely-special modules (qbittorrent/gluetun, cross-seed,
shelfmark, grimmory) keep their special wiring and draw on the module for the
blocks they share.

The load-bearing context is that this codebase already runs four media services
as _native_ NixOS modules — kavita, audiobookshelf, suwayomi, autobrr — behind
the same `cg.service.<name>` interface the containerised ones use, and almost
everything containerised here is already packaged in nixpkgs with a NixOS
module. So the collapse is designed as **one half of a two-adapter seam**: the
podman adapter now, a native-services adapter later, adopted service by service.
The collapse is not throwaway work on the road to de-containerisation; the
container adapter is durable, because some services will never leave it.

## Decisions, 2026-09-06

Taken in a grilling session against the code and nixpkgs facts, then a
design-it-twice pass on the interface. The facts the decisions were taken
against, because they are the whole argument:

- **nixpkgs (the pinned revision) already packages nearly everything native**:
  sonarr, radarr, prowlarr, seerr, bazarr, flaresolverr, shelfmark, cross-seed,
  qbittorrent, unpackerr, recyclarr all have packages _and_ NixOS modules.
  **Not packaged**: wizarr, maintainerr, cleanuparr, huntarr, grimmory — and
  **gluetun is absent from the pinned revision entirely**.
- **The VPN trio** — qbittorrent, cross-seed, shelfmark — shares gluetun's
  network namespace (`--network=container:gluetun`), which is the one thing
  container networking does that a native service does not get for free.
- **Only cross-seed's image is pinned** (`:6`, and grimmory's mariadb sidecar);
  everything else drifts on `:latest` + `--pull=newer`.

The decisions:

- **The collapse is the container adapter of a two-adapter seam.** The module
  is designed so a native adapter can satisfy the same interface later; only
  the podman side is built now. The `mode` field is deliberately _not_ added
  yet — one adapter in the registry means the seam is hypothetical until a
  second exists, and adding `mode` when the native project starts is additive,
  not a re-architecture.
- **gluetun and the VPN trio stay containerised, decided now.** Containers earn
  their keep exactly here: the namespace _is_ the leak-prevention mechanism.
  Native network-namespace routing is its own project with a worse risk
  profile, not a phase of this one.
- **The unpaged long tail stays containerised.** wizarr, maintainerr, cleanuparr,
  huntarr and grimmory have no nixpkgs package; packaging five niche apps whose
  only reason to be native is the goal itself is scope creep. They are why the
  container adapter is durable.
- **The adapter is a primitive, not a monolith.** The ten plain services
  instantiate it; the four specials keep their special wiring and call it for
  common blocks. An adapter that swallowed qbittorrent's gluetun machinery or
  grimmory's sidecar would grow an interface as large as the implementations it
  replaces — the shallowness returning through the back door.
- **Native migration is future work.** This exploration produces the container
  adapter. The interface is designed to admit a native adapter; the adapter
  itself is not built now, and neither is the catalog idea (a central app
  registry replacing the per-service modules) — hosts keep writing
  `cg.service.<name>.enable` and `.port`, which is the interface the fleet and
  the peers already read.
- **Images pin to major-level tags.** Patch and feature updates still flow from
  the registry on restart; a major upgrade becomes a deliberate, reviewable
  flake change. This matches cross-seed's existing `:6` choice and grimmory's
  pinned mariadb.

### The interface choice

Four interfaces were designed in parallel and compared on depth, locality and
seam placement. The accepted shape is Design 3's defaults-rich registry —
common case of two fields, every other fact derived from the name — structured
the way Design 4 argued: the render is an adapter-neutral function over an
evaluated entry, so a native adapter slots in later. Two of Design 2's cheapest
invariants are adopted (no ports published from a shared namespace; host-port
collisions name both services). Design 2's fuller surface (capabilities,
devices, healthcheck, env files) was rejected: those are pass-throughs the
module does not understand, and the specials can keep them in their own modules.
Design 1's hidden default-tag table was rejected: a tag is a per-service
decision, and hiding it makes a major bump invisible.

## The interface: `cg.media.<name>`

`modules/services/media-stack/media-service.nix` declares one registry option,
`cg.media.<name>`, an `attrsOf` submodule. The thin service modules keep
`cg.service.<name>.enable` and `.port`, import `./media-service.nix`, and set
their entry. `media-service.nix` imports `publish.nix` once and renders every
entry whose `image` is set.

| option | type | default | notes |
| ------ | ---- | ------- | ----- |
| `image` | str, mandatory | — | full ref incl. major tag (`lscr.io/linuxserver/sonarr:4`). Asserted `ref:tag`, tag `!= latest`. |
| `port` | port | `containerPort` | host-facing port; the thin module sets it from its `cg.service.<name>.port` option. |
| `containerPort` | port | `port` | the app's fixed internal listen port (8989 for sonarr). Kept separate so changing the host port cannot move the app's internal port. |
| `userMode` | enum `env`/`user`/`none` | `"env"` | `env` = PUID/PGID env vars (linuxserver style); `user` = podman `user = uid:gid` (maintainerr, cross-seed); `none` = neither (seerr, flaresolverr, wizarr, huntarr). |
| `mountData` | bool | `false` | volume `${dataPath}:/data`. Opt-in; only sonarr/radarr/bazarr/cross-seed need it. |
| `config` | nullOr submodule | `{}` | `host` default `${configPath}/<name>`, `target` default `/config`. `null` = no state volume and no tmpfiles dir (flaresolverr). |
| `volumes` | listOf str | `[]` | extra `host:container` mappings (cleanuparr's downloads and blacklist, cross-seed's config.js). |
| `environment` | attrsOf str | `{}` | merged _over_ the derived base env; caller wins (cleanuparr's `UMASK = "022"` overrides the `"002"` default). |
| `extraOptions` | listOf str | `[]` | `--pull=newer` and `--network=` are always added; caller adds `--init`, `--add-host`, etc. |
| `network` | str | `"arr-network"` | or `container:<other>`; shared namespaces suppress the derived port mapping and the firewall. |
| `dependsOn` | listOf str | `[]` | podman `depends_on` plus systemd ordering (cross-seed on gluetun). |
| `cmd` | nullOr listOf str | `null` | image command override (cross-seed `["daemon"]`). |
| `publish.enable` | bool | `true` | `false` for headless services (flaresolverr, huntarr). |
| `publish.subdomain` | str | `name` | seerr → `requests`, wizarr → `invite`. |
| `publish.rateLimitProfile` | enum | `"admin"` | seerr → `media`, maintainerr → `none`. |
| `publish.probePath` | str | `""` | cleanuparr → `/health`. |
| `publish.proxyExtraConfig` | lines | `""` | kept for the qbittorrent special case. |
| `openFirewall` | bool | `true` | the hook structural-cleanup item 5 will flip to false; auto-suppressed in shared namespaces. |

The derived base env is `TZ = config.time.timeZone` always, plus PUID/PGID and
`UMASK = "002"` when `userMode = "env"`, with the caller's `environment` merged
last. The implementation renders, per entry: the podman container definition;
`systemd.services.podman-<name>` ordered after `podman-network-arr.service` and
each `dependsOn` (and the namespace owner when `network = container:<other>`);
the tmpfiles config-dir rule; the firewall line when `openFirewall` and not a
shared namespace; and the `cg.publish.<name>` entry when `publish.enable`.

### Invariants

1. **Tag discipline** — `image` must contain `:` and must not end `:latest`.
2. **media-stack required** — one assertion for the whole registry, naming the
   entries: any rendered entry requires `cg.service.media-stack.enable`.
3. **Port collision** — rendered entries with a derived mapping must have
   distinct `port` values; a collision names both services (today it is a
   silent runtime bind failure).
4. **Shared namespace** — `network = container:<other>` suppresses the derived
   port mapping and the firewall; an explicit non-empty `ports` then fails with
   "ports belong on the namespace owner".

Dropped: Design 2's "sibling must exist" assertion cannot hold across modules
(gluetun lives in qbittorrent.nix), and cross-seed/shelfmark already carry
their own `qbt.enable` assertions. There is no `ports` option — the derived
mapping plus `network` covers every current use.

## Thin modules after the collapse

```nix
# modules/services/media-stack/sonarr.nix  (91 lines → ~20)
{ config, lib, ... }:
{
  imports = [ ./media-service.nix ];

  options.cg.service.sonarr.enable = lib.mkEnableOption "Sonarr TV show management";
  options.cg.service.sonarr.port = lib.mkOption { type = lib.types.port; default = 8989; };

  config = lib.mkIf config.cg.service.sonarr.enable {
    cg.media.sonarr = {
      image = "lscr.io/linuxserver/sonarr:4";
      containerPort = 8989;
      port = config.cg.service.sonarr.port;
      mountData = true;
    };
  };
}
```

Each thin module keeps only its genuinely-service-specific options (`cleanuparr.basePath`,
`maintainerr.basePath`) and the env lines that consume them.

## Done when

No port number, image or firewall line appears in the ten thin modules outside
`cg.media.<name>` and the `cg.service.<name>` enable/port options. The generated
container definitions, `cg.publish` entries, firewall rules and tmpfiles rules
are byte-identical to today's for both hosts — the regression check below says
so, not an eyeball diff. Every image is pinned to a major-level tag. Adding a
new plain media service is a config leaf, not a 90-line copy.

## Risks

- **The collapse must change nothing.** It is a no-behaviour-change refactor; the
  regression check is the gate that makes that claim verifiable. The one
  behavioural hazard is image pinning, which moves every service off
  `:latest`. Pin to the current major _after_ verifying what each host is
  actually running; a wrong major is a downgrade or an invisible upgrade, and
  either is the kind of thing the gate should catch on a host diff.
- **The specials' borrow is the risky part.** cross-seed and shelfmark get
  their network flip and dependsOn from the primitive; their existing
  assertions (`qbt.enable`, prowlarrUrl, torznab) must survive the move
  untouched. qbittorrent and grimmory are out of scope for the first cut — do
  not let the primitive's interface grow to absorb them.
- **`flaresolverr` creates a config dir today that it does not mount.** The
  `config = null` case drops the dir; that is a deliberate correction, and it
  is the one place the generated tmpfiles differs from today. Flag it in the
  regression review rather than papering over it.

## Sequencing

1. Land `media-service.nix` and migrate the ten thin modules in one PR, with
   the regression check. Pin each image to its current major.
2. Migrate cross-seed and shelfmark onto the primitive for their common blocks,
   as a second PR, same regression gate.
3. Defer: the native adapter (`mode` field, added when that project starts);
   the catalog (rejected); qbittorrent/gluetun and grimmory (stay special);
   `openFirewall = false` (structural-cleanup item 5).

## Checks

`checks/media-service.nix`, eval-only, no VM — the sandbox cannot boot
containers, and the whole point of the deepening is that the shared wiring is
assertable through one interface:

1. **Port → three consumers** — a fixture entry at `port = 9999` lands in
   `cg.publish.<name>.port`, the container's `ports = ["9999:9999"]`, and the
   firewall.
2. **Tag discipline** — `:latest` and a tagless ref each raise the assertion; a
   major tag passes.
3. **Invariants** — shared-namespace with explicit ports fails; port collision
   fails naming both; a service enabled without media-stack fails.
4. **Behaviour-preserving regression** — evaluate homelab01 and homelab02 with
   the collapsed modules and diff the generated containers, `cg.publish`,
   firewall and tmpfiles against the pre-collapse values. Byte-identical, or the
   collapse is wrong.
