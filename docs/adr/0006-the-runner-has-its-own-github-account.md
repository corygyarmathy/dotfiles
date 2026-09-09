# ADR 0006: The runner has its own GitHub account, and merge stays a script's property

- **Status:** Accepted
- **Date:** 2026-09-09
- **Related Artefacts:**
  - Reverses: [ADR 0004](0004-afk-agent-runs-self-hosted-with-a-harness-split.md) §4's no-second-account clause. Every other decision in ADR 0004 stands, §9 included
  - Answers: #200, and unblocks #202
  - Shares its instrument with: [ADR 0005](0005-only-a-deploy-key-may-move-deploy.md), which restricts updates to `deploy` - this records why the same rule cannot be used on `master`
  - Constrains: `docs/plans/afk-agent-pipeline.md` (items 3, 12, 14, 15)

## Context

ADR 0004 §4 chose one GitHub account. The runner would open pull requests with a fine-grained PAT under `corygyarmathy`, distinguished by an `afk/*` branch prefix and an `afk-agent` label, because a second account's credentials and 2FA looked like the larger cost. That was decided before any of the pipeline existed, and three consequences have since surfaced that the decision blocks.

**Nothing the agent writes is distinguishable from something the operator wrote.** Both are `corygyarmathy`. Plan item 12 reads review comments back to the agent and filters to "comments from accounts other than the agent's own"; under one account that set is empty, so the filter it calls a safety property cannot exist. The only distinction that survives is positional - the pull request body is the agent's, comments are the human's - which is why item 15 cannot move the review's findings out of the body.

**The token's ceiling is the issuing account's role.** A fine-grained PAT cannot exceed the permissions of the account that issued it, and that account is this repository's admin. Nothing about the permission table narrows that ceiling; it only declines to use it.

**And ADR 0005 has just been written around the same clause.** Restricting who may move `deploy` had exactly one usable exception identity, and the repository admin role was not it: "ADR 0004 §4 rules out a second GitHub account, so `AFK_AGENT_TOKEN` acts as `corygyarmathy`, who is the repository admin. The exemption would cover the exact credential the rule exists to stop." One account had begun to cost design options in a second place.

## Decision

**1. The runner gets a dedicated machine account, added to this repository as a `write` collaborator.** `AFK_AGENT_TOKEN` is reissued under it with item 3's permission table unchanged and the same single-repository scope; the old token is revoked. Write rather than admin is the point of the exercise: the worst case a stolen or confused runner can reach is now bounded by a collaborator role rather than by the operator's own, and withdrawing it is removing a collaborator rather than auditing one's own tokens.

**2. ADR 0004 §9 stays a property of the runner's code. It is not enforced by a ruleset, and that is now a measured finding rather than a consequence of §4.** #200 expected the second account to make a ruleset carry §9, on the reasonable theory that what blocked it was the absence of a second identity. It was verified against the real API instead of assumed, and the theory is wrong for a reason that has nothing to do with how many accounts exist. See Verification.

**3. Attribution is the reason to keep the account, and it is sufficient on its own.** Item 12's author filter becomes implementable as written, item 15's findings can leave the body for a comment, and the permission ceiling drops. None of those depended on the ruleset question.

## Verification

All of it against `corygyarmathy/dotfiles` on 2026-09-09, on throwaway rulesets and scratch refs - the method ADR 0005 established. `master` and `deploy` were never targeted and neither moved.

**The instrument exists here.** An `update` rule targeting `refs/heads/master` is accepted; this is not another organization-only feature like the merge queue. Bypass actors of type `RepositoryRole` are accepted for the roles that carry write - and the role ids are not in permission order. Resolved by GraphQL (`bypassActors { repositoryRoleDatabaseId repositoryRoleName }`) rather than inferred, because the refusals alone suggest the wrong mapping:

| `actor_id` | role     | accepted as a bypass actor      |
| ---------- | -------- | ------------------------------- |
| 1          | read     | no - "does not have write permissions" |
| 2          | maintain | yes                             |
| 3          | triage   | no - "does not have write permissions" |
| 4          | write    | yes                             |
| 5          | admin    | yes                             |

**The rule does apply to merges, not only to pushes.** With an `update` rule over a scratch base branch and no bypass actors, the pull request went to `mergeable_state: blocked` and `gh pr merge` was refused: "the base branch policy prohibits the merge."

**But a bypass actor does not restore merging, for anyone.** With `RepositoryRole: 5` (admin) added - the operator's own role, with the API reporting `current_user_can_bypass: always` for them - the pull request was still `BLOCKED` and the plain merge still refused. The test was re-run from scratch with the bypass in place *before* the pull request existed, to rule out GitHub's cached mergeability, and the answer did not change. **This is the asymmetry to know about: a bypass actor is evaluated against the pusher at push time, which is why it works for `deploy` in ADR 0005, but a pull request's mergeability is computed for the branch rather than for a viewer, so an `update` rule blocks the merge button for every actor including one on the bypass list.**

