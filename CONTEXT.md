# Dotfiles

The fleet's configuration and the services it runs: two NixOS hosts, their modules, and the automation that maintains them. This glossary covers only terms whose meaning here is narrower than, or different from, their ordinary use.

## AFK agent

The unattended runner's vocabulary - job, transition, claim, lease, command, hand-off - is defined in the [`afk-agent`](https://github.com/corygyarmathy/afk-agent) repository's `CONTEXT.md`, not here. This repository is where the NixOS module that packages and configures the runner lives (#281), and it does not own the language.

## Digital garden

The published website and the pipeline that produces it (`modules/services/digital-garden/`). The terms below are narrower here than their ordinary use; see [ADR 0009](docs/adr/0009-the-garden-stays-in-this-repository-and-in-python.md) for why this pipeline lives in this repository rather than its own.

**Vault** - the Obsidian notes repository the garden reads. It is not this repository and not part of it: it arrives by clone or by sync, and nothing in it is authored here. "The vault" never means the rendered site.

**Staging tree** - the flat, filtered CommonMark tree the publish filter writes and the renderer reads. It is the interface between the two programs: everything the renderer knows about a note arrives as frontmatter in this tree, and nothing else crosses. Flat because published notes are flattened to one namespace so a URL is `/some-essay/` regardless of where the note sat in the vault.

**Publish boundary** - the rule that a note reaches the staging tree only if it carries the literal publish marker, and the code that enforces it. Fail-closed in both directions: an unmarked note is not copied, and a staged note found without the marker refuses the whole build rather than serving it. Enforced twice on purpose, in the filter and again before the render.

**Maturity** - a note's computed stage, one of three: seedling, sapling, evergreen. Derived from length, links and revision count rather than declared, though a hand-written value in the note wins. Not a synonym for age; a long-untouched stub stays a seedling.

**Topic** - the shelf a note belongs to, taken from the folder it came from in the vault. **Hue** is the colour that topic is drawn in, assigned as a slot on a fixed ring rather than chosen per topic, so the number of distinct colours is bounded and stable.

**Bonsai** - the ASCII tree on the home page, grown from the published set. Deterministic: the same set of notes must draw the same tree, because the builder skips a rebuild when the staging tree hashes the same.
