# ADR 0008: one formatting pipeline, gated in CI

- **Status:** Proposed
- **Date:** 2026-09-10
- **Related Artefacts:**
    - Amends: [AGENTS.md](../../AGENTS.md) (Formatting section, which named nixfmt-tree as the whole of the record)
    - Answers: #219
    - Constrains: [treefmt.toml](../../treefmt.toml), [.markdownlint-cli2.yaml](../../.markdownlint-cli2.yaml), [.prettierrc.yaml](../../.prettierrc.yaml), `formatter` in [flake.nix](../../flake.nix)

## Context

Formatting was three pipelines that disagreed: the editor (conform.nvim over LazyVim defaults plus a local markdownlint wrapper), the harness (opencode's per-language commands over PATH binaries), and CI (`nix fmt -- --ci` over nixfmt-tree, Nix only). Markdown took the worst of it - prettier and markdownlint-cli2 reformat each other's output forever over list indentation, and no gate noticed because CI never looked at Markdown. AI-agent diffs arrived with formatting churn mixed into content changes, which is what #219 measured: the churn is incomprehensible precisely where review needs to be mechanical.

## Decision

There is one pipeline, `nix fmt`, defined by ./treefmt.toml and executed with binaries from the nixpkgs pinned in flake.lock:

- The formatter set mirrors conform.nvim + LazyVim, which is authoritative for what runs on each file type. Where the editor cannot follow - Hugo layouts (Go actions inside tags are SyntaxErrors to prettier's HTML parser), the skill format (no h1 by spec), the garden's rendering fixture (deliberately adversarial test input) - the pipeline excludes the files and the editor is configured to skip them too, so neither side "fixes" what the other will not check.
- Versions are a property of flake.lock, not of anyone's PATH. A contributor's newer formatter reformatting files CI then rejects is the failure this closes.
- Markdown converges by construction: prettier runs before markdownlint-cli2 (as in the editor), with a Markdown-only `tabWidth: 4` override so it agrees with MD007 instead of fighting it. Rules the repo's established formats structurally violate (template `<slot>` syntax, blind-ranking emphasis labels, untagged transcripts, skill frontmatter) are scoped in .markdownlint-cli2.yaml with the reason on each - ADRs are append-only and templates are load-bearing, so neither can be retrofitted.
- Harnesses delegate: opencode formats through `nix fmt -- <file>` rather than per-language commands, and the AFK runner's implement prompt tells the session to run `nix fmt` (write mode) before committing, so formatting lands in the ticket's commits and the `--ci` gate stays a pure check.

## Consequences

**Positive**

- `nix fmt -- --ci` green means every formatter agrees; a red gate names a file, not a style debate.
- Editor, harness and CI consume the same binaries and configs, so the class of diff that motivated this - formatting churn inside content changes - has nowhere left to come from.

**Negative**

- Prettier and markdownlint-cli2 versions now move with flake.lock bumps. An upstream prettier change that reflows Markdown lands as a tree-wide style commit, not as one file at a time.
- Hugo layouts and the garden fixture are outside every formatter. Their consistency is the garden VM check and human preview, not the gate.

## Alternatives considered

- **Per-language check steps in ci.yml with no unification.** Keeps three pipelines and the drift between them; rejects nothing the editor would not reintroduce on the next save.
- **Format-on-push with a style commit from CI.** Writes to the contributor's branch from a workflow run, which needs `contents: write` on the path the AFK denylist exists to keep read-only.
- **Pre-commit hooks.** Unenforceable on agent worktrees and unattended runs; a gate the author can skip is documentation, not a control.
