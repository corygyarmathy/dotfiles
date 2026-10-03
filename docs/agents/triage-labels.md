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
here - see the `afk-agent` repository's `docs/agents/triage-labels.md` - with
one exception: `ready-for-agent` is homelab01's
`cg.service.afk-agent.eligibilityLabel`, so applying it queues the issue for
unattended work, taken once it has no open blocker.

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the
corresponding label string from this table.

## Choosing between `ready-for-agent` and `ready-for-human`

Applying `ready-for-agent` starts unattended work, so being fully specified is
necessary but not enough. A ticket that fails any of these three gets
`ready-for-human`, however well written it is.

### 1. Its scope needs no denied path

The paths are homelab01's `cg.service.afk-agent.implement.denylist`
(`hosts/homelab01/default.nix`). The agent checks them only when it pushes,
after the work is done, so triage is where a denied ticket is caught cheaply.
Why `.github/workflows/` is denied when every diff is reviewed anyway is in
[`.github/workflows/README.md`](../../.github/workflows/README.md).

The list is literal paths. A module adding a `sops.secrets.<name>` declaration
changes what a host decrypts without touching `secrets/` or `.sops.yaml`, and
`.github/` outside `workflows/` is not denied.

### 2. It adds no flake check

A new check has to be added to the `checks` matrix in
`.github/workflows/ci.yml`, which is a denied path, so the push would be handed
back with the work done. Updating an existing check is fine.

### 3. The agent can tell whether it succeeded

Ask it of each acceptance criterion, not of the ticket as a whole:

| Shape            | What it is                                                                      | Eligible?                    |
| ---------------- | ------------------------------------------------------------------------------- | ---------------------------- |
| **Gate**         | Machine-decidable. The agent runs something and reads the result.               | Yes                          |
| **Confirmation** | A human looks _after_ the gates have passed. The work is complete without them. | Yes, if marked as not a gate |
| **Judgement**    | A human decision that shapes the work _while it is being done_.                 | No                           |

The line between the last two is when the human acts: if the agent would have
to stop and wait for a person, it is a judgement. A judgement is fatal rather
than awkward because an agent halted for a decision looks exactly like one that
broke.

A ticket that fails this usually has a checkable half and a visual half fused
into one criterion. Reshape it before relabelling: turn the checkable half into
a check that fails before the change and passes after, mark the human half in
the criterion itself as a confirmation, and use `ready-for-human` only if a
judgement is still left. Issue #180 is the worked example.
