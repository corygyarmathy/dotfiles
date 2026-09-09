# ADR 0005: Only a deploy key may move `deploy`

- **Status:** Accepted
- **Date:** 2026-09-09
- **Related Artefacts:**
  - Narrows: [ADR 0001](0001-gitops-deployment-with-a-promoted-ref.md), which makes `deploy` the fleet's only contract - this decides who may move it
  - Answers: #190
  - Constrains: `.github/workflows/ci.yml` (the `promote` job), `docs/agents/afk-eligibility.md` (rule 1's reasoning), `docs/plans/afk-agent-pipeline.md` (item 3)

## Context

`deploy` is the only ref the fleet follows and hosts pick it up on their nightly `system.autoUpgrade`, so a push there reaches all three machines without passing the review gate that protects `master`. The `protect-deploy` ruleset restricted deletion and non-fast-forward pushes but not *who* may push, so any credential with write access to this repository could fast-forward it: `FLAKE_UPDATE_TOKEN`, `AFK_AGENT_TOKEN` (#168), and the operator's own credential. Scoping the token could not fix this - a fine-grained PAT's `Contents: write` is repo-wide rather than per-branch - and `docs/plans/afk-agent-pipeline.md` item 4 is about to hand one of those credentials to an unattended coding agent.

Nothing exploited it and it was not new. It is worth closing now rather than later because the failure it permits is the one the monitoring cannot see: `NixosDeployStale` and its neighbours describe deployments that fail, and a fleet moving overnight to a revision nobody reviewed is a deployment that *succeeds*.

The obvious design does not work here, and that was verified rather than assumed - this repository has been bitten once already by an organization-only ruleset feature (`422 invalid rule 'merge_queue'`, see `.github/workflows/README.md`). Adding an `update` rule and exempting the identity `promote` pushes with, `GITHUB_TOKEN` i.e. `github-actions[bot]`, is refused on a user-owned repository:

```
POST /repos/corygyarmathy/dotfiles/rulesets
  bypass_actors: [{ actor_type: "Integration", actor_id: 15368 }]
→ 422 "Actor GitHub Actions integration must be part of the ruleset source
       or owner organization"
```

Three further probes, each a throwaway ruleset on a ref that does not exist, separated the cause: the `update` rule type itself is available here (accepted with an empty bypass list), and both `DeployKey` and `RepositoryRole` are accepted as bypass actors. So the limitation is specific to the GitHub Actions app, and exactly one usable exception identity remains.

## Decision

**1. `deploy` restricts updates, and the only actor exempt is a deploy key.** A `restrict-deploy-updates` ruleset carries a single `update` rule over `refs/heads/deploy`, with `ci-promote-deploy` - a write-enabled deploy key, and the only deploy key this repository has - as its one bypass actor. Every PAT is now refused, including the operator's, because a fine-grained PAT acts as the repository owner and the owner is not on that list.

**2. It is a second ruleset rather than a rule added to `protect-deploy`.** `bypass_actors` is a property of the ruleset, not of an individual rule, so adding `update` to `protect-deploy` would have handed the deploy key a bypass on that ruleset's `deletion` and `non_fast_forward` rules too. Those keep an empty bypass list, and the invariant that nothing at all - not an admin, not `GITHUB_TOKEN`, not this key - can force-push or delete `deploy` survives intact. Two rulesets over one ref is the price of scoping a bypass to one rule.

**3. `promote` pushes over SSH with that key, and the job no longer takes `contents: write`.** The private key is the `PROMOTE_DEPLOY_KEY` Actions secret, written to a temporary file for the length of one push. Dropping `contents: write` is a consequence worth having: `ci.yml` now declares `contents: read` with no job opting out, so the workflow's `GITHUB_TOKEN` cannot write to this repository at all.

**4. This narrows the exposure; it does not close it, and the path denylist stays load-bearing.** A workflow run can still reach `deploy`, because the key it needs is a repository secret and a `pull_request` event runs the workflow file from the PR's head branch. That is the long way round `docs/agents/afk-eligibility.md` already denies, and it is why `.github/workflows/` remains on the denylist. What changes is the short way: reaching `deploy` now requires getting a workflow edit onto a branch, rather than one `git push`.

## Consequences

**Positive**

- The realistic failure this was raised for - an unattended agent, or a tired operator, moving `deploy` with a single mistaken command - is now refused by the server rather than by everyone remembering not to.
- `AFK_AGENT_TOKEN` can no longer reach the fleet at all without going through `.github/workflows/`, which is denied three times over and now also gated on the diff before the push (item 7).
- `ci.yml`'s `GITHUB_TOKEN` is read-only everywhere, so the one job that had a reason to write no longer needs the exception that made it possible to grant elsewhere by copy-paste.
- The bypass is auditable in one line: `gh api repos/{owner}/{repo}/keys` should list exactly one key, and it should be `ci-promote-deploy`.

**Negative**

- A new standing credential, in the secret store that the one remaining path to `deploy` can already read. It buys nothing against that path; it is only paying for the short one.
- `promote` - the single step whose silent failure stops fleet upgrades - grew an SSH setup and a secret it can be missing. The empty-secret case fails loudly and says which secret, because the alternative is an SSH authentication error against a ref nobody may push to, which is two layers away from the cause.
- The `DeployKey` bypass is all-or-nothing: it names the actor *type*, not one key. A second write deploy key added later silently joins the bypass list. There are none today and the audit above is the control.
- Recovery from a diverged `deploy` (`.github/workflows/README.md`) now means relaxing two rulesets rather than one.
- Rotating the key is two coordinated steps - the repository's deploy key and the Actions secret - and getting one without the other means a red `promote` that night.

## Alternatives considered

- **`github-actions[bot]` as the bypass actor**, which is what #190 proposed and what the rest of the pipeline would have made natural. Not available: `422`, above. This is the same organization-only shape as merge queues, and the second time this repository has designed around it.
- **The repository admin role as the bypass actor.** Accepted by the API, and useless: ADR 0004 §4 rules out a second GitHub account, so `AFK_AGENT_TOKEN` acts as `corygyarmathy`, who is the repository admin. The exemption would cover the exact credential the rule exists to stop.
- **A dedicated GitHub App**, installed on the repository, with `promote` minting an installation token. Works in principle and is the mechanism GitHub actually intends here. Rejected as strictly more machinery than a deploy key - an app to create and own, a private key with the same secret-store exposure, and a token-minting step in `promote` - for an identical residual risk.
- **Accept the exposure and write down why.** Defensible while every write credential is one the operator issued, and it was the pre-committed fallback had no bypass identity existed. Rejected because one does: the cost of being wrong is the fleet moving overnight to an unreviewed revision, and the price of not being wrong turned out to be one key and one ruleset.

## Verification

The API refusal above is settled, and so is the negative half: `GET /rulesets/22613803` reports `current_user_can_bypass: never` for `corygyarmathy`, and `GET /rules/branches/deploy` lists the `update` rule as applying. ADR 0004 §4 rules out a second account, so every fine-grained PAT in this repository acts as that user - which is what makes one API field cover `AFK_AGENT_TOKEN`, `FLAKE_UPDATE_TOKEN` and the operator's own credential at once. It is also the reason a live negative test was not run: the only push that would have demonstrated the refusal is a push that must not succeed, and there is no way to rewind `deploy` if it did.

**Narrowed 2026-09-09 by [ADR 0006](0006-the-runner-is-a-github-app.md), which gives the runner an identity of its own.** The sentence above buys its reach from the single account: one API field could speak for every credential here only because every credential here was the same user. The runner is now a GitHub App, so `current_user_can_bypass` answered for `corygyarmathy` says nothing about its credential - and the App holds no repository role at all, which makes the argument from roles inapplicable to it rather than merely separate from it. The decision is unaffected and the conclusion is if anything firmer: this ruleset exempts a deploy key and nothing else, and an App installation is not one. It is now two facts rather than one, and the second has been checked - `GET /rules/branches/deploy`, under the installation token, still lists `update`.

The positive half is that a real merge to `master` still fast-forwards `deploy`, since a `promote` that fails is a silent stop to fleet upgrades. Proven in three parts:

- **The key can push.** `ci-promote-deploy` authenticates as `corygyarmathy/dotfiles` rather than as the user, and pushed and deleted a scratch ref on `github.com` by hand, 2026-09-09.
- **The `promote` step's own shape works on a runner.** The merge of #199 fast-forwarded `deploy` over SSH with the key (`7b317e7..ef1a4b4`, run 34315746687). That merge deliberately landed *before* the ruleset was created: creating it first would have left any merge already in flight running the old `GITHUB_TOKEN` promote straight into the new rule.
- **The join** - `promote`, on a runner, past an active `update` rule - was the next merge after that, #198 (`ef1a4b4..2fdced5`, run 34318554853). The line worth knowing is in that job's log rather than in its exit status: `remote: Bypassed rule violations for refs/heads/deploy`. GitHub says there that the `update` rule fired and the key was the exemption, which is the whole claim - a green `promote` alone would look identical if the ruleset had silently failed to apply.

Should that promotion ever be the thing that breaks, the ruleset is one call to remove (`gh api repos/{owner}/{repo}/rulesets/22613803 --method DELETE`) and the fleet simply stops moving in the meantime rather than moving somewhere wrong.
