# Plan: structural cleanup

Status: drafted 2026-08-28. Item 0 landed the same day; nothing else started.

This is a refactoring plan, not a feature plan. Almost none of it changes what the fleet does; most of it changes where a fact is written down and who is allowed to read it. Two items are exceptions and are marked as such — the secrets re-key (item 4) and closing the service ports (item 5) both change behaviour on running machines.

The pipeline, the checks harness and the documentation are in good shape and are not the subject here. What has not kept up is the boundary between a host and a module: hosts transcribe facts that modules already know, modules hardcode facts about specific hosts, and the same value is written down in three places with nothing to notice when the copies diverge. Every item below is an instance of that one problem.

| #   | Item                              | Size   | Changes behaviour | Depends on | Status                |
| --- | --------------------------------- | ------ | ----------------- | ---------- | --------------------- |
| 0   | Gate hygiene and budget           | small  | no                | —          | **done** 2026-08-28   |
| 1   | A fleet source of truth           | medium | no                | —          | not started           |
| 2   | Services publish themselves       | large  | no                | 1          | not started           |
| 3   | Hosts become profiles + toggles   | medium | no                | 2          | not started           |
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

Reusable modules carry knowledge of this specific installation, which is what makes them not reusable:

- `modules/services/adguard-home.nix:32-33` — a literal map of host names to addresses.
- `modules/services/adguard-home.nix:394` — `10.20.2.1` as a PTR upstream, commented "Your router".
- `modules/services/media-stack/cross-seed.nix:198` — `prowlarrUrl` defaults to `http://10.20.2.85:9696`, i.e. the module defaults to another host in this fleet.
- `modules/services/monitoring/monitoring.nix:330-341` — `scrapeTargets` defaults naming `homelab01` and `homelab02`.
- `modules/services/immich.nix:111` — `DB_PASSWORD=changeme-use-sops-for-real-deployment`. The service is disabled everywhere, so this is not live, but a literal password in a module is the kind of thing that survives being enabled.
- `modules/services/digital-garden/digital-garden.nix` — adds a Caddy virtual host without enabling Caddy. Already noted in the hardening plan as "a coupling that is invisible until it bites"; it should be an assertion.

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
