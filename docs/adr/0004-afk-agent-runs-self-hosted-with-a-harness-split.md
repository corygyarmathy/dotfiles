# ADR 0004: AFK agent runs self-hosted, with a harness split from planning

- **Status:** Accepted. §4's no-second-account clause is reversed by [ADR 0006](0006-the-runner-has-its-own-github-account.md); every other decision here, §9 included, stands.
- **Date:** 2026-09-07
- **Related Artefacts:**
  - Implemented by: `docs/plans/afk-agent-pipeline.md`, which also owns this design's parameters and findings - this ADR states decisions only; counts, prefixes, paths and option names live there
  - Depends on: `docs/agents/issue-tracker.md` (the `ready-for-agent` label and claim convention), `.github/workflows/README.md` (the `FLAKE_UPDATE_TOKEN` precedent this follows), `modules/services/cloudflare-tunnel.nix` (considered, not used)

## Context

The engineering skills already carry a ticket through idea → plan → spec → tickets, and `implement` already runs `/tdd` and a self-review, then commits. Nothing exists after that: no mechanism claims a `ready-for-agent` ticket unattended, pushes a branch, opens a PR, or tells anyone it happened. Building that mechanism raises questions with no obvious default answer: where it runs, which harness and model drive it, whose identity opens the PR, and how it's triggered.

