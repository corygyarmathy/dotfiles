# Agent Instructions

## Repository

This repository is Cory's NixOS fleet configuration. It manages the hosts through a gated GitOps pipeline (see further: [[.github/workflows/README.md]]).

## Formatting

`nix fmt` (treefmt with ./treefmt.toml) is the formatter of record, and CI
gates on `nix fmt -- --ci`. The editor (conform.nvim) and the agent harnesses
delegate to the same pipeline, so there is one formatting decision and it
lives in ./treefmt.toml, .prettierrc.yaml and .markdownlint-cli2.yaml - see
ADR 0008 for why it is shaped this way.

- Run `nix fmt` once from the repo root before finishing, whatever you
  touched. Do not hand-format files the pipeline covers, and do not re-read a
  file and re-edit it purely to adjust formatting beyond that single pass. If
  `nix fmt -- --ci` still disagrees afterwards, report the mismatch instead
  of retrying.
- Files in the `excludes` of ./treefmt.toml are deliberately outside the
  pipeline. Leave them alone rather than formatting them by hand.

## Validation

Add or update a check when changing observable service behavior: CI should
always gate objective _correctness_. Useful checks include:

```bash
nix flake check --print-build-logs
nix build --print-build-logs ".#nixosConfigurations.<host>.config.system.build.toplevel"
```

Use the host names `homelab01`, `homelab02`, and `xps15`. For local iteration,
`nixos-rebuild build --flake .#<host>` avoids activation.

The checks in `checks/` are NixOS VM behavior tests and are part of
`nix flake check`; do not treat a successful evaluation alone as proof that a
service starts or that its generated configuration is valid.

## Secrets And Safety

- All repo secrets are encrypted with `sops` in `secrets/`. See further: [[secrets/README.md]].
- Do not weaken SSH, firewall, SOPS, service confinement, deployment gates, or
  branch protections to make a check pass.
- Do not run destructive commands, activate a configuration on a remote host,
  or run deployment or recovery commands without explicit confirmation.

## Change-Specific Guidance

- New NixOS service modules belong under `modules/services/` and are imported
  automatically. Follow the `cg.service.<name>.enable` pattern.
- Host-specific choices belong under `hosts/<host>/`; shared behavior belongs
  in the appropriate `modules/` subtree.
- `profiles/` holds decisions shared by every machine (`common.nix`) or by a
  kind of machine (`server.nix`, `workstation.nix`). A profile has no options:
  anything that must differ per host is a module under `modules/nixos/`, with
  the host supplying the differing value.
- Changes to a package updater should be made in that package. The workflow
  discovers packages through `passthru.autoUpdate`.
- Adding a host requires adding it to the build matrix in
  `.github/workflows/ci.yml`; otherwise the gate does not protect it.
- Adding a flake check likewise requires adding it to the `checks` matrix in
  `.github/workflows/ci.yml`; the `lint` job fails when the two lists
  disagree.
- Changes to deployment semantics should include documentation or an ADR when
  they introduce or alter a durable architectural decision.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (via the `gh` CLI). See
`docs/agents/issue-tracker.md`.

### Triage labels

Five canonical roles map 1:1 to the tracker's label strings. When triaging,
including deciding between `ready-for-agent` and `ready-for-human`, see
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root. See
`docs/agents/domain.md`.

### Documentation

Which document owns a given fact (issue, ADR, plan, findings note, PR, commit,
README, code comment), and when a plan entry gets deleted rather than kept for
reference. Read before writing a plan, an ADR, or anything that might restate
a fact another document already owns. See `docs/agents/documentation.md`.
