# Plan: a test seam for the digital garden

The garden's 2,420 lines of Python have no Python tests, and every assertion about them is made through a 2,408-line VM check that boots a machine, builds the site and greps the served HTML. Roughly 1,900 of those lines are a pure function of (fixture vault) -> (staging tree, rendered site). This plan moves them to where they can be tested as one, and makes the small structural changes that let it.

Scope is bounded by [ADR 0009](../adr/0009-the-garden-stays-in-this-repository-and-in-python.md): the garden stays here and stays in Python, and the suite below is the precondition on reopening either.

| #   | Item                                              | Size   | Depends on | Status      |
| --- | ------------------------------------------------- | ------ | ---------- | ----------- |
| 1   | One fixture, shared by the preview and the checks | small  | -          | not started |
| 2   | Lift the pipeline out of the host evaluation      | small  | -          | not started |
| 3   | One dotfile rule, one spelling                    | small  | -          | not started |
| 4   | Golden: staging tree and rendered HTML            | medium | 1, 2       | not started |
| 5   | Refusals and determinism, asserted explicitly     | small  | 1, 2       | not started |
| 6   | Shrink the VM check to what a VM is for           | medium | 4, 5       | not started |
| 7   | `filter_vault(...) -> Report`, and pass 5 split   | medium | 4, 5       | not started |
| 8   | Stage names and the hue ring, declared once       | small  | 4          | not started |
| 9   | One publish marker, matched the same way twice    | small  | 5          | not started |

Order matters in one place: the golden lands before the Python is touched, so that the cleanup in item 7 can be shown not to change what gets published. Item 6 lands after the golden has run green against at least one real change, not in the same pull request - deleting the old coverage in the commit that adds its replacement means the first evidence the replacement works is also the moment the old one is gone.

## 1. One fixture

There are two adversarial vaults with overlapping jobs and no knowledge of each other: `modules/services/digital-garden/lib/hugo/fixture/` (six files, every element the theme styles, plus the landing page and the only attachment anywhere) and roughly 290 inline lines in `checks/digital-garden.nix`. Neither covers both jobs, and the consequence is that attachments and the landing-page special case are exercised only by the corpus no check runs.

Merge into the preview fixture, so `garden-preview --fixture` renders exactly what the checks assert on. The private notes are safe to keep there: the preview applies the publish boundary exactly as the server does.

## 2. Lift the pipeline out of the host evaluation

`renderer` and `filter` are `readOnly`, `internal` options that exist so `flake.nix` can read them back out of an evaluated host. They become a function - the module, the preview and the checks each call it. `flake.nix` stops evaluating `homelab01` to find two packages.

## 3. One dotfile rule

"Ignore dotted paths in the vault" exists in four spellings across three files, and they have already diverged: the `'/\.'` form matched a checkout under `.claude/worktrees/` and the preview's watch loop silently stopped. Produce the rule once and hand each consumer the dialect it needs.

## 4. Golden

Staging tree and rendered HTML, blessed the way the palette is - `assertGenerated` plus an app that re-writes the copies. The stylesheet's fingerprinted href is normalised so a CSS edit does not churn it; the stylesheet itself stays on the screenshot loop, which is how visual change is judged here.

## 5. Refusals and determinism

What a golden cannot express: the URL-collision exit, the unparseable-note skip, the fail-closed guard refusing a staged note without the marker, and two consecutive runs producing byte-identical output - the property the skip gates rest on and which nothing currently checks.

## 6. Shrink the VM check

What stays: Caddy's 404 and `try_files`, the inotify-to-path-unit rebuild trigger, the builder starting under `ProtectSystem=strict`, the KaTeX and Pagefind responses. What gets added, because it needs a VM and has never been tested: both skip gates, `source = "git"` (the module's default, and what a fresh host gets), and a disabled node.

## 7. `filter_vault` and pass 5

Bounded deliberately. `main` becomes argv parsing and an exit code; the work moves behind an entry point that returns a result rather than printing and exiting. Pass 5 is 276 of `main`'s 434 lines and does three jobs - derive dates, write the flat tree, swap it in - which become three. Passes 1 to 4 are left alone; the golden pins them.

## 8. Stage names and the hue ring

The three maturity stage names appear in ten places and the ring size in three, one of which is a test asserting `range(8)`. Both are constants; Nix already generates `hugo.toml` and can feed the filter and the templates from one definition. The wider frontmatter contract waits - the golden will show which keys are dead (`word_count` and `maturity_score` are written and read by nobody) and those get deleted before anything is declared.

## 9. One publish marker

The filter matches the marker case-insensitively; the guard that backs it re-spells the same rule as an ERE without the flag. A note written `Publish: TRUE` is therefore staged and then refuses the entire build. Both become case-sensitive - `publish: true` is the documented spelling and what Obsidian's property editor writes, and an exact marker is what a publish boundary should use - and a check asserts the two agree.
