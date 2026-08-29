# Plan: structural cleanup

Status: drafted 2026-08-28. Items 0 and 1 landed the same day, items 2 and 3 on 2026-08-29; nothing else started.

This is a refactoring plan, not a feature plan. Almost none of it changes what the fleet does; most of it changes where a fact is written down and who is allowed to read it. Two items are exceptions and are marked as such — the secrets re-key (item 4) and closing the service ports (item 5) both change behaviour on running machines. Items 1 and 2 are marked `minor`: each changed a handful of lines of generated configuration, and each lists them under what it landed. Item 2's are the probe list it exists to fix.

The pipeline, the checks harness and the documentation are in good shape and are not the subject here. What has not kept up is the boundary between a host and a module: hosts transcribe facts that modules already know, modules hardcode facts about specific hosts, and the same value is written down in three places with nothing to notice when the copies diverge. Every item below is an instance of that one problem.

| #   | Item                              | Size   | Changes behaviour | Depends on | Status                |
| --- | --------------------------------- | ------ | ----------------- | ---------- | --------------------- |
| 0   | Gate hygiene and budget           | small  | no                | —          | **done** 2026-08-28   |
| 1   | A fleet source of truth           | medium | minor             | —          | **done** 2026-08-28   |
| 2   | Services publish themselves       | large  | minor             | 1          | **done** 2026-08-29   |
| 3   | Hosts become profiles + toggles   | medium | no                | 2          | **done** 2026-08-29   |
| 4   | Per-host secret scoping           | large  | **yes**           | 1          | not started           |
| 5   | Caddy as the real boundary        | medium | **yes**           | 1, 2       | not started           |
| 6   | Decouple modules from the fleet   | small  | no                | 1          | not started           |
| 7   | Documentation follows the code    | small  | no                | 1–6        | not started           |

Suggested order is the numbering. Item 0 first because the gate is currently over budget and every later PR pays that cost. Items 1–3 are one continuous piece of work and are only split because each has a natural landing point. Items 4 and 5 are the two that need a deliberate deploy and a rollback plan, and both are much easier once item 1 exists.

---

## 0. Gate hygiene and budget

### The problem

**The gate is over budget again.** [Item 4 of the hardening plan](deployment-hardening.md) recorded on 2026-08-26 that `flake check` had overtaken `build xps15` and was fixed back inside it. Two days later it is outside again. Measured on run `33151623433` (2026-08-28, the most recent `master` run):

| Step                | Duration |
| ------------------- | -------- |
| `Check flake`       | 4m18s    |
| `Build xps15`       | 3m12s    |
| Gate wall clock     | **5m15s** |

So the ~4 minute target is already missed by a minute, and the thing missing it is the checks job rather than the host build the target was derived from. This matters now rather than later because several items below want to _add_ checks, and each one lands on the critical path as things stand.

The fix is not to make the tests cheaper. It is that `nix flake check` runs ten independent checks in one job, so the job is as slow as their sum and one runner does all of it. Sharding them across the matrix makes the job as slow as the _slowest_ check, and GitHub gives us the parallel runners for free. `nix build .#checks.x86_64-linux.<name>` per matrix entry, with the existing `nixos ci` aggregate job unchanged as the required status context.

**There is no formatter gate.** 20 of the 133 tracked `.nix` files do not satisfy `nixfmt --check`, including `modules/services/monitoring/monitoring.nix` and `modules/services/digital-garden/digital-garden.nix` — the two largest modules, which are exactly where a formatting-noise diff hides a real change. The flake has no `formatter` output either, so `nix fmt` does nothing.

**Dead code in `lib/`.** `mkNixosModule`, `mkHomeModule` and `importDir` have no callers anywhere in the repo; only `importDirRecursive` is used. `mkHomeModule` additionally shadows its own `config` argument and could not work if it were called. Three of the four helpers in the file are unreachable, which makes the file misleading to read.

### Approach

One PR, in this order so the formatting churn is isolated:

1. Add `formatter = nixfmt` to the flake and run it over the tree. Pure whitespace, one commit, easy to skip when reading history.
2. Add a `fmt` job to `ci.yml` running `nix fmt -- --check`. It does not need Nix's store, so it costs seconds and never touches the critical path. Add it to `gate`'s `needs`.
3. Delete the three unused helpers from `lib/default.nix`.
4. Shard `checks` across the matrix.

Consider `statix` and `deadnix` in the same job while it exists — both are fast and both find the class of thing item 6 is otherwise doing by hand. Worth running once locally before committing to them; if either is noisy against this tree, drop it rather than adding a suppression file.

### Done when

`nix fmt -- --check` passes and is enforced by the gate, and the gate's wall clock is bounded by `build xps15` rather than by the checks.

### Risks

Sharding multiplies runner-minutes even as it reduces wall clock — ten jobs, each paying ~30s of installer and Cachix setup. That is the trade being made deliberately. If the shard count becomes the cost, group the cheap static checks (`alert-rules`, `alert-rules-unit`, `alertmanager-config`, `bless-boot-guard`, `digital-garden-sync-health`) into one entry and shard only the VM tests.

### What landed

All four pieces, plus two the approach above did not anticipate.

`nix fmt` is `nixfmt-tree`, not bare `nixfmt`: `nix fmt` hands the formatter a directory, and nixfmt deprecates directory arguments in favour of exactly that wrapper. It also gives a `--ci` mode, which is what the gate runs.