Three platforms were live options: a GitHub Actions workflow (matches this repo's existing bot-authored automation exactly), a Claude cloud routine fired by a GitHub webhook (a first-party mechanism, unused here, with unverified repository permissions), and a service on `homelab01` (self-hosted, reusing infrastructure - the Cloudflare tunnel, the worktree-isolation pattern, the `gh` claim convention - already built and trusted for other things). Cost did not decide it: this repository is public, so GitHub Actions minutes are unlimited and free regardless of which platform wins.

Harness and model raised a separate, sharper question. Anthropic's own support docs describe headless Claude Code as within a Pro/Max plan's terms, but multiple secondary sources describe subscription usage scoped to first-party, interactive-shaped invocations, with automated/CI use pushed toward metered API billing instead - unconfirmed against Anthropic's primary terms text either way. Meanwhile OpenCode Go ($10/month, a portable OpenAI-compatible key, dollar-capped rather than device-bound) is confirmed to support headless/server automation with no such ambiguity, and gives access to DeepSeek V4 (Pro and Flash) at a fraction of the cost.

## Decision

Each decision below is stated without its implementation parameters - counts, prefixes, path lists, option names. Those live in `docs/plans/afk-agent-pipeline.md`, which is expected to change; this document is not. See `docs/agents/domain.md` for the convention and why it exists.

**1. The AFK executor runs on `homelab01`**, not GitHub Actions and not a Claude cloud routine. Chosen for control and customizability - a value in its own right, not a cost argument, since Actions minutes are free either way. `homelab01` over `homelab02` because it's the compute-role box; `homelab02` carries the storage/download pipeline (already the site of one prior incident) and shouldn't also carry an unproven agent runner.

**2. Harness is split by phase.** Claude Code, on the existing Pro subscription, stays for every *interactive* stage - grilling, planning, spec, ticket generation - where subscription terms are unambiguous. The unattended executor runs OpenCode against DeepSeek V4 via OpenCode Go. This sidesteps the Claude subscription ambiguity entirely rather than resolving it, and costs less. Which DeepSeek variant (or another model) wins is deliberately left open, to be settled by a measured pilot (plan item 1), not decided here.

**3. Trigger is a polling systemd timer**, not a GitHub webhook, even though the existing Cloudflare tunnel would make a webhook receiver feasible. The timer reuses the claim convention `docs/agents/issue-tracker.md` already defines (`gh issue edit <n> --add-assignee @me`) to avoid double-processing, with no new signature-verification code or inbound surface.

**4. PRs are opened under a second fine-grained PAT scoped to this repo (`AFK_AGENT_TOKEN`)**, not `GITHUB_TOKEN`, following the exact shape of `FLAKE_UPDATE_TOKEN`: GitHub suppresses workflow events raised by `GITHUB_TOKEN`, so the required `nixos ci` check would never fire on the PR. Not a separate GitHub account either - a dedicated branch prefix and label carry the same at-a-glance distinction `deps/*` already provides for `FLAKE_UPDATE_TOKEN`, without a second account's credentials and 2FA to manage. The prefix and label names are plan parameters (item 3).

**5. AFK eligibility is bounded by a path denylist**, enforced twice: once at triage, before `ready-for-agent` is applied, and again by the runner itself before it starts, rather than trusted from the label alone. The denied paths are triage vocabulary, not an architectural constant, and live in `docs/agents/afk-eligibility.md` (plan item 2).

**6. Implementation retries in the same session, review does not.** A retry against a failing build or test happens inside the session that produced the failure, because a retry without the prior failure as context is close to useless. Review is always a separate pass in a fresh context (the existing `/code-review` skill, standards + spec in parallel) after implementation succeeds, regardless of how many retries it took - a self-review in the context that just wrote the code is the weakest form. A ticket that exhausts its retries, or otherwise can't proceed, gets a comment, a relabel, and a notification - never a PR. The retry budget is a plan parameter (item 5), bounded so that it cannot meaningfully threaten OpenCode Go's usage caps.

**7. The whole thing is a real NixOS module**, not a script someone remembers to run, so turning it off in an emergency is one boolean - following the pattern this repo already uses for every other service. The module path and option name follow that existing convention rather than being decided here (plan item 4).

**8. Execution is serial while the pipeline is unproven.** Concurrent worktrees were considered and deferred - not enough AFK-eligible tickets exist yet to need the throughput, and serial execution keeps "what's running right now" trivial to reason about. The concurrency level is a plan parameter (item 5); the reason to start at one is that an unproven runner should fail in one place at a time.

**9. Merge stays a human act.** No auto-merge for ticket-driven AFK work, full stop, regardless of how much trust the pipeline earns. (Fleet-incident-triggered auto-remediation was raised as a plausible *future*, narrower case - explicitly not decided here.)

## Consequences

**Positive**

- No new inbound network surface, no webhook signature verification to get wrong.
- No compliance ambiguity underneath the unattended path - OpenCode Go's automation support is confirmed, where Claude Pro/Max's is not.
- The identity, claim, and worktree-isolation mechanisms are all precedents this repo already trusts, not new designs.
- A one-line kill switch, consistent with how every other service in this repo is turned off.

**Negative**

- `homelab01` gains a new always-on process with repo-write credentials, alongside its existing services - genuine added blast radius, bounded by the path denylist, the worktree isolation, and the bounded retry count, but real.
- Polling adds up to one timer interval of latency between a ticket becoming eligible and work starting - accepted, since nothing about AFK ticket work needs sub-minute response.
- DeepSeek V4's actual code-quality on this codebase's ticket types is unproven, as is OpenCode's compatibility with the `.agents/skills/` format `implement`/`code-review` are written against. Both are pilot questions, not settled by this ADR.

## Alternatives considered

- **GitHub Actions**, mirroring `flake-update.yml`/`package-update.yml` exactly. Rejected: once the repo's public-repo free minutes removed the cost argument, the only remaining case for it was "less to build" - and self-hosting was a stated preference in its own right, not merely a cost trade-off to be argued out of.
- **A Claude cloud routine fired by a GitHub webhook trigger.** A genuine, unexplored first-party mechanism for exactly this kind of trigger. Rejected for now on two grounds: its exact repository-permission scope is unverified for a repo holding SOPS-encrypted secrets, and it doesn't serve the stated preference for self-hosting. Worth a follow-up spike once its permissions are confirmed.
- **A GitHub webhook into `homelab01`** through the existing Cloudflare tunnel, instead of polling. Feasible - the tunnel infrastructure already exists - but rejected as unnecessary new code (signature verification, a receiver service) for a latency requirement (sub-minute ticket pickup) that doesn't exist here.
- **Claude Code + Pro/Max subscription as the AFK executor**, accepting the ToS ambiguity. Rejected: building an unattended, unsupervised path on a foundation with an open compliance question is worse than the cost of switching harness for that one phase.
