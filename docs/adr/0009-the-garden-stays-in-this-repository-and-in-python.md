# ADR 0009: The garden stays in this repository, and in Python

- **Status:** Accepted
- **Date:** 2026-09-19
- **Related Artefacts:**
    - Contrasts with: [ADR 0004](0004-afk-agent-runs-self-hosted-with-a-harness-split.md) §1, which put the AFK executor in its own repository
    - Constrains: `modules/services/digital-garden/`
    - Implemented by: the test seam the Decision below makes a precondition

## Context

The digital garden is the largest single body of code this repository owns: two Python programs totalling 2,420 lines, 243 lines of renderer assembly, 1,104 lines of Hugo layouts, a 2,212-line stylesheet, and an 810-line NixOS module, tested by a 2,408-line VM check. It is also the only thing here whose failure has consequences outside this repository - it publishes to the internet, and the publish boundary is what stands between a private note and a public URL.

Two structural moves were proposed for it: extract it into its own repository and consume it as a flake input, exactly as `afk-agent` is consumed (ADR 0004 §1); and rewrite `publish-filter.py` and `bonsai.py` in Go, on the general argument that Python past a few hundred lines resists organisation and testing.

Both are plausible, and the first has a precedent in this repository that appears to endorse it. The forces that decided against them, for now, are not visible from the code.

## Decision

**1. The garden stays in this repository.** It is not extracted, and it is not consumed as a flake input.

The friction the garden actually exhibits is internal: the interface between the Python and the Hugo templates is untyped frontmatter declared nowhere, the renderer and the filter are read-only module options used as an export channel, and every assertion about any of it is made through a booted VM. A repository boundary relocates each of those without dissolving any of them. Applying the deletion test to the boundary itself: deleting it would not concentrate complexity, it would move it.

Against that, extraction has a measurable cost here that it does not have for `afk-agent`. Of the 76 commits that have touched the garden, 32 touch presentation only and 9 touch the Python only; the stylesheet and the layouts are where the work is. `afk-agent` tracks master through ordinary lock bumps, so a change lands in its own repository and then waits for a lock-bump pull request here, the gate, and promotion - two landing hops instead of one. Imposing that on the loop that churns most inverts the point of `nix run .#garden-preview`, which exists because that round trip was minutes long, and of the working-tree overrides it carries so the preview reads the file being edited.

This is a decision about _where the seams are drawn_, not a permanent refusal. It flips when the internal seams named in §3 exist: a codebase with a filter interface and a test suite that does not need a VM is a far cheaper thing to split, and the split would then be drawn along seams that have been shown to work rather than guessed at.

**2. The filter and the bonsai stay in Python.** Testability is not the reason to rewrite them, because the test suite that makes them safe is language-agnostic: a fixture vault in, a staging tree and rendered HTML out. That suite is worth building whatever language the filter is written in, and it does not become easier to build by changing the language first.

Nor is the disorganisation a property of Python. `publish-filter.py` is 1,083 lines of which roughly 120 are docstring and 400 are fifteen small pure functions that are fine; what is hard to read is one 434-line `main` holding five passes, of which the fifth is 276 lines doing three jobs. That shape follows a rewrite into any language unless it is fixed deliberately, so it is worth fixing on its own terms first.

**3. A rewrite is reopened only behind a characterisation suite, and in a stated order.** Two conditions, both of which exist to stop a rewrite being the thing that breaks the publish boundary:

- The golden test must exist and pass first, so that both implementations can be held to the same output for the same vault. A rewrite of a fail-closed security boundary with nothing to catch a regression is how a private note reaches a public URL.
- `bonsai.py` goes first if either does. It is pure computation with deterministic seeding, no I/O, and a single entry point - the easiest thing to port and the one whose failure is cosmetic. `publish-filter.py` is the publish boundary, and it goes last or not at all.

The strongest argument for Go, if it is revisited, is architectural rather than ergonomic: Hugo is itself Go, so a Go filter opens the possibility of collapsing the filter and the renderer into one program - vault in, site out - which is a materially deeper module than the two-program pipeline that exists now. That argument should be made on its own merits when the seams are in place, not as a side effect of disliking a long Python file.

## Consequences

**Positive**

- The loop that churns most - stylesheet, layouts, fixture - keeps its single landing hop, and `garden-preview` keeps reading the working tree.
- The work that a split or a rewrite would each require first is the same work, and it is worth doing on its own: a named pipeline interface, one fixture, and a test suite that does not boot a machine.
- A future architecture review has the reasoning rather than the conclusion, and can tell whether the conditions in §3 have been met.

**Negative**

- The gate keeps paying for the garden's tests. This is mitigated by moving most of them out of the VM rather than out of the repository, but the ceiling is lower than extraction would give.
- The garden gets no `CONTEXT.md` or ADRs of its own; its vocabulary lands in this repository's glossary instead, alongside a fleet's.
- Two Python programs stay in a repository that is otherwise Nix and shell, and the reader has to know that is deliberate.

## Alternatives considered

- **Extract now, and draw the seams in the new repository.** Rejected on sequencing rather than on principle. The seams would be guessed at during a move rather than established first, and the move is the point at which a mistake is most expensive to correct - a wrongly-placed boundary between two repositories is a great deal harder to redraw than one inside a directory. The genuine wins it offers - the gate's budget, a fast test loop, the garden's own domain docs - are all obtainable without it, and two of the three are obtainable in the same work that would make the extraction safe.
- **Rewrite `publish-filter.py` in Go first, and treat the rewrite as the cleanup.** Rejected because it changes the publish boundary with no oracle. The filter has no tests at all today; its stated rules - publish defaults to false, an unparseable note is skipped rather than published - are fail-closed claims that nothing verifies. A reimplementation would be judged by reading it, which is the weakest form of verification available for exactly the property whose failure is public and irreversible.
- **Leave it alone.** Rejected because the status quo has a standing cost that is already being paid: the only corpus exercising attachments and the landing-page case is the fixture no check runs, the publish marker is matched case-insensitively by the filter and case-sensitively by the guard that backs it, and the dotfile-exclusion rule exists in four spellings, one of which has already silently stopped the preview's watch loop.
