# AFK Eligibility

`ready-for-agent` means an unattended agent may claim this ticket and work it
with nobody watching. Two rules decide whether a ticket qualifies, and a ticket
that fails either gets `ready-for-human` instead, however well specified it is.

This file is the vocabulary those two rules are written in. For the label
strings themselves, see [triage-labels.md](triage-labels.md).

## Rule 1: the path denylist

No AFK-produced diff may touch:

- `.github/workflows/`
- `secrets/`
- `.sops.yaml`

A ticket whose described scope would require changing any of those is
`ready-for-human`. This is ADR 0004 §5. The paths themselves are triage
vocabulary rather than an architectural constant, so this list may change here
without a new ADR.

There is exactly one exception, for the `checks` matrix in `ci.yml`, spelled out
below. It is narrow and mechanically checkable; nothing else in
`.github/workflows/` is reachable under any circumstances.

### Why these three, when merge is reviewed anyway

`secrets/` and `.sops.yaml` are obvious enough. `.github/workflows/` is the one
that looks over-cautious, because a bad workflow diff is as reviewable as any
other diff. The catch is that review is not what stands between a workflow edit
and the fleet.

A `pull_request` event runs the workflow file **from the PR's head branch**, not
from `master`. So an edited `ci.yml` executes the moment the PR opens, before
anyone reads it. The AFK agent pushes to a branch in this repo rather than a
fork (ADR 0004 §4), which makes that a same-repo run, which means it gets the
repository secrets - `CACHIX_AUTH_TOKEN` and `FLAKE_UPDATE_TOKEN`, the latter a
PAT that can open and merge PRs. A job's `permissions:` are declared in the
workflow file itself, so the edited copy can grant itself `contents: write`;
`ci.yml`'s own `promote` job does exactly that today despite the repo's
read-only default.

And `deploy` is reachable from a workflow run rather than from a merge. The
`protect-deploy` ruleset forbids deletion and non-fast-forward pushes, but does
not restrict *who* may push, and any agent branch is `master` plus commits -
a fast-forward. `deploy` is the only ref the fleet follows (ADR 0001), and hosts
pick it up on their nightly `system.autoUpgrade`.

So the denylist here is not protecting `master`, which review does protect. It
is protecting `deploy`, which sits on the other side of the review gate
entirely: the PR could be read, rejected and closed, and the fleet would already
have moved. That is why this path stays denied even though every other kind of
mistake in an AFK diff is caught by reading it.

The denylist is a property of the work, not of any single check, and it binds at
three moments:

1. **At triage**, before `ready-for-agent` is applied.
2. **Before the runner claims a ticket**, re-read from the ticket itself rather
   than trusted from the label - ADR 0004 §5 asks for the check twice precisely
   so the label is not the gate.
3. **Mid-run**, if denylisted scope surfaces that the ticket never described.
   That is a stuck-path exit (`docs/plans/afk-agent-pipeline.md`, item 8):
   comment, relabel, no PR.

The list is **literal paths**. It does not stretch to cover things merely
adjacent to them, and two of those are worth naming so nobody assumes a cover
that isn't there:

- A module adding a `sops.secrets.<name>` declaration touches neither `secrets/`
  nor `.sops.yaml`, but does change what a host decrypts.
- `.github/` outside `workflows/` - `CODEOWNERS`, dependabot config, issue
  templates - is not denied.

`.agents/skills/` and `docs/agents/` are deliberately **not** denied, this file
included. The pipeline has to be able to work its own maintenance tickets, and
human merge (ADR 0004 §9) is the gate on what it writes there.

Worth knowing while relying on that: merge being a human act is currently the
runner's design and ADR 0004 §9, not something a ruleset enforces. `protect-main`
requires a pull request and the `nixos ci` check, but its
`required_approving_review_count` is `0`. Nothing structural stops a token with
the right scope merging its own PR - a question for the AFK identity
(`docs/plans/afk-agent-pipeline.md`, item 3) rather than for triage.

Item 3 has since answered it, and the answer is that no ruleset can carry §9
here: ADR 0004 §4 rules out a second GitHub account, so an AFK PR is authored by
the same person who would approve it, and GitHub does not let an author approve
their own pull request. Requiring one approval would deadlock every PR in the
repo. Human merge stays a property of the runner's code, so this file's reliance
on it is reliance on something reviewed rather than something enforced.

### The one exception: the checks matrix

`.github/workflows/ci.yml` runs one job per check from a hand-written matrix,
and lints that the matrix and `nix flake check` agree. So adding
`checks/foo.nix` also requires adding `foo` to that matrix - in an otherwise
denied file. Without an exception the agent's diff would be correct,
`nix flake check` would pass, and CI would fail on the lint step, meaning no AFK
ticket could ever add a check. `AGENTS.md` asks for one whenever observable
service behaviour changes, so that is a large share of the work worth handing to
an agent at all.

The matrix is hand-written on purpose - discovering the checks would cost a
serialised job ahead of every shard, against the wall-clock budget the sharding
exists to protect - so the collision is between two deliberate choices, and it
is the denylist that gives way, narrowly:

> `.github/workflows/ci.yml` may be changed **only** by adding entries to
> `jobs.checks.strategy.matrix.check`. No other file under
> `.github/workflows/` may change, nothing else in `ci.yml` may differ, no
> existing entry may be removed or altered, and each added entry must match
> `^[a-z][a-z0-9-]*$` and name a check that exists in
> `nix eval .#checks.x86_64-linux`.

Every clause is load-bearing:

- **Additions only.** Removing an entry silently stops a check from running -
  the exact "gate that quietly stops gating" failure the lint job exists to
  catch.
