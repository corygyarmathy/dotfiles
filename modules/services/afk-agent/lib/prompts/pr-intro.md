Closes #ISSUE.

Opened unattended by the AFK agent (ADR 0004). The work on `BRANCH` was
claimed from `ready-for-agent`, implemented by `IMPLEMODEL` across ATTEMPTS
session(s), and pushed only once this repository's own gate passed on the
commit at the head of the branch: `nix fmt -- --ci`, a build of every check
the flake exposes, a build of every host, and agreement between the checks
the flake exposes and the matrix in `ci.yml`. The diff was checked against the path denylist in
`docs/agents/afk-eligibility.md` immediately before every push, as well as
before the claim.

**No person has read this diff.** Nothing in this pipeline merges and no
auto-merge is armed on this path: merging is a human act (ADR 0004 §9).

This pull request was opened _before_ its review ran, which is the order
ADR 0007 settled: CI on this branch is what decides correctness, and the
review is a quality pass whose findings are appended to this body once it
has run. **If there is no "Handed over" section below this one, the run has
not finished** - CI never went green, the review could not be shown to have
happened, or the runner died in between. The `HANDOFF` label says the same
thing from the outside, and is applied in the same edit that appends the
section.

## What the branch says it does

Quoted from its own commit messages, unedited.
