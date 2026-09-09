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

Two further labels are written by the AFK runner rather than applied at triage,
and are here because they share the tracker with the ones above:

| Label                    | Applied to     | Meaning                                                      |
| ------------------------ | -------------- | ------------------------------------------------------------ |
| `agent-working`          | the issue      | The AFK runner has claimed this ticket and is working it now  |
| `agent-ready-for-review` | the pull request | CI is green on this branch and the agent's review has run   |

The runner claims by swapping `ready-for-agent` for `agent-working` in a single
edit, rather than by assigning itself, because GitHub will not let a GitHub App
hold an issue assignment (ADR 0006). Dropping `ready-for-agent` is what stops
the ticket being claimed twice; `agent-working` is what makes that visible. An
`agent-working` ticket with no open pull request and no running unit is a run
that died - handing it back is the stuck path (#175).

`agent-ready-for-review` is the runner's hand-off, and it goes on the pull
request rather than on the issue. It arrives last, in the same `gh pr edit` that
writes the review's findings into the body, so a pull request carrying the label
carries the findings too (ADR 0007). Deliberately **not** `ready-for-human`: that
is an issue triage role meaning "requires human implementation", and on an
agent's own pull request it would read as "an agent could not do this" - the
opposite of what happened. It joins `agent-working` in an `agent-*` lifecycle
family that `agent-stuck` (#175) and `agent-revise` (#196) will extend.

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