The tree-wide format was **verified inert rather than assumed**. For each of the 20 files, `nix-instantiate --parse` produces a byte-identical AST before and after; the only file whose AST changed is `flake.nix`, and only in the line adding the formatter. A whitespace pass over `monitoring.nix` is exactly the kind of change nobody reads, so it is worth being able to say it changed nothing rather than believing it.

The format gate was checked against a deliberate break in both directions, the way the behaviour tests are: unformatted tree exits 1, clean tree exits 0. Worth doing, because `treefmt` formats *in place* and then fails - so a naive second invocation reports success, and a gate tested only once looks like it works when it does not.

**Sharding needed two things `nix flake check` was doing incidentally.** Building each check by attribute path no longer evaluates the flake as a whole, so `devShells`, `packages` and `apps` stopped being evaluated at all - `lint` evaluates those three by attribute to keep that. (`overlays` is applied by every host build and `formatter` by the fmt step, so neither needed covering.) And the matrix names its shards rather than discovering them, because a discovery job serialises ahead of every shard and eats most of the saving; the price is that a check dropped from the matrix stops running silently, so `lint` asserts the matrix and `checks/default.nix` list the same names. That assertion was also tested against a deliberate break in both directions - a check removed from the matrix, and a phantom check added to it.

The gate-timing history is recorded in [the hardening plan](deployment-hardening.md) under "It outgrew it again two days later", including the part worth keeping: this was the third occurrence, and the two previous fixes both worked by making one test faster, which is a fix with a shelf life.

### Measured, 2026-08-28

