# ADR 0006: The runner is a GitHub App, and merge stays a script's property

- **Status:** Accepted
- **Date:** 2026-09-09
- **Related Artefacts:**
  - Amends: [ADR 0004](0004-afk-agent-runs-self-hosted-with-a-harness-split.md) §4, on the credential only - its no-second-account clause is upheld here rather than reversed - and §3, which loses the assignee as its claim marker
  - Answers: #200, and unblocks #202
  - Shares its instrument with: [ADR 0005](0005-only-a-deploy-key-may-move-deploy.md), which restricts updates to `deploy` - this records why the same rule cannot be used on `master`
  - Constrains: `docs/plans/afk-agent-pipeline.md` (items 3, 12, 14, 15), `docs/agents/issue-tracker.md` (the claim convention)

## Context

ADR 0004 §4 chose one GitHub identity. The runner would open pull requests with a fine-grained PAT under `corygyarmathy`, distinguished by an `afk/*` branch prefix and an `afk-agent` label, because a second account's credentials and 2FA looked like the larger cost. That was decided before any of the pipeline existed, and three consequences have since surfaced that a single identity blocks.

**Nothing the agent writes is distinguishable from something the operator wrote.** Both are `corygyarmathy`. Plan item 12 reads review comments back to the agent and filters to "comments from accounts other than the agent's own"; under one identity that set is empty, so the filter it calls a safety property cannot exist. The only distinction that survives is positional - the pull request body is the agent's, comments are the human's - which is why item 15 cannot move the review's findings out of the body.

**The token's ceiling is the issuing account's role.** A fine-grained PAT cannot exceed the permissions of the account that issued it, and that account is this repository's admin. Nothing about the permission table narrows that ceiling; it only declines to use it.

**And ADR 0005 has just been written around the same clause.** Restricting who may move `deploy` had exactly one usable exception identity, and the repository admin role was not it: "ADR 0004 §4 rules out a second GitHub account, so `AFK_AGENT_TOKEN` acts as `corygyarmathy`, who is the repository admin. The exemption would cover the exact credential the rule exists to stop." One identity had begun to cost design options in a second place.

#200 proposed to fix this with a machine account, and to spend the new identity on a ruleset that would server-enforce ADR 0004 §9. Both halves were tested rather than assumed. The ruleset premise is wrong, for a reason unrelated to how many identities exist. And the account turned out not to be the cheapest way to get an identity at all.

## Decision

**1. The runner's identity is a GitHub App installed on this repository, authenticating with short-lived installation tokens.** ADR 0004 §4 declined a second account because of what a second account drags in - an email address, a 2FA secret, recovery codes - and an App has none of the three. So §4's no-second-account clause is not reversed here; it is satisfied. What §4 is amended on is narrower: the credential is an installation token rather than a fine-grained PAT. Its stated reason survives that change intact, because the thing §4 was avoiding is specific to `GITHUB_TOKEN` and not general to installation tokens - verified below, since this repository's entire reason for holding a token of its own rests on it.

**2. The claim marker moves from an assignee to the `ready-for-agent` label**, amending ADR 0004 §3. GitHub will not let an App hold an issue assignment, so §3's `gh issue edit <n> --add-assignee @me` is unavailable to this identity. The replacement is already in place: the runner's frontier query is scoped by `ready-for-agent`, so removing that label _is_ the claim, and item 8's stuck path re-adds it. This leaves the assignee convention in `docs/agents/issue-tracker.md` untouched for humans reading the same tracker, which matters more than it looks - a shared tracker with two claim mechanisms would be worse than either.

**3. ADR 0004 §9 stays a property of the runner's code. It is not enforced by a ruleset, and that is now a measured finding rather than a consequence of §4.** #200 expected a second identity to make a ruleset carry §9, on the reasonable theory that what blocked it was the absence of a second identity. The theory is wrong for a reason that has nothing to do with how many identities exist. See Verification.

**4. Attribution is the reason to keep the identity, and it is sufficient on its own.** Item 12's author filter becomes implementable as written, item 15's findings can leave the body for a comment, and the permission ceiling drops. None of those depended on the ruleset question.

## Verification

All of it against `corygyarmathy/dotfiles` on 2026-09-09, on throwaway rulesets, scratch refs and a throwaway issue and pull request - the method ADR 0005 established. `master` and `deploy` were never targeted and neither moved.

