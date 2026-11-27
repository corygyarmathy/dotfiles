# Documentation: what lives where

Every fact in this repo's history has exactly one canonical home. Every other document that touches it links to that home - it does not restate the fact. When you're about to write something down, ask whether it's already someone else's job below before adding a paragraph.

## Issue - the spec, permanent

Problem statement and acceptance criteria. Doesn't move once implementation starts - a changed shape is a comment on the issue, not a rewrite somewhere else. Nothing else in this list restates a spec; they link the issue instead.

## ADR - a decision, one per file, append-only

See [`domain.md`](domain.md): what counts as a decision versus a parameter, and how an ADR changes.

## Plan - the intended work, written once

States what is going to be built, why, and in what order. Written once and not edited after: no status, no progress markers, no amendments, no dated decision logs. Progress lives in the issues and PRs the plan produces. If the plan turns out wrong, replace it with a new plan or delete it; don't patch it.

Never cited by path or section from anything that has to keep working - an ADR, a code comment, another doc. A plan is expected to be deleted, so point at the issue or the code instead.

Delete the plan file once its work has landed or been abandoned. It has no standing as a historical record - that's the issue, the PR, and, if something was actually measured, a findings note.

## Findings note - measured evidence, historical

Exists only when something was actually run and produced numbers worth keeping: a pilot, an experiment, a load test. Not a spec, not a decision, not expected to change - dated evidence, cited by the ADR whose decision it justified. If nothing was measured, this document doesn't exist; don't create one to hold prose that isn't evidence.

## Research note - sourced survey, dated

Lives in `docs/research/` next to findings notes. It surveys outside sources ahead of a design: what other projects do, what a tool supports. Each claim cites the primary source it came from, and the note records the date and the versions it read. It is not a decision; the ADR or plan that acts on it cites it and owns the conclusion. It goes stale and is not kept up to date: re-survey instead of editing it.

## PR description - the bridge

Links the issue. Summarises what changed and why, for a reviewer. Becomes the permanent changelog entry once merged - this is what a plan item's history collapses into, not a preserved plan section.

## Commit message - atomic, for git-archaeology

What and why for this one commit. What you already write; no change here.

## README - orientation only

What this is, how to run it, a pointer into the ADRs for why it's shaped this way. No implementation detail: an algorithm explained in a README belongs in a code comment or an ADR instead.

## Code comment - non-obvious why only

Earns its place only if the code can't say it for itself: a workaround, a constraint from outside the file, a rejected alternative and why. A comment restating what the next few lines do is a no-op - delete it, don't shorten it.
