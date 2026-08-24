# Agent Instructions

## Repository

This repository is Cory's NixOS fleet configuration. It manages `homelab01`,
`homelab02`, and `xps15` through a gated GitOps pipeline.

- `master` is the integration branch. Changes go through pull requests.
- `deploy` is the only promoted ref and the only ref followed by the fleet.
- CI builds every host and runs `nix flake check` before promoting `deploy`.
- `flake.lock` is maintained by the scheduled `flake-update` workflow; do not
  update it manually unless the user explicitly asks.
- Never create a branch whose name starts with `deploy/`; Git ref layout makes
  that conflict with the `deploy` branch.

Read the relevant README, workflow documentation, ADR, or hardening-plan entry
before changing behavior that affects deployment, rollback, services, or
security. Prefer existing module patterns over introducing new abstractions.

## Working Method

1. Inspect the relevant files and trace how the current configuration works
   before editing.
2. State important assumptions when the request is ambiguous. Do not broaden a
   focused change into an unrelated refactor.
3. Make the smallest correct change and preserve established naming and layout.
4. Add or update a check when changing observable service behavior, especially
   for configuration parsing, HTTP behavior, publication filters, or deployment
   safety.
5. Review `git diff` and `git status` after editing. Do not modify or revert
   unrelated user changes.
6. Run the narrowest useful checks, then run the full relevant check when
   practical. Report commands, results, and any checks that could not run.

## Validation

Useful checks include:

```bash
nix flake check --print-build-logs
nix build --print-build-logs ".#nixosConfigurations.<host>.config.system.build.toplevel"
```

Use the host names `homelab01`, `homelab02`, and `xps15`. For local iteration,
`nixos-rebuild build --flake .#<host>` avoids activation. Do not activate a
configuration on a remote host or run deployment/recovery commands unless the
user explicitly requests that operational action.

The checks in `checks/` are NixOS VM behavior tests and are part of
`nix flake check`; do not treat a successful evaluation alone as proof that a
service starts or that its generated configuration is valid.

## Secrets And Safety

- Never print, decrypt, expose, or commit plaintext secrets, age private keys,
  tokens, or credentials.
- Treat `secrets/secrets.yaml` and SOPS configuration as sensitive. Use `sops`
  for intentional secret edits and avoid including secret values in command
  output or summaries.
- Do not weaken SSH, firewall, SOPS, service confinement, deployment gates, or
  branch protections to make a check pass.
- Do not force-push, delete, or manually move `deploy`. Recovery requires
  deliberate operator confirmation and follows the documented procedure in
  `.github/workflows/README.md`.
- Do not run destructive commands, remote activation, or production-affecting
  operations without explicit confirmation.

## Change-Specific Guidance

- New NixOS service modules belong under `modules/services/` and are imported
  automatically. Follow the `cg.service.<name>.enable` pattern.
- Host-specific choices belong under `hosts/<host>/`; shared behavior belongs
  in the appropriate `modules/` subtree.
- Changes to a package updater should be made in that package. The workflow
  discovers packages through `passthru.autoUpdate`.
- Adding a host requires adding it to the build matrix in
  `.github/workflows/ci.yml`; otherwise the gate does not protect it.
- Changes to deployment semantics should include documentation or an ADR when
  they introduce or alter a durable architectural decision.

## Response Expectations

For each completed task, summarize:

- What changed and why.
- Files changed, especially any security- or deployment-sensitive files.
- Checks run and their results.
- Assumptions, residual risks, or skipped verification.