**The only way through is the admin override**, `gh pr merge --admin` - GitHub's "bypass rules and merge". It succeeded where the plain merge did not. It is admin-only, so it would in fact distinguish the operator from a `write` collaborator, but it bypasses *every* rule on the ref, including `nixos ci` and the strict up-to-date policy.

**And auto-merge does not survive it.** On a scratch base carrying a required status check plus a separate `update` ruleset - the two-ruleset split ADR 0005 uses - auto-merge armed, the required check was marked successful, and the pull request stayed `BLOCKED` and unmerged for the full polling window. `flake-update.yml`, `dependabot-auto-merge.yml` and `automerge-nudge.yml` all drain through ordinary auto-merge.

So the price of server-enforcing §9 on `master` is: every human merge becomes an override that also skips the CI gate, and the nightly lock pipeline stops merging at all. That is a strictly worse repository than one where §9 is four lines of shell that never call `gh pr merge`.

**What is still open, and can only close once the account exists:** that a `write` collaborator is actually refused both the plain merge and the `--admin` override. Everything above was run as the admin, so the negative case is inferred from GitHub's permission model rather than observed. It is the one live check to run against the new identity, alongside re-proving that a pull request it opens still fires `nixos ci`.

## Consequences

**Positive**

- Item 12's author filter can be written as designed, and item 15 can move the review's findings into a comment - both were blocked on nothing but attribution.
- The blast radius of the runner's credential drops from "whatever the repository admin may do" to "whatever a write collaborator may do", and the ceiling is now a property of the account rather than a promise made by a permission table.
- A merge by the agent, if one ever happened, is attributable at a glance without relying on the `afk-agent` label being present.
- The ruleset question is answered with evidence and will not be reopened from first principles a third time. It has now been reasoned about twice - item 3 and #200 - from the wrong premise.

**Negative**

- A second set of credentials and 2FA to hold, which is exactly the cost ADR 0004 §4 named. It was not wrong about the cost; it was weighing it against benefits that had not appeared yet.
- ADR 0004 §9 remains reviewable rather than enforced. The runner does not call `gh pr merge`, the harness in `checks/afk-agent-runner.nix` asserts that directly, and that is the whole control.
- The machine account is a real GitHub account with a recovery path, an email address and a 2FA secret that all have to live somewhere. Losing it is a re-provisioning job, not a disaster, because the token is the only thing the pipeline consumes.
- ADR 0005's negative half was argued from §4 - `current_user_can_bypass: never` for the owner covered every fine-grained PAT at once, because every one of them acted as the owner. That sentence stops being true here. The conclusion survives unchanged, and for a better reason: `restrict-deploy-updates` exempts only a deploy key, and a `write` collaborator is not one either. But it is now two facts rather than one, and the machine account's token should be checked against `deploy` directly rather than inheriting the operator's answer.
- A second collaborator on the repository is a second thing to audit. `gh api repos/{owner}/{repo}/collaborators` should list exactly two, and the machine account's role should read `write` - the same one-line audit ADR 0005 gives for deploy keys.

## Alternatives considered

- **Keep one account, per ADR 0004 §4.** Rejected: it is now blocking two plan items outright and has twice been the reason a ruleset could not be written. The cost it was avoiding is real but one-off; the costs it is imposing recur.
- **An `update` rule on `master` with the operator as a bypass actor**, which is what #200 proposed and what this ADR set out to adopt. Rejected on the evidence above: it blocks the merge for the bypass actor too, so the human path becomes an override that skips `nixos ci`, and auto-merge stops draining entirely.
- **`required_approving_review_count: 1`**, which is how plan item 3 originally framed the structural option. Rejected before testing, and #200 is right about why: the review stage advises rather than approves (ADR 0004 §6, item 6), so nothing would supply the approval, and the requirement would bind human and lock-update pull requests too - the same auto-merge deadlock by a different route.
- **Issue the machine account a token that cannot merge.** Not available: merging a pull request needs `Contents: write` and `Pull requests: write`, which are the same two permissions the runner needs to push a branch and open the pull request at all. There is no narrower grant that separates them.
- **A GitHub App instead of a machine account.** The mechanism GitHub actually intends for a bot identity, and it would give a distinct author for item 12's filter. Rejected for the same reason ADR 0005 rejected it for `deploy`: an app to create and own, a private key with the same secret-store exposure, and a token-minting step in the runner, for an identity a free account provides directly. Worth revisiting only if a second bot ever needs one.