Run `33181496820` (PR #90, all green):

| Job                      | Duration  |
| ------------------------ | --------- |
| `build xps15`            | **3m42s** |
| `check grafana` (slowest shard) | 2m43s |
| `check upgrade-verify`   | 2m32s     |
| `lint`                   | 1m06s     |
| `build homelab01`        | 1m51s     |
| **gate wall clock**      | **3m51s** |

Inside the ~4 minute budget, and bounded by `build xps15` rather than by the checks - which is what the item was for. The checks axis went from `flake check`'s 4m18s to a slowest shard of 2m43s.

The number that makes the point is the **sum** of the shards: 14m20s. That is what a single job pays before `--max-jobs` claws any of it back, and it is the quantity that grows every time a check is added. The gate now pays the maximum instead, so the next test costs a runner rather than wall clock.

Two smaller observations, both expected:

- `lint` went from 43s to 1m06s when `nix flake check --no-build` was replaced by direct evaluation, because evaluating `apps` pulls in homelab01's whole config. Still far inside the host builds.
- The **first** run of this branch built `xps15` in 5m01s rather than 3m42s. Reformatting 20 module files changes their derivations, so that run was paying for its own whitespace commit against a cold cache. Worth knowing before reading a single slow run as a regression.

---

## 1. A fleet source of truth

### The problem

There is no place that says what the fleet _is_. Host names, addresses, the domain and which host runs what are each written down several times, in files that have no way to notice when they disagree.

- **Addresses.** `10.20.2.85` and `10.20.2.130` appear in 26 non-comment positions across `hosts/` and `modules/`, including `modules/services/adguard-home.nix:32-33`, which holds a literal `servers = { homelab01 = "10.20.2.85"; homelab02 = "10.20.2.130"; }` — a general-purpose DNS module carrying this specific fleet's addressing.
- **The domain.** `gyarmathy.co` is bound three times — a `let` in `modules/services/reverse-proxy.nix:45`, an option default in `modules/services/cloudflare-tunnel.nix`, and then spelled out again in roughly forty probe URLs across the two hosts.
- **Scrape targets.** `modules/services/monitoring/monitoring.nix:330-341` defaults `scrapeTargets` to `[ "homelab01:9100" "homelab02:9100" ]`, and both hosts then set the same list again explicitly. Three copies, one of which lives inside the module that is meant to be reusable.

The failure mode is silent divergence, and it has already happened — see item 2.

### Approach

A plain data file, `fleet/default.nix`, holding an attrset of hosts: address, role, and whatever else is genuinely fleet-level (the domain, the LAN CIDR). No `mkIf`, no options, no `config` — data, so it can be read at flake level by `checks` and `apps` as well as by modules.

Surface it twice, deliberately:

- **`specialArgs.fleet`** for flake-level consumers and for anything that needs it before the module system is running.
- **`config.cg.fleet`**, an option carrying the data as its **default**, declared in an ordinary module (`modules/nixos/fleet.nix`) as `mkOption { type = …; default = import ../../fleet; }`. Modules consume it through `config` like everything else instead of taking an extra function argument, and a module that reads `config.cg.fleet.hosts.homelab02.address` stays a normal NixOS module.

**Two things about that declaration are load-bearing, and both are easy to get wrong.**

_The data belongs in the option's `default`, not in a definition from `mkHost`._ The two look equivalent and are not. The VM tests in `checks/` instantiate modules directly and never go through `mkHost`, so under the `mkHost` design the first module to read `config.cg.fleet` breaks every check containing it, and the fix is to teach `checks/lib.nix` to inject a fleet into every test — a harness change caused entirely by where the value was put. As a default, every module-system evaluation gets the fleet, tests included, and `mkHost` sets nothing.

_Do not mark it `readOnly`._ It is the obvious thing to reach for — the value is meant to come from one place — and it silently costs the property this design exists for. `readOnly` counts the option's own default among its definitions, so `readOnly = true` together with `default = …` rejects **any** override, not just a second one:

```
error: The option `cg.fleet' is read-only, but it's set multiple times.
```

That would leave every check permanently stuck with the production fleet, unable to exercise a module against a different one. A plain option with a default keeps the single-source-of-truth property by convention rather than by mechanism, and a non-merging type still turns an accidental double definition into a conflict error, which is most of what `readOnly` was wanted for anyway.

`specialArgs.fleet` stays for flake-level consumers — `checks`, `apps` — which are outside the module system entirely and cannot read `config` at all.

The distinction worth keeping is between _fleet facts_ and _host choices_. `homelab02`'s address is a fleet fact. That `homelab02` runs qBittorrent is a host choice and belongs in `hosts/homelab02/`. Putting the second kind into `fleet/` recreates the monolith one level up.

### Done when

No `.nix` file outside `fleet/` contains a literal fleet IP address, host name or the domain, except in comments, `example` fields and `hosts/homelab02/disko.nix` (which is consumed by `nixos-anywhere` before any of this exists) — and `checks/` still passes without `checks/lib.nix` having learned anything about the fleet.

### Risks

The temptation to make `fleet/` the place where everything is declared, at which point the host files are empty and the interesting content has just moved. The `Done when` above is deliberately narrow for that reason: it is about literals, not about volume.

### What landed

`fleet/default.nix` holds the domain, the LAN (CIDR and gateway), every host (`kind`, `system`, and an `address` for the two that have a reservation), and a two-entry `roles` map. `modules/nixos/fleet.nix` declares `cg.fleet` with that file as its default, `types.raw`, not `readOnly` — for the reasons the approach gives, both of which are written into that file rather than left here.

**Three things the approach did not anticipate.**

_`nixosConfigurations` is generated from `fleet.hosts`._ It had to be: the `Done when` forbids a literal host name in a `.nix` file, and `mkHost { hostname = "homelab01"; … }` is one. `mkHost` now takes a name and that host's fleet entry, and `nixpkgs.lib.mapAttrs mkHost fleet.hosts` is the whole `nixosConfigurations` output. The `extraModules` argument went with it: the nixos-hardware modules a machine needs are a property of that machine, so each `hosts/<name>/default.nix` imports its own. Adding a host is now an entry in `fleet/` and a directory beside it. The build matrix in `ci.yml` still names hosts explicitly, deliberately — a host that stops being built is exactly what the gate is for.

_A module that reads the fleet imports the declaration itself._ Putting the data in the option's default gets a fleet into every module-system evaluation, but only where the option is *declared*, and the checks import single module files rather than `modules/nixos`. So the sixteen modules that read `config.cg.fleet` each carry `imports = [ ../nixos/fleet.nix ]`. Importing one path from several modules costs nothing — the module system keys on it — and it means a check instantiating one module gets the fleet with it, which is what kept `checks/lib.nix` from having to learn anything.

_The override is exercised, not just left possible._ `checks/reverse-proxy.nix` now sets `cg.fleet` to a fleet that is not this one (`example.test`, a `10.0.0.0/24` LAN, no hosts) and asserts against `internal.example.test`. That is the reason the option is not `readOnly` stated as a passing test rather than as a comment, and it took the last of the domain literals out of `checks/`.

**Two things fell out of the rewrite** and are behaviour changes, both small:

- Root's SSH config for backups was `Host 10.20.2.*`. It is now the fleet's own addresses, one at a time. A glob offers the backup key to whatever else answers on the LAN; the addresses are ones this flake already knows.
- The `cloudflared` scrape job is emitted only when `cloudflaredTarget` is set, which is what the option's `null to disable` always claimed — it used to emit `targets = [ null ]` and fail the type check. Its `instance` label is now taken from the target rather than hardcoded, so the peer scraping the tunnel host no longer labels the series with its own name.

### Verified, 2026-08-28

**Inert, not assumed.** For homelab01 and homelab02, every entry in the generated `/etc` was compared against the same host built from `43102b0` (the revision this branched from), and every systemd unit within it. One entry differs on each host: `ssh/ssh_config`, the deliberate change above. Caddy's config file, Prometheus' scrape config, AdGuard's settings, the NFS export and all four restic units are byte-identical.

Five other derivations move — `system-path`, `dbus-1`, `user-units`, and the `nixos-upgrade`, `nixos-deploy-metrics`, `digital-garden-build`, `dbus-broker` and `polkit` units. Those are not this change: comparing `43102b0` against its own parent, a documentation-only commit, moves exactly the same set. They carry `system.configurationRevision`, directly or through `nixos-version` in the system path, so any commit moves them. Worth chasing down rather than waving at, because "some unrelated things also changed" is how a real difference gets missed.

All ten checks pass, including the three VM tests that instantiate a module which now reads the fleet. `nix fmt -- --ci` is clean, and `devShells`, `packages` and `apps` — the three outputs the `lint` job evaluates by hand — still evaluate; `garden-preview` resolves to the same store path it did before, which is the check that the gateway lookup replacing `nixosConfigurations.homelab01` picks the same host.

The `Done when` was checked by script rather than by eye. Four occurrences remain, all of them the host name inside an SSH public key's own comment field (`… coryg@xps15`). That is key material, not a transcribed fleet fact: editing it would change the key.

---

## 2. Services publish themselves

### The problem

**Every service port is declared twice** — once in the module that runs the service, once again as a literal in the host's `reverse-proxy.services` block:

```nix
# modules/services/media-stack/sonarr.nix:33
port = lib.mkOption { type = lib.types.port; default = 8989; };

# hosts/homelab01/default.nix:218
sonarr = { subdomain = "sonarr"; port = 8989; localOnly = true; };
```

Changing the module's port produces no error. It produces a proxy pointing at nothing. This holds for all twelve media-stack services checked, and for the rest of the proxy block besides.

**The host is doing the modules' integration by hand.** `hosts/homelab01/default.nix:558-563` maps `reverse-proxy.services` into `cloudflare-tunnel.services` with an inline `lib.mapAttrs`, picking out the four fields the tunnel understands. That is module-to-module wiring living in a host file, which is the thing the host file is least able to keep correct.

**The monitoring probes have already drifted, and nobody noticed.** The two hosts hand-maintain probe lists that overlap heavily but not exactly — 17 entries on `homelab01`, 13 on `homelab02`, differing by six. Against the 25 hostnames the fleet actually proxies, **seven are probed from nowhere**: `alertmanager`, `bazarr`, `grimmory`, `invite`, `prometheus`, `shelfmark` and `suwayomi`. Two of those (`grimmory`, `invite`) are published to the internet. This is the concrete cost of transcription, and it is why this item is sized `large` and still worth it.

### Approach

Invert the direction. A service module already knows its port, and it is the only thing that does. Let it declare how it should be published, and let the three consumers read a registry rather than a hand-written list.

```nix
# in modules/services/media-stack/sonarr.nix
cg.publish.sonarr = {
  subdomain = "sonarr";
  port = cfg.port;          # the module's own option, not a copy
  localOnly = true;
  probe = true;             # default true; false for things with no useful GET
};
```

`cg.publish` is an `attrsOf submodule` that any module may contribute to. Then:

- `reverse-proxy` builds its virtual hosts from `config.cg.publish`.
- `cloudflare-tunnel` builds its ingress from the same, filtered to `!localOnly`. The `mapAttrs` in the host file is deleted rather than moved.
- `monitoring` derives `httpProbes` from the same, as `https://${subdomain}.${fleet.domain}` — which closes the drift by construction, because a service that is published and not probed becomes impossible to express.

Cross-host publishing (`grimmory` runs on `homelab02` but is proxied from `homelab01`, which owns the tunnel) needs the `upstream` field the proxy already has, and it should come from `fleet` rather than a literal: `upstream = fleet.hosts.homelab02.address`.

The one genuine host-level decision this leaves is _whether_ a service is reachable from outside, which stays a host toggle. `localOnly` is a policy choice, not a property of the software.

### Done when

No port number appears in a host file, `httpProbes` is not written by hand anywhere, and the seven currently-unprobed hostnames are either probed or explicitly marked `probe = false` with a reason.

### Risks

This is the item most likely to sprawl, because `cg.publish` is a small piece of framework and framework attracts features. Keep the submodule to the fields the three consumers actually read today. `proxyExtraConfig` and `rateLimitProfile` already exist on the proxy and should move across unchanged rather than being redesigned in passing.

The probe derivation will _add_ seven probes to a running Prometheus, and new probes on services nobody was watching may well fire. That is the point, but do it on a day when investigating an alert is welcome.

### What landed

`modules/nixos/publish.nix` declares `cg.publish`, an `attrsOf submodule` with nine fields, every one of them read by one of the three consumers. Twenty-two service modules contribute an entry each; `reverse-proxy.nix` builds its vhosts from the registry, `cloudflare-tunnel.nix` its ingress from the `localOnly = false` subset, and `monitoring.nix` its `httpProbes` from all of it. Both hosts' `services` blocks, both probe lists and the `lib.mapAttrs` that wired the proxy into the tunnel are gone — 331 lines out of the two host files against 65 added, most of the latter being the block naming which services face the internet.

**Four things the approach did not anticipate.**

_`localOnly` moved off the modules entirely, including ntfy's._ `ntfy.nix` was already publishing itself into the proxy, and it set `localOnly = false` there. Leaving that would have meant the answer to "what does this host expose" was one block in the host file plus however many modules had opinions. It is now the host's block alone, and the field defaults to `true`, so a service nobody decided about stays off the internet.

_Two web UIs cannot both be `prometheus`._ Every host runs a Prometheus and an Alertmanager, so a module that publishes them unconditionally puts the same hostname on two proxies — where DNS picks one and the other holds a certificate for a name it never serves. They are published where Grafana is, since Grafana is what links to them and runs on one host. Reach the peer's at `<host>:9090` over ssh, as before.

_The probe URL is the `instance` label._ Building it as `https://${subdomain}.${domain}${probePath}` with `probePath` defaulting to `/` appended a trailing slash to all seventeen existing probes and renamed every series they produce — silently cutting the dashboards and alert history off from their own past. The default is `""`, and `probePath` is documented as being about that rather than about tidiness.

_Three more transcribed ports were in scope after all._ `scrapeTargets` and `smartctlTargets` were `map (host: "${host}:9100") servers` in both host files — the same duplication one level down, since `9100` and `9633` are set by `monitoring.nix` itself. They now default to every `server` in `cg.fleet` at the port that module gives its own exporters, and neither host writes them.

The third was the alertmanager-ntfy bridge's `port = 8015` on homelab02, which is the only one of these that changes a running host. It was not a copy of anything — it was a host dodging the module's default, because 8000 is gluetun's control server wherever the media stack runs and the bridge lost that bind race on homelab02 every start. Repairing it per-host left the collision sitting in the default, one host away from happening again, so 8015 is now the default and homelab02 says nothing. The bridge on homelab01 moves 8000 → 8015 with it. Both ends of that port are read from the same option, so the move is self-consistent: the generated diff is Alertmanager's webhook URL and the bridge's listen address, and nothing else. With it gone, no host file contains a port number at all.

**One thing changed on purpose**, and it is the item's whole point: each host now probes what its own Caddy serves. `cg.publish` is per-host and a host cannot see what its peer publishes, so the union of the two lists covers the fleet exactly once, where the hand-written lists covered thirteen hostnames twice and seven not at all. The redundancy is gone with them: a host that is down takes its own probes with it, and is reported by the node and target-down alerts instead of by its peer's probe.

_The one literal that mattered was in a check._ `checks/monitoring.nix` asserted against `http://127.0.0.1:8000/hook`, transcribed from the module. Moving the bridge's default broke that test — and broke it *as* "unauthenticated webhook post was not rejected", a message about authentication that had nothing to do with the cause. Its `testScript` is now a function of `nodes` and reads the port from the option, which is the same lesson as the rest of this item arriving from the direction of a test.

`checks/publish.nix` pins both halves. Against a stand-in service module it asserts that a port set once reaches the vhost, the ingress and the probe, that `localOnly` keeps a service out of the tunnel but not out of Caddy, and that `probe = false` removes the probe but not the vhost. Against the real hosts it asserts that every published entry is probed and that every tunnel hostname is served by the host carrying it — the assertion that would have caught the original drift. It fails as intended: dropping two entries from the probe derivation names `cg.publish.bazarr` and `cg.publish.suwayomi`.

### Verified, 2026-08-29

**Inert, not assumed.** For homelab01 and homelab02, every entry in the generated `/etc` was compared against the same host built from `b950130`, and every systemd unit within it. **`/etc/caddy/caddy_config` is byte-identical on both hosts** — the same store path, from a registry assembled a completely different way, which is the strongest available statement that no service moved.

Four units differ beyond the five that always do:

- `cloudflared-route-dns.service` on homelab01, by ordering alone. The same ten hostnames are registered; the registry is keyed by module name rather than by subdomain, so `invite` now comes last instead of second. `cloudflared tunnel route dns` is idempotent and each call is `|| true`.
- `alertmanager.service` and `alertmanager-ntfy.service` on homelab01, by the bridge port alone: `http://127.0.0.1:8000/hook` becomes `:8015` in Alertmanager's webhook config, and the bridge's `http.addr` follows. Nothing else in either file moves. homelab02 is unaffected — it was already on 8015.
- `prometheus.service` on both, which is the intended change. Every retained probe URL is byte-identical; homelab01 gains `alertmanager`, `bazarr`, `grimmory`, `invite`, `ntfy` and `prometheus` and loses `downloads` and `adguard2` to homelab02, which gains `shelfmark` and `suwayomi` and loses the eleven the gateway fronts. The node and smartctl target lists are unchanged, which is the check on the `scrapeTargets` default.

The five that always move — `system-path`, `dbus-1`, `user-units`, and the `nixos-upgrade`, `nixos-deploy-metrics`, `digital-garden-build`, `dbus-broker` and `polkit` units — are the same set item 1 identified, and move for the same reason: they carry `system.configurationRevision`.

All eleven checks pass, including the reverse-proxy VM test now driven from a `cg.publish` registry rather than the deleted `services` option. `nix fmt -- --ci` is clean, all three hosts build, and `devShells`, `packages` and `apps` still evaluate.

**`publish` is in the `ci.yml` matrix**, which it was not on the first pass — the flake had eleven checks and the matrix ten, so `lint`'s "Every flake check is in the matrix" audit would have failed the PR. That is item 0's audit doing exactly the job it was added for, on the first check added after it landed. Both directions were re-confirmed locally: with the entry the audit reports eleven, without it, it names `publish` and exits 1. Its own shard rather than a group, since it evaluates two whole hosts; item 0's grouping note is about the cheap static checks and only applies once shard count becomes the cost.

The `Done when` was checked by script, and holds without exception: no port number appears in any host file.

---

## 3. Hosts become profiles and toggles

### The problem

`hosts/homelab01/default.nix` is 809 lines and `hosts/homelab02/default.nix` is 691, and a large fraction of both is neither host-specific nor interesting. The two files share, near-verbatim: the locale block (13 lines), the "this is a server, do not sleep" block, the Wake-on-LAN unit, the `fwupd-auto-update` unit ordered before `nixos-upgrade`, the podman block, the `users.coryg` definition with its `media` group and explicit GID, and a 25-package `environment.systemPackages` list. `hosts/homelab01/home.nix` and `hosts/homelab02/home.nix` are byte-identical except for the comment on line 1. The locale block is duplicated a third time in `hosts/xps15/default.nix`.

None of that tells a reader anything about the host. It is the cost of admission for being a machine in this fleet, and it is currently paid three times.

### Approach

A `profiles/` layer between `modules/` and `hosts/`, holding composed opinions rather than options:

- `profiles/common.nix` — locale, time zone, the `coryg` user, editor environment. Imported by every host.
- `profiles/server.nix` — no sleep, Wake-on-LAN, `fwupd` before upgrade, podman, the server package set, the `media` group. Imported by the two servers.
- `profiles/workstation.nix` — whatever falls out of `xps15` once the above two are extracted.
- `profiles/home/server.nix` — replaces the two identical `home.nix` files.

The distinction from `modules/`: a module offers an option and does nothing until enabled; a profile makes a decision. `cg.boot-counting` is a module. "Servers in this fleet do not suspend" is a profile.

Wake-on-LAN is the one that needs care — both hosts hardcode interface `eno1`. That is a hardware fact, so the profile should take the interface from `fleet` or from the host's `hardware.nix`, not assume it.

### Done when

Both server host files are under ~250 lines and contain only: the auto-upgrade block, the `cg.*` toggles, hardware specifics, and things genuinely unique to that machine (`homelab02`'s swapfile, `homelab01`'s Quick Sync packages).

### Risks

Profiles are a well-known place for a config to acquire a second, worse module system. The rule that keeps that from happening: **a profile has no options.** If something in `profiles/` needs to be configurable per host, it is a module and belongs in `modules/`.

### What landed

`profiles/` exists, with the four files the approach named: `common.nix` (75 lines, every host), `server.nix` (161, both servers), `workstation.nix` (85, `xps15`) and `home/server.nix` (39, replacing the two host `home.nix` files). The host files lost 391 lines between them — `homelab01` 657 → 500, `homelab02` 607 → 450, `xps15` 311 → 234 — and no profile declares an option.

`common.nix` took two things the approach did not list, both because they were written out three times and are decisions rather than hardware: `boot.loader.systemd-boot` with `canTouchEfiVariables`, which `cg.boot-counting` has nowhere to write without, and `networking.networkmanager.enable`. It also took only the part of the `coryg` account that is true everywhere — description, `isNormalUser`, `wheel`. Authentication is not portable: the servers read a hashed password from SOPS, set `uid = 1000` because the media tree outlives any particular install, and turn `mutableUsers` off, none of which is true on the laptop, so all of it is in `server.nix`.

**Wake-on-LAN did not become a profile line, and the reason is the item's own risk section.** The obvious implementation is the stock `networking.interfaces.<iface>.wakeOnLan.enable`, which replaces the hand-rolled `ethtool` unit with a systemd `.link` file. It was written, and reverted: nothing else on `homelab02` declares `networking.interfaces.eno1`, so declaring it there to reach that one attribute also generated a `network-addresses-eno1.service`, a udev rule to start it, and two new per-interface sysctls — one of them `net.ipv6.conf.eno1.use_tempaddr`, which changes how the host picks a source address. That is a real change to a running server smuggled in by a refactor that is supposed to change nothing. So Wake-on-LAN is now `modules/nixos/wake-on-lan.nix`, keeping the `ethtool` unit these machines already run: the profile says `cg.wake-on-lan.enable = true` because "a server should be startable without walking to it" is a decision, and each host says `cg.wake-on-lan.interfaces = [ "eno1" ]` because an interface name is a fact about a NIC. Enabling it without naming one is an assertion failure rather than a unit that succeeds while arming nothing. This is exactly the escape hatch the risk section describes — something in `profiles/` that has to be configurable per host is a module — and it is worth noting that the first thing to need it was the first thing the approach flagged as needing care.

`workstation.nix` removes no duplication, because there is one workstation. It exists so the `xps15` file is about the XPS 15 — its screens, thermals, GPU and what it is used for — rather than about a desktop needing an audio server and a way to mount a USB stick. What went in is what a second laptop would want unasked: pipewire, printing and mDNS, dbus, `gvfs`/`udisks2`, the GnuPG agent, `nix-ld`, the keyboard layout. What stayed is anything tied to a `cg.*` toggle: the `i2c`, `docker` and `input` groups are still beside the toggles that need them.

### Verified, 2026-08-29

**Inert, not assumed.** For all three hosts, the generated `/etc` and the `system-path` closure were compared against the same host built from `f095ab2`. Every host's package set is identical apart from `nixos-version`, and the only files that differ in `/etc` are the ones that always do: `dbus-1/session.conf` and `system.conf` and the `dbus-broker` and `polkit` override files, which carry the `system-path` hash; `nixos-deploy-metrics` and `nixos-upgrade`, which carry the revision literally; and on `homelab01` `digital-garden-build`, whose build stamp folds in a store path from the source tree. **Nothing else moves on any host** — no unit added, none removed, and `enable-wol.service` byte-identical on both servers, which is the check that matters most given what the first implementation of it did.

The two server `home.nix` files really were interchangeable: `home.activationPackage` is the same store path for `homelab01` and `homelab02`, before and after, so the profile reproduces both exactly.

**The `Done when` is met structurally and missed numerically.** The host files contain only the auto-upgrade block, the `cg.*` toggles, the hardware, and what is unique to that machine — but they are 500 and 450 lines, not 250. What is left is almost entirely `cg.service` toggles and the comments explaining them: `homelab01`'s backup `paths` and `extraExclude` are 60 lines of prose about which state is regenerable, and its comskip block is 35 lines of tuning constants. Those are toggles, which the `Done when` says stay. Getting under 250 means moving backup paths to the modules that own the state and comskip's tuning into its module's defaults — the same "services publish themselves" move as item 2, applied to state rather than ports, which is item 6's shape rather than this one's. The line target was set against the pre-item-2 files and did not anticipate that item 2 would remove the other kind of bulk first.

---

## 4. Per-host secret scoping

**Changes behaviour. Needs a deploy plan and a way back.**

### The problem

`secrets/.sops.yaml` encrypts `secrets/secrets.yaml` to four keys: the user, `xps15`, `homelab01` and `homelab02`. Every host can therefore decrypt every secret in it. In practice that means a laptop that travels can decrypt the WireGuard private key, the restic repository password, the Grafana admin credentials, the Cloudflare tunnel credentials and the Proton SMTP token — none of which it has any use for. `secrets/homelab.yaml` is scoped to the two servers, which is better, but the split between the two files does not follow any stated rule: `cloudflare/*`, `miniflux/*`, `vikunja/*`, `wallabag/*`, `adguard/*` and `digital-garden/*` pin `sopsFile = ../../secrets/homelab.yaml` explicitly at each declaration site, while `media-stack/*`, `backups/*` and `monitoring/*` fall through to the default and land in `secrets.yaml` — which is also the file the laptop can read.

So the current arrangement has the cost of a split (two files, per-secret `sopsFile` lines scattered through seven modules) without the benefit of one.

The mechanics are otherwise sound, and worth saying plainly since the question was asked: no plaintext secret reaches the Nix store. Modules reference `config.sops.secrets.<name>.path`, which is a `/run/secrets/...` path resolved at runtime, and where a config file needs a secret _inline_ they use `sops.templates` with `config.sops.placeholder.<name>` — the store gets a template with a placeholder, and sops-nix substitutes at activation. `owner`, `group`, `mode` and `restartUnits` are used consistently. That part does not need changing.

### Approach

Make the file boundary mean something: **a secret lives in the file for the host that needs it.**

- `secrets/xps15.yaml` — user key material, wifi PSKs.
- `secrets/homelab01.yaml`, `secrets/homelab02.yaml` — per host.
- `secrets/shared.yaml` — only what genuinely needs to be readable by more than one host, with each entry justified. The restic password is the honest example: both servers back up to the same repositories.

Then delete the per-declaration `sopsFile` lines. With files named after hosts, the mapping belongs in `.sops.yaml`'s `creation_rules` and in one place in `cg.sops-nix`, not repeated across seven modules.

**Add a check.** A secret name typo is currently caught at activation, on the machine, at 04:00. It is checkable at eval time: walk `config.sops.secrets` for the host, walk the keys actually present in the (still encrypted) YAML — `sops` metadata leaves the key structure readable without decrypting — and fail on any referenced name that does not exist. This is cheap, static, and closes the gap where a module references a secret nobody ever added.

### Sequencing

The re-key is the risky part, because a host that cannot decrypt a secret it needs fails to activate.

1. Land the split and the new `.sops.yaml` with **both** old and new keys valid, so nothing loses access.
2. Deploy to `homelab01` by hand with `nixos-rebuild --target-host`, verify every unit that consumes a secret is running, and only then let the nightly take `homelab02`.
3. Remove the now-unnecessary keys from `.sops.yaml` and `sops updatekeys` as a separate, later PR.

Do not combine step 1 and step 3. Splitting them is what makes step 2 recoverable.

### Done when

`xps15`'s age key cannot decrypt any server secret, every `sopsFile` line has been deleted from `modules/`, and a deliberately misspelled secret name fails `nix flake check`.

### Risks

`sops updatekeys` rewrites every value's encryption. Confirm `git diff` shows only `sops:` metadata and ciphertext changes, and that the decrypted plaintext is byte-identical before and after — compare digests, do not print the values.

The host keys are derived from `/etc/ssh/ssh_host_ed25519_key`, so reinstalling a host means re-keying. That is already true and already documented in `secrets/README.md`; the per-host split makes it a smaller operation, not a larger one.

---

## 5. Caddy as the real boundary

**Changes behaviour. Expect breakage in inter-service links.**

### The problem

Every service module opens its own port on the LAN firewall unconditionally:

```nix
# modules/services/media-stack/sonarr.nix:81 — and eleven more like it
networking.firewall.allowedTCPPorts = [ cfg.port ];
```

So `http://homelab01:8989` answers from any device on the LAN. The proxy's `localOnly` matcher, its TLS, its rate limit profiles and its security headers are all reachable around. Whatever `localOnly = true` is protecting, it is not the service.

This is not a module's decision to make. Whether a port is exposed is a host policy, and the module has hardcoded it.

### Approach

Give each service module an `openFirewall` option defaulting to **false**, and bind to localhost where the upstream supports it. The proxy becomes the only path.

**The complication is real and needs mapping first.** Several services talk to each other across hosts by address and port, and closing the ports naively breaks them. The known links, from the tree:

| From                       | To                        | Path                          |
| -------------------------- | ------------------------- | ----------------------------- |
| `cross-seed` (homelab02)   | `prowlarr` (homelab01)    | `http://10.20.2.85:9696`      |
| `shelfmark` (homelab02)    | `prowlarr` (homelab01)    | documented, set in-app        |
| `autobrr` (homelab01)      | `qbittorrent` (homelab02) | documented, set in-app        |
| Caddy (homelab01)          | `grimmory` (homelab02)    | `upstream = "10.20.2.130"`    |
| Prometheus (both)          | node/smartctl exporters   | `homelab0N:9100`, `:9633`     |
| restic (both)              | peer host                 | SFTP                          |
| `homelab01`                | `homelab02`               | NFS                           |

Some of these are configured inside a service's own database rather than in Nix, which means the config cannot see them and a build cannot catch them. Sonarr and Radarr pointing at qBittorrent are the likely cases.

So: **a peer allowance, not a blanket open.** `fleet` knows the addresses, so a module can express "this port is reachable by `homelab02` and nobody else" and get an interface-scoped rule rather than a global `allowedTCPPorts` entry. That keeps the LAN out while keeping the fleet's own traffic working, and — unlike today — the allowance is written down where someone can read it.

### Sequencing

Do not do this in one PR.

1. Add `openFirewall` (default `true`, matching current behaviour) to every service module. No behaviour change; this is the escape hatch existing first.
2. Add peer allowances for the links in the table above.
3. Flip the default to `false`, one host at a time, and set `openFirewall = true` explicitly in the host for anything found to need it.
4. Remove the leftovers once nothing has complained for a couple of weeks.

Step 3 is where things break, and they will break as "a service quietly stops importing" rather than as a failed unit. Check Sonarr's and Radarr's download client connectivity, cross-seed's search, and autobrr's push targets by hand after each host.

### Done when

`nmap` against a server from a LAN client shows only the ports the host explicitly declares, and every service still reaches the peers it needs.

### Risks

The in-app configuration is the part no check can cover — the same limitation [item 8 of the hardening plan](deployment-hardening.md) ran into with the download root. Assume the map above is incomplete and treat step 3 as an experiment with a fast revert, not as a refactor.

---

## 6. Decouple modules from the fleet

### The problem

Reusable modules carry knowledge of this specific installation, which is what makes them not reusable. Item 1 took the literals out; what it did not do is make the defaults right for a machine outside this fleet.

- `modules/services/adguard-home.nix` — the literal host-to-address map is gone, but the module now *requires* `cg.fleet.roles.gateway` and `.storage` to name real hosts, and its `gatewaySubdomains` / `storageSubdomains` lists are still this installation's service map living in a general-purpose DNS module. That is item 2's to move; what belongs here is that the module should say so rather than failing on a missing attribute.
- `modules/services/media-stack/cross-seed.nix` — `prowlarrUrl` still defaults to the gateway host's address, i.e. the module still defaults to another machine in this fleet.
- `modules/services/immich.nix:111` — `DB_PASSWORD=changeme-use-sops-for-real-deployment`. The service is disabled everywhere, so this is not live, but a literal password in a module is the kind of thing that survives being enabled.
- `modules/services/digital-garden/digital-garden.nix` — adds a Caddy virtual host without enabling Caddy. Already noted in the hardening plan as "a coupling that is invisible until it bites"; it should be an assertion.

Two entries the draft listed are already closed: `adguard-home`'s `10.20.2.1` PTR upstream is `cg.fleet.lan.gateway`, and `monitoring.nix`'s `scrapeTargets` and `smartctlTargets` already defaulted to `[ ]` with the fleet's names only as an `example`.

### Approach

Once item 1 exists, most of these become a read from `config.cg.fleet` or an option with no default. The rule: **a module's default should be correct for a machine that is not in this fleet, or there should be no default and an assertion instead.** `cross-seed` without a Prowlarr URL should fail to build with a clear message, not silently point at `homelab01`.

The `immich` placeholder should be deleted and the module should assert that a secret is configured. The `digital-garden` case is a one-line assertion that `cg.service.reverse-proxy.enable` is on.

29 modules already use `assertions`, so the pattern is established; this is applying it where it was skipped.

### Done when

Item 1's `Done when` holds, and no module has a default that only makes sense inside this fleet.

---

## 7. Documentation follows the code

### The problem

The documentation is genuinely good and mostly needs to not be broken by items 1–6 rather than to be rewritten. But some of it will go stale on contact:

- `README.md` and `docs/runbooks/fleet-map.md` both describe the topology that item 1 makes machine-readable. The fleet map in particular should be generated from `fleet/` or reduced to a pointer, rather than being a hand-maintained second copy of it — it is the same transcription problem as the probes.
- `AGENTS.md` says "New NixOS service modules belong under `modules/services/` and are imported automatically. Follow the `cg.service.<name>.enable` pattern." After item 2 there is a second half to that: a service that is reachable over HTTP also declares `cg.publish`. After item 3 there is a `profiles/` layer to explain and a rule for when something belongs there.
- `secrets/README.md` documents the current single-file arrangement and will need the per-host mapping.

### Approach

Take it at the end, in one pass, rather than editing docs alongside each item — the shape is not settled until item 5 lands, and documentation written against an intermediate state gets written twice.

Two things worth adding rather than updating: an ADR for the fleet layer (the choice of a plain data file over per-host `specialArgs` or a flake-parts style registry is exactly the kind of decision ADRs exist to record), and a short `modules/README.md` stating the three-way distinction between `lib/`, `modules/` and `profiles/`, since that is the organising idea the tree will then be built on and it is currently only implicit.

### Done when

A reader can answer "where does this belong?" from `modules/README.md`, and no document restates a fact that `fleet/` now holds.

---

## What this plan deliberately does not do

- **Split the large modules.** `monitoring.nix` (952 lines) and `digital-garden.nix` (729) are big, but both are internally sectioned and coherent, and neither is duplicated anywhere. Size alone is not the problem this plan is about. Revisit if either grows a second reason to change.
- **Reorganise `modules/services/media-stack/`.** 26 modules in one directory is a lot, but they are genuinely one stack and the flat layout makes them easy to find.
- **Add checks for the untested modules.** `backup`, `adguard-home`, `nas-storage`, `cloudflare-tunnel` and the whole media stack have no behaviour test. That is a real gap and a real backlog item; it is not this plan, and item 0 is the prerequisite for taking it on without blowing the gate budget.
- **Touch the deployment pipeline.** It works, it is documented, and the remaining gaps are already tracked in [the hardening plan](deployment-hardening.md).
