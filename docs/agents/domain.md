# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase. For the full map of which document owns which fact (issue, plan, PR, findings note, README, comment), see [`documentation.md`](documentation.md) - this file covers the ADR/plan boundary only.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/adr/`**: the ADRs that touch the area you're about to work in.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_

## Keep parameters out of ADRs

An ADR records a decision and the reasoning behind it, at a date. A plan records how that decision is currently implemented, and is expected to change. Mixing the two is what turns ADRs into documents nobody trusts.

The test: **would reversing this send you back to the Alternatives section, or just to a text editor?**

- Back to Alternatives → it's a decision. It belongs in the ADR. If you can't write an honest "Alternatives considered" entry with a genuine contender, it isn't one.
- Just a text editor → it's a parameter. Counts, retry budgets, branch prefixes, label names, path lists, timer windows, option paths, module names. These belong in the plan, even when they were settled in the same conversation as the decision.

Watch for items that fuse both in one sentence, which is the failure mode that actually bites: "implementation gets up to 2 retries, and review is always a separate pass in a fresh context" welds a number you will change to a decision you won't. State the decision, then name where the parameter lives.

## Never amend an _accepted_ ADR in place

A Proposed ADR has not been accepted and may be amended in place: an "Amended …" block records the change in the ADR's own words, keeping the decision and its revisions together until the ADR is accepted.

When an accepted decision genuinely changes, write a new ADR and set the old one's status to `Superseded by ADR NNNN`. Leave its body alone - a superseded ADR is still the correct record of what was decided and why, and rewriting it destroys the only thing it was for.

This is what prevents amend/supplement chains among accepted ADRs. There is at most one hop from any ADR to its successor, never a trail of revisions, because the current state was never the ADR's job.

Relocating content without changing a decision - moving a parameter out to the plan, fixing a broken link - is not superseding and needs no new ADR. Say so in the commit message.
