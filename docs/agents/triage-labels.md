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

One further label is written by the AFK runner rather than applied at triage,
and is here because it shares the tracker with the ones above:

| Label           | Meaning                                                     |
| --------------- | ----------------------------------------------------------- |
| `agent-working` | The AFK runner has claimed this ticket and is working it now |

The runner claims by swapping `ready-for-agent` for `agent-working` in a single
edit, rather than by assigning itself, because GitHub will not let a GitHub App
hold an issue assignment (ADR 0006). Dropping `ready-for-agent` is what stops
the ticket being claimed twice; `agent-working` is what makes that visible. An
`agent-working` ticket with no open pull request and no running unit is a run
that died - handing it back is the stuck path (#175).

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
