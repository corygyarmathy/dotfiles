# Documentation: what lives where

Every fact in this repo's history has exactly one canonical home. Every other document that touches it links to that home - it does not restate the fact. When you're about to write something down, ask whether it's already someone else's job below before adding a paragraph.

## Issue - the spec, permanent

Problem statement and acceptance criteria. Doesn't move once implementation starts - a changed shape is a comment on the issue, not a rewrite somewhere else. Nothing else in this list restates a spec; they link the issue instead.

## ADR - a decision, one per file, append-only

See [`domain.md`](domain.md) for the full discipline: what counts as a decision versus a parameter, and why an accepted ADR is never amended in place - a changed decision gets a new ADR, and the old one is marked superseded rather than rewritten. A Proposed ADR may still be amended in place.

## Plan - the work, disposable

Tracks only what is currently in flight: which items are active, what each is blocked on. Not a spec (the issue's job) and not a changelog (the PR's and commit's job).

A shipped item's entry becomes one line - issue, PR or code path, nothing else - not an archived section. Its Problem/Approach/Testing content is deleted, not kept for reference.

Never cited by path or item number from anything that has to keep working after the plan changes shape - an ADR, a code comment, another doc pointing at "item 7" ties its own correctness to a document that is expected to empty out. Point at the issue or the code instead.

Delete the plan file once nothing in it is active. It has no standing as a historical record - that's the issue, the PR, and, if something was actually measured, a findings note.

## Findings note - measured evidence, historical

Exists only when something was actually run and produced numbers worth keeping: a pilot, an experiment, a load test. Not a spec, not a decision, not expected to change - dated evidence, cited by the ADR whose decision it justified. If nothing was measured, this document doesn't exist; don't create one to hold prose that isn't evidence.

## PR description - the bridge

Links the issue. Summarises what changed and why, for a reviewer. Becomes the permanent changelog entry once merged - this is what a plan item's history collapses into, not a preserved plan section.

## Commit message - atomic, for git-archaeology

What and why for this one commit. What you already write; no change here.

## README - orientation only

What this is, how to run it, a pointer into the ADRs for why it's shaped this way. No implementation detail: an algorithm explained in a README belongs in a code comment or an ADR instead.

## Code comment - non-obvious why only

Earns its place only if the code can't say it for itself: a workaround, a constraint from outside the file, a rejected alternative and why. A comment restating what the next few lines do is a no-op - delete it, don't shorten it.
