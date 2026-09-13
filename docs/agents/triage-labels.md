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

Issues and pull requests from before 2026-09-13 may also carry `agent-working`,
`agent-stuck`, `agent-ready-for-review` or `agent-revising`. Those were written
by the bash prototype runner, which has been deleted; its history is in git and
in ADR 0004, 0006 and 0007. The successor's label vocabulary is not settled
here - see the `afk-agent` repository's `docs/agents/triage-labels.md`.

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
