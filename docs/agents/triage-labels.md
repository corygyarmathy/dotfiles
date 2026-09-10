# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those
roles to the actual label strings used in this repo's issue tracker.

| Canonical role    | Label in our tracker | Meaning                                  |
| ----------------- | -------------------- | ---------------------------------------- |
| `needs-triage`    | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`      | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent` | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human` | `ready-for-human`    | Requires human implementation            |
| `wontfix`         | `wontfix`            | Will not be actioned                     |

Three further labels are written by the AFK runner rather than applied at
triage, and are here because they share the tracker with the ones above:

| Label                    | Applied to       | Meaning                                                        |
| ------------------------ | ---------------- | -------------------------------------------------------------- |
| `agent-working`          | the issue        | The AFK runner has claimed this ticket and is working it now   |
| `agent-stuck`            | the issue        | The AFK runner stopped without finishing; its comments say why |
| `agent-ready-for-review` | the pull request | CI is green on this branch and the agent's review has run      |
| `agent-revising`         | the pull request | The AFK runner claimed this pull request for a revision round  |

`agent-working` and `agent-stuck` sit on the issue on the ticket lane, and
`agent-stuck` and `agent-revising` sit on the pull request on the revision lane
(#196): only a revision run ever puts `agent-revising` on a pull request, which
is what makes a dead revision run recognisable from outside.

The runner claims by swapping `ready-for-agent` for `agent-working` in a single
edit, rather than by assigning itself, because GitHub will not let a GitHub App
hold an issue assignment (ADR 0006). Dropping `ready-for-agent` is what stops
the ticket being claimed twice; `agent-working` is what makes that visible.

The stuck path (#175, the runner's `hand_back` in `modules/services/afk-agent.nix`) hands a ticket
the runner cannot finish back in the same one-edit shape: `agent-working`
becomes `agent-stuck`, next to a comment saying what was tried and why it
stopped. Before the push, nothing else the run built survives - no pull
request, no worktree, no branch. Past the push there is a pull request to
reach: it is commented on too and left open without the hand-off label below,
because it holds real work (ADR 0007 §2). `agent-stuck` is deliberately not
`ready-for-agent` again: re-applying the claim marker would send a ticket the
runner cannot finish straight round the frontier query, to burn its retry
budget on the same failure every poll. A human decides what happens next -
reshape the ticket and re-apply `ready-for-agent`, or take it by hand. An
`agent-working` ticket with no open pull request and no running unit is a run
that died - the runner's next poll hands it back through the same path.

`agent-ready-for-review` is the runner's hand-off, and it goes on the pull
request rather than on the issue. It arrives last, in the same `gh pr edit` that
writes the review's findings into the body, so a pull request carrying the label
carries the findings too (ADR 0007). Deliberately **not** `ready-for-human`: that
is an issue triage role meaning "requires human implementation", and on an
agent's own pull request it would read as "an agent could not do this" - the
opposite of what happened. It joins `agent-working` and `agent-stuck` in the
`agent-*` lifecycle family, which `agent-revising` extends: while a revision
round runs, the claim is the only label the pull request carries, and the
hand-off label goes back on once CI is green.

The revision trigger itself (#196, as re-triggered by #247) is not a label but
a `/revise` comment, written by an account other than the agent's on one of the
runner's own pull requests: the runner reads that request - or, when the
comment carries no text, the review comments written since its last word on
the pull request - back into a revision session that pushes to the same
branch, three rounds per pull request before the stuck path. A review comment
without `/revise` starts nothing, and a half-written review is exactly that.

**It is a signal, not a control.** It says CI is green and a review has run; it
does not say "you may merge", and nothing stops a merge before it is applied.
That is deliberate: ADR 0004 §9 makes merging a human act, and a mechanism that
could withhold a merge would be the runner holding a veto over the person rather
than the other way round. A pull request from the runner without this label is
one where CI never went green, the review could not be shown to have run, or the
run died in between - all of which look the same from outside and all of which
mean the same thing to a reader: nobody has finished with this yet.

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the
corresponding label string from this table.

## Choosing between `ready-for-agent` and `ready-for-human`

Being fully specified is necessary but not sufficient for `ready-for-agent`.
Two further rules decide whether a ticket may be worked unattended at all - a
path denylist, and a test of whether the agent can tell for itself that it
succeeded. A ticket failing either gets `ready-for-human` however well written
it is.

Both are in [afk-eligibility.md](afk-eligibility.md), along with what to do with
a ticket that fails the second one, which is usually to reshape it rather than
to relabel it.