### The identity

**An App can do everything the pipeline needs except one thing.** `corygyarmathy-afk-agent` was created and installed on this repository, and an installation token minted from its private key pushed a branch and opened pull request #214 as `corygyarmathy-afk-agent[bot]` (`type: Bot`).

**A pull request opened by an installation token does fire `nixos ci`.** This is the load-bearing one, because ADR 0004 §4 exists precisely because `GITHUB_TOKEN` suppresses workflow events - and `GITHUB_TOKEN` is itself an installation token, of the `github-actions` App. The suppression had to be shown to be specific to the default token rather than general to the mechanism. On #214, `NixOS CI` started on `event: pull_request` with `triggering_actor: corygyarmathy-afk-agent[bot]`, and thirty check runs queued. The run was cancelled and the branch deleted once the answer was visible.

**But an App cannot be an issue assignee**, which is what costs ADR 0004 §3 its claim marker. This mattered enough to check four ways, because GitHub's REST documentation says an invalid assignee is _silently ignored_, and a claim guard that fails silently is worse than no guard - the symptom would be two runners on one ticket rather than an error.

| Probe                                                        | Result |
| ------------------------------------------------------------ | ------ |
| `GET /repos/{repo}/assignees/corygyarmathy-afk-agent[bot]`    | `404` |
| `suggestedActors(capabilities: [CAN_BE_ASSIGNED])`            | only `corygyarmathy` |
| REST `POST /issues/{n}/assignees` naming the bot              | `403 Forbidden` |
| GraphQL `addAssigneesToAssignable` naming the bot             | `FORBIDDEN` - "Could not assign agent: `corygyarmathy-afk-agent[bot]` cannot be assigned to issues or pull requests" |
| _control:_ the same call naming `corygyarmathy`               | assigned |
| _control:_ the same call naming a login that does not exist   | `200`, assignee silently dropped |

The two controls are the point of the table. The silent-ignore behaviour is real and reproducible, so the failure mode does exist - but an App does not hit it. It is refused down a separate path, loudly, by both APIs. GitHub's own assignable-agent feature is an allowlist a custom App does not inherit.

**A custom App is accepted as a ruleset bypass actor, and the bypass works.** ADR 0005 recorded a `422` when it tried to exempt `github-actions[bot]` as an `Integration`, and concluded the limitation was specific to the GitHub Actions app rather than to the actor type. That reading is now verified: this App was accepted as an `Integration` bypass actor on a throwaway `update` ruleset, and a controlled pair showed the bypass working at push time - the same commit to the same ref was rejected for `corygyarmathy` and accepted for the App. It changes nothing here, since this ADR wants the runner restricted rather than exempted, but it is the instrument ADR 0005 could not get.

**The App holds no repository role.** `GET /repos/{owner}/{repo}` under the installation token reports `admin`, `maintain`, `push`, `triage` and `pull` all false; its rights come from installation permissions instead. Two things follow. `gh api user` returns `403 Resource not accessible by integration`, so the runner cannot read its own login from the token - item 12's filter takes the App slug as a parameter instead. And ADR 0005's check passes for this identity directly: `GET /rules/branches/deploy` under the installation token still lists `update`, so the `deploy` restriction is not something the runner's credential is exempt from.

### The ruleset that #200 proposed

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

**The only way through is the admin override**, `gh pr merge --admin` - GitHub's "bypass rules and merge". It succeeded where the plain merge did not. It is admin-only, so it would in fact distinguish the operator from the runner, but it bypasses *every* rule on the ref, including `nixos ci` and the strict up-to-date policy.

**And auto-merge does not survive it.** On a scratch base carrying a required status check plus a separate `update` ruleset - the two-ruleset split ADR 0005 uses - auto-merge armed, the required check was marked successful, and the pull request stayed `BLOCKED` and unmerged for the full polling window. `flake-update.yml`, `dependabot-auto-merge.yml` and `automerge-nudge.yml` all drain through ordinary auto-merge.

So the price of server-enforcing §9 on `master` is: every human merge becomes an override that also skips the CI gate, and the nightly lock pipeline stops merging at all. That is a strictly worse repository than one where §9 is four lines of shell that never call `gh pr merge`.