- **The character class.** `${{ matrix.check }}` is interpolated directly into
  a `run:` script, so the entry is shell context, not data. Nix attribute names
  can contain arbitrary characters when quoted, and the agent writes
  `checks/default.nix` too, so "it has to match a real check" is not on its own
  enough to make the string safe.
- **Nothing else differs.** Steps, `permissions:`, triggers and secrets stay
  untouchable, which is the whole of the section above.

What this buys is bounded: an added entry can cause an existing, sandboxed
derivation to be built, and nothing else. It cannot introduce a step, reference
a secret, or widen a permission.

Checkable from the diff, roughly:

```bash
# 1. nothing else under .github/workflows/ changed
git diff --name-only "$BASE"... -- .github/workflows/ \
  | grep -qv '^\.github/workflows/ci\.yml$' && exit 1

# 2. ci.yml is identical once the matrix list is normalised away
q='del(.jobs.checks.strategy.matrix.check)'
diff <(git show "$BASE:.github/workflows/ci.yml" | yq "$q") \
     <(yq "$q" .github/workflows/ci.yml) || exit 1

# 3. the new list is a superset of the old, and every added name is well-formed
```

Note the limit of step 2: `yq` drops comments on both sides, so a comment-only
edit to `ci.yml` would pass. That is accepted - comments do not execute.

### What stands behind it

Nothing at GitHub's end. A fine-grained PAT cannot push anything under
`.github/workflows/` without the Workflows permission, whatever the runner
believes, and `AFK_AGENT_TOKEN` carries that permission precisely so this
exception can be exercised (`docs/plans/afk-agent-pipeline.md`, item 3). Without
it the runner would produce a correct diff and fail at the push instead.

That leaves all three enforcement moments above as the agent checking itself, so
the diff check sketched here is the only control rather than an extra - and it
has to run **before the push**. The push becomes a PR, the PR runs the head
branch's workflow with the repository's secrets before anyone reads it, and
after that there is nothing left to gate. Item 7 owns implementing it as a
pre-push gate, and the runner is not switched on before it exists.

Item 5's runner does re-check the denylist before it claims (moment 2 above),
but that check reads the ticket's prose and this exception cannot be judged
from prose at all: whether a `ci.yml` diff is additions-only to the matrix is a
question about a diff that does not exist yet. The two are not substitutes, and
the prose check is the weaker one - it is also blunt in the other direction,
refusing any ticket that so much as names a denied path.

This exception is the one place the denylist is not purely path-shaped, and the
only one that *widens* it rather than narrowing it. Like rule 2 below, it is
recorded here as triage vocabulary rather than as an ADR 0004 §5 amendment; it
is the first thing to revisit if the denylist's shape is ever reopened.

## Rule 2: self-verifiability

**Can the agent tell whether it succeeded?**

An unattended agent may only take a ticket whose success it can determine for
itself. The rule is about the agent's own success signal, not about human
involvement generally: merge stays a human act either way (ADR 0004 §9), and a
criterion a human confirms at review time is fine. What disqualifies a ticket is
a human being the *only* signal that the work is done.

Ask the question of **each acceptance criterion**, not of the ticket as a whole.
Criteria come in three shapes:

| Shape            | What it is                                                                      | Eligible?                    |
| ---------------- | ------------------------------------------------------------------------------- | ---------------------------- |
| **Gate**         | Machine-decidable. The agent runs something and reads the result.               | Yes                          |
| **Confirmation** | A human looks *after* the gates have passed. The work is complete without them. | Yes, if marked as not a gate |
| **Judgement**    | A human decision that shapes the work *while it is being done*.                 | No                           |

A ticket is `ready-for-agent` when every criterion is a gate or an explicitly
marked confirmation, and none is a judgement.

The discriminator between the last two is **when the human acts**. A
confirmation happens after the agent has finished and cannot change what got
built; the agent can complete, commit and hand over without it. A judgement
happens in the middle and determines the outcome - "record whether 40px proved
too narrow, or move to 48px", "judge the alignment by rendering it". If the
agent would have to stop and wait for a person, it is a judgement.

That mid-flight stop is why a judgement is fatal rather than merely awkward. An
agent that halts for a human decision looks exactly like an agent that broke,
and the stuck path (item 8) has no way to tell the two apart - so the ticket
either draws a stuck report for work that was going fine, or draws a success
report the agent cannot justify.

This rule does not ban deciding things by looking, which is established practice
here and often the right way to settle a visual question. It says only that
looking cannot be the agent's success signal.

### When a ticket fails rule 2

A ticket that fails this test is usually not badly written. It usually has a
checkable half and a visual half fused into one criterion. Reshape before
relabelling:

1. **Turn the checkable half into a gate** - a build-time check or test that
   fails red before the change and passes after.
2. **Demote the human half to a confirmation**, marked as one in the criterion
   itself, recorded in the plan item's "Built" note.
3. **Relabel `ready-for-human`** only if a judgement is still left after that.

Issue #180 is the worked example: its rofi theme criteria became build-time
checks, and "confirmed by opening each of the seven surfaces" stayed on the
ticket as an explicit confirmation - "this is a confirmation, not a gate" - so
the agent's success signal is the checks alone.

### Where this rule's authority comes from

Rule 1 is ADR 0004 §5. Rule 2 is **not** in ADR 0004, which bounds AFK
eligibility by paths only. It is recorded here as triage vocabulary. If it turns
out to carry more weight than that, it earns its own ADR rather than an
amendment to 0004 (see `docs/agents/domain.md`).

### Where it is enforced

Unlike the denylist, rule 2 is applied **at triage only**. The runner does not
re-gate on it before claiming: the judgement is made on ticket prose, and a
false rejection there is indistinguishable from a real bail. If the runner
discovers mid-run that it cannot determine its own success, that is a stuck-path
exit (item 8), not a pre-claim rejection.