**What is still open:** that the runner's own credential is refused the merge. The App is granted `Contents: write` and `Pull requests: write` because pushing a branch and opening a pull request need exactly those, and those are also what merging needs - so §9 is not, and was never going to be, enforced by the token's permissions. The `--admin` override is separately out of reach, since the installation reports no repository role at all, but that is inference from the permissions above rather than an observed refusal. §9 remains what Decision 3 says it is: a property of the runner's code, asserted by item 5's harness.

## Consequences

**Positive**

- Item 12's author filter can be written as designed, and item 15 can move the review's findings into a comment - both were blocked on nothing but attribution.
- ADR 0004 §4's objection is met rather than overruled. There is no second inbox to keep, no second 2FA secret, and no recovery codes to store.
- The credential in `secrets/homelab01.yaml` stops being a bearer token. What is stored is a private key; what is used is a token that expires in an hour and is minted on demand. A leaked installation token is a one-hour problem, and there is no annual PAT rotation to remember.
- The permission ceiling is intrinsic. A fine-grained PAT inherits the issuing account's role and merely declines to use it; an App's installation permissions _are_ the ceiling, and changing them is a deliberate act with an audit trail.
- The ruleset question is answered with evidence and will not be reopened from first principles a third time. It has now been reasoned about twice - item 3 and #200 - from the wrong premise.

**Negative**

- An installation token lives one hour, and `attemptTimeout` is already 3600 with `maxRuntime` covering three attempts plus their gates. The token expires mid-run as the normal case rather than the exceptional one, so reading the credential stops being a file read and becomes a mint-and-cache with an expiry check - the first genuinely new code this decision costs.
- The claim marker changes, so `docs/agents/issue-tracker.md` gains an agent-specific clause and ADR 0004 §3 no longer describes what the runner does. A label is a weaker signal than an avatar in the issue list, and a crashed runner strands a ticket by leaving the label off rather than by leaving an assignee on - the same failure, differently shaped.
- A private key is a worse thing to lose than a PAT in one respect: it does not expire on its own. It is revocable from the App's settings page and re-issuable without touching the repository, which is why this is a re-provisioning job rather than a disaster, but nothing forces the question the way a PAT's expiry date does.
- ADR 0005's negative half was argued from §4 - `current_user_can_bypass: never` for the owner covered every fine-grained PAT at once, because every one of them acted as the owner. That sentence stops being true here. The conclusion survives, and is now verified for this identity directly rather than inherited.
- The App is a second thing to audit, and a less visible one than a collaborator: it appears under the repository's installed GitHub Apps rather than in the collaborator list.

## Alternatives considered

- **A dedicated machine account added as a `write` collaborator**, which is what #200 proposed and what the first draft of this ADR adopted. Rejected once the App was shown to work: it overrides ADR 0004 §4's objection where the App satisfies it, and it buys an assignable identity for the price of an email address, a 2FA secret, recovery codes, and a token that expires within a year and must be rotated by hand. The one thing it does better is hold §3's claim unchanged, and that is worth less than the four costs it brings.
- **Keep one identity, per ADR 0004 §4.** Rejected: it is now blocking two plan items outright and has twice been the reason a ruleset could not be written. The cost it was avoiding is real but one-off; the costs it is imposing recur.
- **An `update` rule on `master` with the operator as a bypass actor**, the second half of what #200 proposed. Rejected on the evidence above: it blocks the merge for the bypass actor too, so the human path becomes an override that skips `nixos ci`, and auto-merge stops draining entirely.
- **`required_approving_review_count: 1`**, which is how plan item 3 originally framed the structural option. Rejected before testing, and #200 is right about why: the review stage advises rather than approves (ADR 0004 §6, item 6), so nothing would supply the approval, and the requirement would bind human and lock-update pull requests too - the same auto-merge deadlock by a different route.
- **Issue the runner a credential that cannot merge.** Not available under either identity: merging a pull request needs `Contents: write` and `Pull requests: write`, which are the same two permissions the runner needs to push a branch and open the pull request at all. There is no narrower grant that separates them.
- **Keep the assignee claim by assigning the operator.** It would work as a mutex and would need no documentation changes at all, since the frontier query already skips anything with an assignee. Rejected because it puts the operator's name on work the operator is not doing, which is the precise thing #200 exists to stop.
