# Plan: the AFK agent pipeline

Status: in progress — item 1 is done (`opencode-go/glm-5.3-flash` at `high`; see its Built note and cost-sustainability finding); item 2 is done (both eligibility rules written down, and the checks-matrix conflict settled with a narrow exception); item 3 is done (the token exists, is scoped to this repo alone, and was proven on a live PR); item 4 is done as a scaffold (the module, the kill-switch check, and the switch itself, written down as `false` on homelab01 - the runner it wraps is item 5, so its "Done when" only completes with that item); item 5 is done - both halves built, tested and proven live: poll → denylist → claim → isolate (#171, PR #194, which also demonstrated a second poll refusing while the worktree stood and a third finding nothing once cleared) and the implement stage on a bounded retry budget (#172, PR #195, which carried real ticket #178 from claim to a first-attempt commit on `afk/178-the-lock-screen-is-off-palette` under the unit's own ExecStart and environment); item 6 is done (#173): the stage runs, is contained, verifies itself from the transcript, and is **advisory** - both experiments that might have made it a gate have been run, neither did, and the plan's pre-committed outcome was applied, dropping the verdict and rewording the first acceptance criterion; see its Measured notes, the first of which also corrects item 1's review-stage finding, and the re-grade that moved review onto `deepseek-v4-pro` while implement stays on `glm-5.3-flash`; item 7 is done (#174) as code, and its live half is the join item 3 and the harness each prove separately - the runner pushes past a gate that reads the diff rather than the ticket's prose, opens the pull request with the review's findings and a paragraph saying what they are not, and clears up after itself; items 13, 14 and 15 were added 2026-09-09 out of reading item 7 back: the order it implements was chosen when the review was a gate, and with the gate gone the pull request should open first so that CI rather than an advisory pass is what catches correctness, which in turn wants the runner to have an identity of its own; item 14 is done (#200, [ADR 0006](../adr/0006-the-runner-is-a-github-app.md)) - the runner is a GitHub App, claims by label rather than by assignment, and commits and opens pull requests as itself; item 13 is done (#201, [ADR 0007](../adr/0007-the-pull-request-opens-before-the-review.md)) - the reorder landed, so a ticket that converges now pushes past the denylist gate, opens its pull request, watches that branch's own CI and feeds a red run back into the implement session, and only then reviews and writes the findings onto the pull request with the hand-off label, which also made item 7's `HEAD` pin dead code and deleted it; item 15 is unblocked by both and has not started; item 12 is new, added 2026-09-09 as the gap item 6's outcome exposed: the reviewer's notes and the human's notes now arrive in the same place with the same standing, and only the human's are worth acting on, but only the reviewer's have a path anywhere; item 8 is done (#175), its notification half closing with the item below; item 9 is done (notifications, #176): the runner publishes straight to the self-hosted ntfy server and the push lane's topic at that lane's own severity levels - a handed-over pull request at `low`, a handed-back ticket and a crossed cap threshold at `default` - with the runner's own spend recorded per session and checked against Go's dollar caps at the moment each record lands. Follows [ADR 0004](../adr/0004-afk-agent-runs-self-hosted-with-a-harness-split.md), which covers the architectural decisions (platform, harness split, identity, trigger, retries, kill switch) and the alternatives rejected along the way; this plan is the work items that implement it.

The engineering skills (`.agents/skills/`) already carry a ticket from idea through `to-tickets`, which publishes a GitHub issue labelled `ready-for-agent` per `docs/agents/triage-labels.md`. `implement` already runs `/tdd`, tests, and a self-review, then commits. Everything below starts at the gap right after that: nothing currently claims a `ready-for-agent` ticket unattended, pushes it, opens a PR, or tells anyone.

Item 1 gates the stages that depend on a model choice - item 5's implement step and item 6's review step - because building either around a guess would be the wrong order (ADR 0004 §2 leaves the model deliberately undecided). Items 2, 3 and 4 do not depend on it and can proceed in parallel with the pilot.

| #   | Item                                 | Size   | Status      |
| --- | ------------------------------------ | ------ | ----------- |
| 1   | Measured pilot                       | medium | done        |
| 2   | Triage: AFK eligibility              | small  | done        |
| 3   | AFK identity (`AFK_AGENT_TOKEN`)     | small  | done        |
| 4   | `modules/services/afk-agent.nix`     | medium | done        |
| 5   | Runner: claim → worktree → implement | large  | done        |
| 6   | Review stage                         | small  | done        |
| 7   | Raise the PR                         | small  | done        |
| 8   | Stuck path                           | small  | done        |
| 9   | Notifications                        | small  | done        |
| 10  | Peak-hour scheduling                 | small  | dropped     |
| 11  | Secrets                              | small  | not started |
| 12  | Revision loop: human review → agent  | medium | not started |
| 13  | PR before review, and watch CI       | medium | done        |
| 14  | The runner's own GitHub account      | small  | done        |
| 15  | Findings become a PR comment         | small  | not started |

---

## 1. Measured pilot

### The problem

Three real unknowns sit underneath ADR 0004's harness split: whether DeepSeek V4 (Pro or Flash) produces PR-quality output on this codebase's kind of tickets, whether OpenCode reads `.agents/skills/` well enough to run something equivalent to `/implement` and `/code-review`, and whether OpenCode Go's usage accounting reflects DeepSeek's off-peak discount. Guessing at any of them and building the rest of the pipeline on top is exactly backwards.

### Settled without spending a token, 2026-09-07

Two of the three questions fell out of the local install before any run happened. Recorded here so the runs below only have to answer what is actually still open.

**OpenCode reads `.agents/skills/` directly. Item 5 does not need to inline anything.** `opencode debug skill`, run from this repo, returns all 25 skills resolved off disk by absolute path — `implement` and `code-review` among them — alongside OpenCode's own built-in `customize-opencode`. Discovery searches `.opencode/skills/`, then `.claude/skills/`, then `.agents/skills/`, walking up from the working directory to the git worktree root, so a `git worktree add` checkout resolves them the same way the main checkout does.

Three caveats travel with that finding, all of them places the pipeline could misbehave without erroring:

- **Discovery is not invocation.** OpenCode exposes skills through a native `skill` tool the model _chooses_ to call. A weaker model may never call it and improvise instead — and this is not hypothetical: an existing DeepSeek V4 Flash session on this repo (`ses_f8abae513ffe…`, the Cloudflare Tunnel alert-silencing work) made 41 tool calls across `bash`, `edit`, `read`, `grep`, `glob` and `todowrite`, and never once called `skill`. The runner's prompt must name the skill explicitly rather than hope, and each pilot run records whether the `skill` tool actually fired.
- **`disable-model-invocation: true` is silently ignored.** OpenCode's frontmatter schema is `name`/`description`/`license`/`compatibility`/`metadata`, and unknown fields are dropped. So `implement`, `to-tickets`, `triage` and `handoff` — everything Claude Code deliberately hides from auto-invocation — are all auto-invocable under OpenCode. Not harmful, but it is a real behavioural divergence between the two harnesses, and it means the AFK executor has a wider skill surface than the interactive one.
- **`code-review` spawns parallel sub-agents.** OpenCode has a `task` tool, so the shape can work, but sub-agent model selection is separate configuration. Item 6 asserts the two axes run in genuinely separate contexts; if they collapse into one, that premise fails silently. Confirm it during the pilot's review stage rather than assuming it.

**The Go catalogue is far wider than ADR 0004 assumed, and the rates are flat.** Go carries 27 models, not the two the ADR names. The relevant slice, refreshed from models.dev via `opencode models opencode-go --verbose --refresh` (US$ per million tokens):

| Model               | In    | Out  | Context | Image | Variants                    |
| ------------------- | ----- | ---- | ------- | ----- | --------------------------- |
| `glm-5.3-flash`     | 0.075 | 0.25 | 1M      | yes   | low / high / max            |
| `qwen3.8-flash`     | 0.15  | 0.47 | 1M      | yes   | low / medium / xhigh        |
| `gpt-5.6-luna`      | 0.20  | 1.20 | 1.05M   | yes   | none…max (capped $15/mo)    |
| `deepseek-v4-flash` | 0.22  | 0.66 | 1M      | no    | low / high / max            |
| `longcat-2.0`       | 0.30  | 1.20 | 1M      | no    | low / medium / high         |
| `deepseek-v4-pro`   | 0.66  | 1.98 | 1M      | no    | high / max                  |
| `glm-5.3`           | 1.40  | 4.40 | 1M      | no    | low / high / max            |
| `qwen3.8-max`       | 2.00  | 6.00 | 1M      | yes   | low / medium / xhigh        |
| `grok-4.6`          | 2.00  | 6.00 | 500K    | yes   | low / medium / high / xhigh |
| `kimi-k3`           | 3.00  | 15.0 | 1M      | yes   | max only                    |

Go is dollar-metered at these published rates: $10/month buys roughly $60 of usage, capped at $12 per 5 hours, $30 per week and $60 per month, with optional fallback to the Zen balance once a cap is hit. The practical consequence for a serial runner is that `kimi-k3` burns the meter about fourteen times faster than `deepseek-v4-flash` for the same token count, and that the binding constraint is the **$12/5h rolling cap**, not the monthly one — a single ticket that costs a dollar is irrelevant monthly and material within a five-hour window.

There is no peak/off-peak field anywhere in the Go metadata; the rates are flat. That is strong evidence Go does _not_ pass DeepSeek's off-peak discount through, which is item 10's open question. It stays cheap to settle empirically — see the procedure — but **item 10 stands either way**, now justified by the 5-hour cap rather than by the discount.

**The measurement instrument already exists.** `opencode export <session-id>` emits, per session, the aggregate dollar cost, input/output/**reasoning** token counts, wall-clock span, the model _and variant_ actually used, and every tool call. Verified end to end on this host. Reasoning tokens being counted separately is what makes the effort-variant arm measurable rather than a matter of opinion.

It also gives a first cost scale to plan against, from real sessions rather than arithmetic: the DeepSeek V4 Flash session above cost **$0.067** for one small module change (90.7K input, 34.1K output, 3.5M cache reads). If that is representative, a ticket costs cents on the cheap arms and the $12/5h cap is nowhere near binding — but it is one session, on one ticket, which is exactly the reason the runs below exist rather than an argument for skipping them.

### Found during the pilot itself, 2026-09-08

Two things surfaced while grading the first three runs of arm A on #178, and both matter more than any single run's score.

**Repeats were not independent.** `pilot-run` originally used `git worktree add` against the live `~/git/dotfiles` checkout. Worktrees of one repo share its object database and refs, so from inside any run's worktree, `git branch -a` / `git log --all` / `git show <hash>` could see every other pilot run's branch - including a prior repeat's full committed solution to the same ticket. Repeat 3 of arm A on #178 did exactly this: it ran `git log --all --oneline --graph`, found repeat 1's commit, and `git show`ed all three of its changed files before writing its own - its own report calls the result "a deviation from the reference commit in history." That run is disqualified as a data point; it measured "can this model improve on a worked answer," not "can it solve the ticket." Repeats 1 and 2 happened to be clean (repeat 1 ran before any other #178 branch existed; repeat 2 only ran `git log --oneline -5`, never `--all`), so their results stand, but nothing downstream of repeat 3 could have been trusted without a fix.

The fix is a real, isolated clone per run rather than a worktree: `git clone --no-local --no-tags --single-branch --branch master`, then checkout the pinned baseline onto a new branch. Both flags are load-bearing. `--single-branch --branch master` keeps every ref but master out of view. `--no-local` is easy to miss and just as necessary - a same-filesystem clone otherwise hardlinks the _entire_ object store regardless of `--single-branch`, so a run that already had a commit hash could still `git show` it even with the ref hidden; verified by reproducing exactly that before adding the flag. Overhead is about 8 seconds per run, against a 15-60 minute `opencode run` - negligible. `pilot-run` and this document's copy of it are both updated.

**Passing the checklist is not the same as being mergeable, and repeat 1 is the proof.** Repeat 1 scored 8/8 against the checklist below, including "every colour traces to `lib/kanagawa-wave.nix`" - true of the wiring. But the palette's roles are plain `#RRGGBB` strings (correct for the CSS consumers waybar and rofi already use them for), and hyprlock's config grammar is not CSS: its own shipped example config uses only `rgba(...)`/`rgb(...)`, `#` is its comment character, and the rendered `hyprlock.conf` from repeat 1's build reads `check_color=#98BB6C` - a value that almost certainly never parses as a colour at all. `nix fmt` and the host build both passed; the lock screen would very likely still render off-palette. Gate-pass and even a literal spec-pass checklist can both go green on a change that fails the ticket's actual acceptance criterion ("visually matches Kanagawa Wave"), which is exactly why this item weights the subjective "would I merge this" pass as the ground truth rather than the checklist alone. Recorded as a failure reason for item 5's prompt: **sourcing the right file is not the same as sourcing a value the target format can parse - verify against the consuming tool's actual grammar, not just against where the value came from.**

Net effect on the noise-calibration pair: repeat 1 (checklist-passing but likely non-rendering) and repeat 2 (timed out, zero commits) now disagree in a different way than first reported, but they still disagree - which still means arm A's flake rate on this ticket needs a clean third repeat, run under the fixed isolation, before 3c proceeds.

**A clean repeat 3, run after the isolation fix, resolves more than it complicates.** It converged (committed, gate-pass, 7.5/8 on the checklist - the one gap being `rounding`/`outline_thickness` set to the correct numbers as bare literals rather than read from `lib/geometry.nix`, so a future change to item 6's scale would not reach it the way repeat 1's version would), it independently noticed and recorded the "five, not six" literal-count discrepancy that repeat 1 missed, and its architecture is arguably cleaner than repeat 1's (the deployed `hyprlock.conf` is literally the checked derivation's own output, rather than a side-derivation asserted alongside it). But rebuilding its `home-manager-generation` and inspecting the rendered conf shows the **identical** bug found in repeat 1: `check_color=#98BB6C`, bare and unquoted - repeat 3's own completion report even quotes that exact string as evidence the fix worked. Two independently-run, uncontaminated sessions reached the same wrong conclusion the same way, which reframes the finding: this is not per-run noise, it is a systematic blind spot in how this task gets approached - the palette file's roles are correct for the CSS consumers they were built for, nothing in the repo hints they need a different literal form for hyprlock, and neither run rendered its own output to check. It is reasonable to expect arms B-D to make the same miss, since nothing about it is model-specific.

That changes what the third repeat was for. Arm A's real convergence rate across three clean runs is 2/3 (one clean timeout, two clean commits) rather than a coin flip on output quality - the two that converged agree closely, including on the one thing both got wrong. That is enough to stop spending repeats on arm A and move to 3c, on two conditions: **add a fixed, uniform post-build check to the grading procedure** - after every run's host build, extract the rendered `hyprlock.conf` from `home.activationPackage`'s `home-files` output and grep for a colour literal not wrapped in `rgba(...)`/`0x...`, the same way this was caught by hand - so the bug is caught mechanically for arms B-D rather than requiring another manual rebuild-and-inspect; and **record the failure reason for item 5's real prompt** rather than editing this pilot's frozen prompt mid-run: sourcing the right file is not the same as sourcing a value the target format can parse, and a task that touches a Nix-configured surface should render and inspect its own output, not just re-check where the value came from.

### 3c (arms B-D), 2026-09-08

All six runs converged - gate-pass, one commit each, no isolation leaks (checked the same way as arm A's repeats: no run's `branch -a` shows anything beyond its own branch and `master`). That alone is a contrast with arm A's 2/3. Two things came out of grading them against the rendered-conf check the arm-A finding above called for.

**The colour-grammar bug is not universal - it is arm A's.** Every arm-A run that converged (repeats 1 and 3) got it wrong. Of arms B-D: `deepseek-v4-pro` fixed it in repeat 1 (`rgb = colour: "rgb(${lib.removePrefix "#" colour})"`, confirmed in the rendered conf) but _not_ in repeat 2, which rendered the identical bare `#98BB6C` arm A produced - so it is not a clean model-tier split, but the cheap arm is now the one with a perfect miss rate rather than a mixed one. `glm-5.3` and `glm-5.3-flash` both fixed it in both repeats, via their own small helper added to `lib/kanagawa-wave.nix` (additions only - nothing existing changed, and `homelab01`'s config still evaluates under each). Revises the earlier "expect every arm to miss this" prediction: three of four arms mostly catch it, and the fourth is not simply "the weak one" - it split 50/50 on its own two repeats.

**A second, genuinely subjective question surfaced: which palette role is "correct" for `check_color`.** The palette has both a `success` role (springGreen) and a `warning` role (roninYellow) and an `info` role (a blue). `deepseek-v4-pro` r1 and both `deepseek-v4-flash` successes used `success`. `glm-5.3` (both repeats) used `info`, with no stated reason. `glm-5.3-flash` (both repeats) used `warning`, and gave one: the _baseline_ itself painted this field amber (`rgb(204, 136, 34)`), and `warning` is the role that preserves that association rather than assuming "check-in-progress" means "success." The ticket names no role, so none of these is a checklist failure - but they are exactly the kind of reasoned-versus-arbitrary difference the blind pairwise ranking exists to surface, and `glm-5.3`'s unexplained choice is a weaker answer than either alternative regardless of which one is "right."

**Cost separates the arms far more than quality does.** `glm-5.3` costs $1.72-$3.11 per run - one run alone is over a quarter of the $12/5h cap, which makes it hard to justify for serial AFK use regardless of output quality. `deepseek-v4-pro` sits at $0.76-$0.99. `glm-5.3-flash` is $0.036-$0.054 - cheaper than arm A itself, and it is also the arm that fixed the colour bug in both repeats and gave the best-reasoned answer to the subjective question. That combination - cheapest, most consistent, best-justified - is worth registering now, ahead of the blind ranking in step 5, as the strongest candidate to survive to the holdout.

### Blind ranking, 2026-09-08

Graded with identities stripped, per Step 5.3, using the seven runs above (six Go arms plus the 3d calibration reference) laid out anonymously and re-shuffled so position gave no hint. The full ranking, best to worst, with the grader's own notes and the identity revealed afterward:

1. **Opus 5 (3d, reference - not eligible).** "Seems to be the most correct. Also went outside the literal ask, but in a way that addressed the spirit of what I was asking. Like the choice of showing my wallpaper (private and aesthetic)."
2. **`glm-5.3-flash`, repeat 1.** "Successful build - narrow scope. Colour literals fail evaluation without complex testing logic."
3. **`deepseek-v4-pro`, repeat 1.** "Valid syntax. Contained change. Like the choice of showing my wallpaper (private and aesthetic)."
4. **`glm-5.3-flash`, repeat 2.** "Valid syntax, and found the 5-vs-6 discrepancy, but seems to have over-complicated things a bit."
5. **`deepseek-v4-pro`, repeat 2.** "Likely won't render, like choosing the wallpaper as the background."
6. **`deepseek-v4-flash`, repeat 1.** "Likely won't render. Having side derivations for the check seems overcomplicated, and I don't want several packages to be created."
7. **`deepseek-v4-flash`, repeat 3 (last).** "Likely won't render, hard-coded colour values despite being asked not to." (The hardcoding was actually in the geometry - `rounding`/`outline_thickness` as bare literals rather than read from `lib/geometry.nix` - the colours themselves did come from the palette, just in a format hyprlock can't parse. Same underlying objection either way: a value that should trace to one file was written by hand instead.)

The ranking is a clean split on the objective "does this render" fact - every valid-syntax run outranked every broken one, no exceptions - and within each half, the deciding factor was architectural: rewarded narrow scope and a check simple enough to need no separate test logic (rank 2's "colour literals fail evaluation" is the highest praise any check got); penalized both an unnecessarily wide one (rank 4, which also touched `lib/kanagawa-wave.nix` and wrapped the whole `hyprlock` package) and an unnecessarily indirect one (rank 6's side-derivation-plus-extra-package pattern). The wallpaper-over-screenshot background call was noted approvingly every time it appeared (ranks 1, 3 and 5), independent of arm or render outcome - the first real signal that this is the grader's own preference rather than a coincidence of which arm happened to pick it.

**Verdict: `glm-5.3-flash` (arm D) wins among actual candidates**, taking 1st and 3rd of the six real candidates while costing roughly 1/20th of `deepseek-v4-pro` (arm B, 2nd and 4th). `deepseek-v4-flash` (arm A) is dropped: last in both repeats here, and it was already the only arm with a non-convergent run back in 3b. `deepseek-v4-pro` is kept as the pricier alternate into 3f rather than eliminated outright, since it beat one of `glm-5.3-flash`'s own repeats.

**Extending 3e to both `low` and `max`, not just `max` as originally scoped.** The written plan called for one run of the winner at `max` (the effort question was "does more reasoning help at all"); run at cost-per-run this low, there's no reason not to also ask "does _less_ reasoning still work" - `glm-5.3-flash` supports `low`/`high`/`max`, `high` is already covered by ranks 2 and 4 above, and one run each of `low` and `max` costs and takes about as much as the `high` runs already did. Worth watching once the export lands: repeat 1 above used zero reasoning tokens even at `high` while repeat 2 used 12,443 - if the variant isn't actually changing this model's behaviour much, `low` landing close to `high` would say so directly, which the original one-armed design (`max` only) couldn't have shown.

### Effort variants, 2026-09-08

Both `low` and `max` converged, both fixed the colour-grammar bug, and both correctly sourced geometry from `lib/geometry.nix` - on this ticket, the effort knob did not touch correctness. What it moved was scope, and it moved it a lot: `low` touched one file for 58 insertions and used the plainest check mechanism of any run in the pilot (a bare home-manager `assertions` entry, no script, no package); `high`'s two repeats sat in the middle (150 and 174 insertions, one and three extra files respectively); `max` touched four files for 322 insertions and built a two-sided source-and-output check that comes closer to the Opus reference's rigor than anything else in arm D. Reasoning-token counts back this reading: 0 / 12,443 / 10,789 / 36,678 across high-r1, high-r2, low, max - noisy at the bottom, but `max` is a clear outlier at the top. For this model on this ticket, the effort variant reads less like an accuracy dial and more like a thoroughness dial - worth stating plainly in item 5's prompt rather than assuming "higher effort" means "more correct," since correctness was never actually in question here.

`low` has one real gap `max` does not: it never touched `docs/plans/desktop-design.md`, so item 17's status and build note go unwritten even though the code change itself is sound. Its own log is more interesting than its output here - it verified "five" literals red against the baseline while testing the gate, then reverted to citing "six" in its final commit message, so the discrepancy was noticed and then lost rather than never noticed at all. `max` caught it and kept it, recording it directly in the plan.

Not re-run through the blind-ranking artifact - by this point the ranking has already been unsealed, and re-blinding two more runs from an already-identified winning arm would not remove any bias worth removing. Graded directly instead, the same way the checklist and rendered-conf checks were applied throughout.

### What is still open

Only the first question: whether any Go model produces mergeable output on this codebase's tickets, at what cost, and at what reasoning effort. The rest of this item is the protocol for answering it.

### Approach

**Five arms.** The ADR names two; two is not enough to find the floor, and the leaderboard evidence says the top of the Go range is undifferentiated. Terminal-Bench 2.1 currently places GLM-5.3 at 88.2, Grok 4.6 at 88.4, DeepSeek V4 Pro at 87.9, Kimi K3 at 88.3 and Qwen3.8 Max at 86.6 — five models inside a 1.8-point band, which is smaller than the benchmark's own noise. The useful reading of that is not "they are all equally good", it is "public benchmarks cannot pick the winner here". What separates them on this repo will be harness fit — tool-call reliability across a thirty-turn run, whether the `skill` tool gets called, whether the model stops early — none of which any leaderboard measures.

| Arm | Model                           | Variant         | Why it is in                                                                                                                                                                                                                         |
| --- | ------------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A   | `opencode-go/deepseek-v4-flash` | `high`          | The cheap default ADR 0004 presumed                                                                                                                                                                                                  |
| B   | `opencode-go/deepseek-v4-pro`   | `high`          | The ADR's other named arm                                                                                                                                                                                                            |
| C   | `opencode-go/glm-5.3`           | `high`          | The strong arm; tops the open-weights band and sets a realistic ceiling in Go                                                                                                                                                        |
| D   | `opencode-go/glm-5.3-flash`     | `high`          | Three times cheaper than A. If it passes, the budget question stops existing                                                                                                                                                         |
| E   | winner of A–D                   | `low` and `max` | The effort arm — run only after A–D are graded. Extended to both ends of the range once the winner (`glm-5.3-flash`) turned out cheap enough that asking "does less work too" costs almost nothing on top of asking "does more help" |

`high` is the floor because it is the only effort level all four models share (`deepseek-v4-pro` offers no `low`). Arm E is deliberately sequenced last: it is one extra run that retires a question otherwise guessed at permanently.

Plus one arm that is **not a candidate**: the same ticket run through Claude Code on Opus 5, as the calibration line. ADR 0004 §2 rules Claude Code out of the unattended path, so this never becomes the answer — but without a known-good ceiling there is no way to distinguish "this model is weak" from "this ticket is badly specified", and that ambiguity would waste the whole exercise.

**Two tickets and a smoke test, chosen for gradeability rather than for being representative.**

- **Smoke test: #167** (document the path denylist). Docs-only, costs cents, **not scored**. Run it on all four arms first, purely to shake out authentication, skills discovery, the permission overlay, commit formatting and worktree isolation — so the real runs are not debugging the harness and the model simultaneously.
- **Primary: #178** ("The lock screen is off-palette"). Desktop config, palette sourcing, geometry scale, write-the-check-first — the same _kind_ of work as the rofi and waybar tickets, but with mechanically checkable criteria. "A build-time check fails if `hyprlock.nix` contains any raw hex or `rgb()` literal not sourced from the shared palette" is gate-able; "radius and border match 12/2" is a literal comparison. The five offending literals are still at `modules/home/desktop/hyprlock.nix:42-51`, so a correctly-written check fails red on the baseline. It is single-file and small but still exercises the hard parts: locating `lib/kanagawa-wave.nix`, following item 5's check pattern, writing the check _before_ the change, and producing an explicit recorded decision about the `screenshot` background — that last criterion is the probe for silently-skipped judgement calls, which is a failure mode that only matters once nobody is watching.
- **Holdout: #159** ("The filter refuses a shelf-name collision"). A different axis entirely: real logic, a new test seam, and a ticket body that _argues_ for why the test must be structured a particular way. It is the best available measure of whether a model follows reasoning it has been given rather than pattern-matching nearby code, and it is fully headless and fully objective. **Held back and run once per surviving arm with the prompt frozen**, because iterating prompt wording against #178 fits the prompt to #178; #159 is the honest estimate.

**Why not #180, the ticket originally proposed.** Not because the models cannot see — the human grades the windows, not the model. Because its decisive criteria are manual and visual, and that breaks the experiment three ways. "Opening each of the seven surfaces shows a window sized to its content… no empty trailing rows… does not truncate without a scroll affordance" needs a live Hyprland session and human eyes across seven surfaces per run; at the sample size below that is over a hundred GUI inspections, and the measurement cost swamps the thing being measured. `nix flake check` passes whether or not the windows are sized correctly, so the primary objective metric goes dead exactly where the ticket is hardest. And it is large — seven call sites, a new build check, plus a resolve-or-defer judgement on `sidebar-mode` — which produces too many partial-credit states to discriminate between arms. #180 remains a good ticket; it is a bad instrument.

Also excluded: this pipeline's own tickets (#170–#176). Having the unproven agent build its own runner makes every failure ambiguous between "weak model" and "unclear spec".

**Sample size, and the one thing not to economise on.** Agent runs are stochastic — the same model on the same ticket can pass and fail. The design is **four arms × two repeats on the primary ticket (8 scored runs)**, then the effort arm and a single confirming run per surviving arm on the holdout — 13 scored runs in total, against roughly 20 executions once the unscored smoke and calibration runs are counted. The full breakdown is in the procedure's vocabulary section. If it proves too expensive, **cut arms before cutting repeats.** Run one arm's two repeats first: if they disagree with each other, the effect size is smaller than the noise, and no amount of single-run comparison will settle anything.

### What counts as evidence

Three sources, with three different jobs, and they are not interchangeable.

**Public leaderboards pick the shortlist and never the winner.** They are a prior, not evidence, for four reasons. The top of the band is inside the noise, as above. The task distribution is Python and JavaScript repositories with unit tests; Nix is close to absent from every public coding benchmark, so a SWE-bench score transfers roughly not at all to "knows that `nix fmt -- --ci` is the gate and that `checks/` are VM tests". Every published number is model _plus_ scaffold — Kimi K3's 88.3 is measured with KimiCode at max reasoning, not with OpenCode. And the headline figures are increasingly vendor-reported. Their legitimate job was getting 27 Go models down to four arms in an afternoon of reading. That job is done.

**Objective data decides elimination, and the metrics are fixed before the first run.** The trap is measuring what is easy — tokens, seconds — rather than what decides. Recorded per run:

- **Gate-pass (binary, primary).** Did `nix fmt -- --ci` and the host build pass on the agent's branch, unassisted? This gate already exists and CI already enforces it. One bit, no judgement.
- **Spec-pass (binary, primary).** Every acceptance checkbox satisfied, graded against the checklists below, which are written _before_ any run.
- **Human-fix distance.** The most informative number. Not "needed fixes: yes/no", which flattens a typo and a redesign into one value — the diff between the agent's commit and the state that would actually be merged, in lines _and_ in minutes to fix.
- **Cost per _successful_ run.** From the session export. A three-cent run that fails is infinitely expensive; cost per run is the wrong denominator.
- **Wall-clock: recorded, not weighted.** AFK work runs overnight, so twelve minutes and forty minutes are the same outcome. What matters is whether a run exceeds the timeout item 5 will need.
- **Unattended-failure behaviours**, which are what make this different from measuring a supervised agent: was the `skill` tool called at all; was a denylisted path touched; was a command hallucinated; did the run stop early and hand back. A model that scores well but stops early is useless here, and no benchmark measures it.

**Subjective judgement is the ground truth, not the weak evidence.** These PRs get merged by a human, so "would I merge this unedited?" _is_ the target variable and every objective metric above is a proxy for it. It is structured rather than free-floating: grade the diffs with the arm identities stripped, and **rank pairwise rather than scoring out of ten**, because a single rater's absolute scores drift across a session while rankings do not. Grade against the pre-written checklist, so the verdict is not rationalised after seeing the output. And record the _reasons_, not just the verdict — "invented an abstraction the repo does not use", "wrote the check after the change instead of before", "ignored the formatting gate". Those reasons are worth more than the scores; they are what goes into `AGENTS.md` and into item 5's prompt.

The synthesis: leaderboards shortlist, gates eliminate, blind ranking selects among survivors, cost breaks ties. Nothing is chosen on a benchmark number, and nothing is eliminated on a feeling.

### Procedure

Kept in this document rather than as a script under `packages/`, because it is a one-off measurement whose reasoning matters more than its reusability — and because item 5 lifts its `opencode run` invocation from here directly.

#### Vocabulary

Four words that are used precisely below, because the arithmetic depends on them:

| Term       | Means                                                                                                                                             | How many                                  |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| **Pilot**  | This whole exercise — every command in this section, start to finish                                                                              | 1                                         |
| **Arm**    | One _configuration_ under comparison: a model plus a reasoning variant. A condition, not an execution                                             | 5 (A–E)                                   |
| **Repeat** | The same arm on the same ticket, executed again, to separate signal from noise                                                                    | 2 on the primary ticket, 1 on the holdout |
| **Run**    | One _execution_ — one call to `pilot-run`. A run is an arm × a ticket × a repeat, and produces one worktree, one branch, one row in `results.tsv` | 22 at most (see below)                    |

So an arm is what you are comparing; a run is what you execute; the pilot is all of it. "Arm C failed" means the model configuration lost; "run `i178-glm-5.3-high-r2` failed" means one specific execution did, which may or may not be the arm's fault — that is exactly what the repeats are for.

The full count, since the run order below is easy to misread as symmetric:

| Stage | What                                        | Runs      | Scored         |
| ----- | ------------------------------------------- | --------- | -------------- |
| 3a    | Smoke test, #167, arms A–D                  | 4         | no             |
| 3b    | Noise calibration, #178, arm A × 2          | 2         | yes            |
| 3c    | #178, arms B–D × 2 repeats                  | 6         | yes            |
| 3d    | Calibration ceiling, #178, Opus 5           | 1         | no (reference) |
| 3e    | Effort arm, #178, winner at `low` and `max` | 2         | yes            |
| 3f    | Holdout, #159, surviving arms × 1           | up to 4   | yes            |
| —     | Off-peak probe, #167                        | 2         | no             |
|       | **Total (original estimate)**               | **20–22** | **13 scored**  |

The actual count has already run ahead of this estimate - a re-run repeat after the isolation fix, `glm-5.3` dropped after 3c rather than carried to 3f, and 3e extended from one run to two - each decision recorded where it happened above rather than reconciled back into this table.

The holdout runs **once** per surviving arm, not twice, and that asymmetry is deliberate: #159 is a confirmation with the prompt frozen, not a second comparison. Repeats buy noise estimates, and the noise estimate has already been bought on #178.

#### Where to run these commands

`pilot-run` and `pilot-review` are written to be independent of the working directory — they use `git -C "$REPO"` and `cd` into the run's own worktree in a subshell, because OpenCode scopes both skill discovery and session listing to the project it was launched in. **The one exception is the `gh issue view` snapshot in Step 1**, because `gh` resolves the repository from the current directory's git remote: run that line from `~/git/dotfiles`. Nothing else cares, so the simplest habit is to run the whole pilot from `~/git/dotfiles` and never think about it again.

#### Step 0 — prerequisites, from `~/git/dotfiles`

1. Commit or stash everything. The pilot's baseline must be a real commit, and every arm starts from the same one.
2. Confirm authentication: `opencode providers list` lists **OpenCode Go**.
3. Read the grading checklists below **now**, before seeing any output.

#### Step 1 — set up the pilot directory, once per pilot

The baseline is pinned into a **file**, not an environment variable. A variable assigned with `$(git rev-parse HEAD)` re-derives itself in every new shell, so a commit landing on `master` midway through would silently give later runs a different baseline — and the comparison would be broken in a way nothing in the results would reveal.

```bash
mkdir -p ~/pilot
git -C ~/git/dotfiles rev-parse HEAD > ~/pilot/baseline     # pin once, never again
for n in 167 178 159; do gh issue view $n > ~/pilot/issue-$n.txt; done   # from ~/git/dotfiles
printf 'run_id\tissue\tmodel\tvariant\trepeat\tsession\tcost\ttok_in\ttok_out\ttok_reasoning\ttool_calls\tused_skill\tsecs\texit\tfmt\tbuild\tcommits\tinsertions\tdeletions\n' > ~/pilot/results.tsv
```

Snapshotting the issue bodies matters because they are the spec being graded against: if one gets edited mid-pilot, the later arms are answering a different question, and the snapshot is what makes that visible.

The prompt is written once and never varied between arms — that is the whole point of a controlled comparison, and it is also the draft of item 5's real prompt:

```bash
cat > ~/pilot/prompt.tmpl <<'EOF'
Implement GitHub issue #ISSUE in this repository.

Use the `implement` skill. Fetch the issue with `gh issue view ISSUE`.

Constraints:
- Do not modify `.github/workflows/`, `secrets/`, or `.sops.yaml`.
- Do not push, do not open a pull request, and do not edit or close the issue.
- Do not run `/code-review`; review is a separate stage run after you finish.
- Commit your work to the current branch when done.
EOF
```

The `implement` skill ends by telling the agent to run `/code-review` itself. That instruction is overridden above deliberately: item 6 makes review a separate fresh-context pass, and folding it in here would make an implement failure and a review failure indistinguishable.

#### Step 2 — the pilot library

`pilot-run` and `pilot-review` are shell functions, so they exist only in the shell that defined them. Rather than pasting them repeatedly, write them to a file once and **`source ~/pilot/pilot.sh` in each terminal you use for the pilot** — including after a reboot, a new tab, or a `tmux` pane. Re-sourcing is always safe: it reads the pinned baseline from `~/pilot/baseline` rather than re-deriving it.

Write the file (`cat > ~/pilot/pilot.sh <<'PILOT_EOF' … PILOT_EOF`) with this content:

```bash
REPO=~/git/dotfiles
PILOT=~/pilot
BASE=$(cat "$PILOT/baseline")   # read the pin; never re-derive it

pilot-run() {  # pilot-run <issue> <model> <variant> <repeat> <host>
  local issue=$1 model=$2 variant=$3 rep=$4 host=$5
  local id="i${issue}-${model}-${variant}-r${rep}"
  local wt="$PILOT/$id"

  # An isolated clone, not a worktree of $REPO. Worktrees share $REPO's refs,
  # so any run could `git log --all` / `branch -a` / `show <hash>` its way
  # into every other run's committed solution for the same ticket - found
  # 2026-09-08 when a repeat read a prior repeat's commit this way and built
  # on it instead of solving independently (see the finding below). Both
  # flags matter: --single-branch --branch master keeps every ref but master
  # out of view; --no-local is easy to miss and just as load-bearing - a
  # same-filesystem clone otherwise hardlinks the *entire* object store
  # regardless of --single-branch, so a run that already knew a commit hash
  # could still `git show` it even with refs hidden. --no-local forces the
  # real fetch-negotiation path, which actually excludes unreachable objects.
  git clone -q --no-local --no-tags --single-branch --branch master "$REPO" "$wt" >/dev/null 2>&1 || return 1
  git -C "$wt" checkout -q "$BASE" -b "pilot/$id" >/dev/null 2>&1 || return 1
  sed "s/ISSUE/$issue/g" "$PILOT/prompt.tmpl" > "$PILOT/$id.prompt"

  # Pilot-only guardrails. Verified with `opencode debug config`: inline config
  # merges after the repo's own rules, and last match wins, so these take effect.
  local guard='{"permission":{"bash":{"git push*":"deny","gh issue edit*":"deny","gh issue close*":"deny","gh issue comment*":"deny","gh pr*":"deny"}}}'

  local t0 t1 rc
  t0=$(date +%s)
  ( cd "$wt" && OPENCODE_CONFIG_CONTENT="$guard" timeout 3600 \
      opencode run --model "opencode-go/$model" --variant "$variant" \
                   --agent build --title "$id" --auto \
                   "$(cat "$PILOT/$id.prompt")" ) > "$PILOT/$id.log" 2>&1
  rc=$?
  t1=$(date +%s)

  # Redirect the export to a file before touching it with jq: piping
  # `opencode export` straight into jq truncates on large sessions.
  local sid
  sid=$(cd "$wt" && opencode session list -n 20 --format json 2>/dev/null \
          | jq -r --arg t "$id" '.[] | select(.title==$t) | .id' | head -1)
  ( cd "$wt" && opencode export "$sid" ) > "$PILOT/$id.json" 2>/dev/null

  local metrics
  metrics=$(jq -r '
    [ .info.cost,
      .info.tokens.input, .info.tokens.output, .info.tokens.reasoning,
      ([.messages[].parts[]? | select(.type=="tool") | .tool] | length),
      ([.messages[].parts[]? | select(.type=="tool") | .tool] | index("skill") != null)
    ] | @tsv' "$PILOT/$id.json")

  ( cd "$wt" && nix fmt -- --ci ) >/dev/null 2>&1; local fmt=$?
  local build=0
  if [ -n "$host" ]; then
    ( cd "$wt" && nix build --no-link \
        ".#nixosConfigurations.$host.config.system.build.toplevel" ) >/dev/null 2>&1
    build=$?
  fi

  local commits ins del row
  commits=$(git -C "$wt" rev-list --count "$BASE"..HEAD)
  read -r ins del <<<"$(git -C "$wt" diff --numstat "$BASE" \
                          | awk '{i+=$1; d+=$2} END {print i+0, d+0}')"

  row=$(printf '%s\t' "$id" "$issue" "$model" "$variant" "$rep" "$sid")
  row+="$metrics"$'\t'
  row+=$(printf '%s\t' "$((t1-t0))" "$rc" "$fmt" "$build" "$commits" "$ins" "$del")
  printf '%s\n' "${row%$'\t'}" >> "$PILOT/results.tsv"

  echo "$id: exit=$rc fmt=$fmt build=$build commits=$commits $((t1-t0))s"
}

pilot-review() {  # pilot-review <run-id> <issue> <model>
  local id=$1 issue=$2 model=$3 wt="$PILOT/$id"
  # `edit: deny` makes "report only" enforced rather than merely requested,
  # so a review pass cannot quietly fix what it was supposed to report.
  local guard='{"permission":{"edit":"deny","bash":{"git push*":"deny","git commit*":"deny","gh pr*":"deny","gh issue edit*":"deny"}}}'

  ( cd "$wt" && OPENCODE_CONFIG_CONTENT="$guard" timeout 1800 \
      opencode run --model "opencode-go/$model" --variant high \
                   --agent build --title "$id-review" --auto \
                   "Use the \`code-review\` skill. The fixed point is $BASE. The spec is GitHub issue #$issue; fetch it with \`gh issue view $issue\`. Report findings only — do not change any files." \
  ) > "$PILOT/$id-review.log" 2>&1

  local sid
  sid=$(cd "$wt" && opencode session list -n 20 --format json 2>/dev/null \
          | jq -r --arg t "$id-review" '.[] | select(.title==$t) | .id' | head -1)
  ( cd "$wt" && opencode export "$sid" ) > "$PILOT/$id-review.json" 2>/dev/null

  jq -r '"cost=\(.info.cost) subagents=\([.messages[].parts[]? | select(.type=="tool") | .tool] | map(select(. == "task")) | length)"' \
    "$PILOT/$id-review.json"
}
```

A run is named by its arm, its ticket and its repeat — `i178-glm-5.3-high-r2` is arm C's second repeat on the primary ticket. That id is the worktree directory under `~/pilot/`, the branch name under `pilot/`, the OpenCode session title, and the first column of `results.tsv`, so any one of them leads back to the other three.

Notes on the choices, since each of them is load-bearing:

- **`--auto` is required, not a shortcut.** It approves everything the permission config does not deny, which is exactly the posture the real runner has. Sitting there approving prompts would measure the supervised path, not the unattended one.
- **`OPENCODE_CONFIG_CONTENT` rather than a file in the worktree.** A config file committed into the worktree would show up in the diff being measured. The inline variable merges above both the repo config and any `.opencode/` directory, and the pilot denies are appended after the repo's own rules, so last-match-wins gives them effect. Confirmed with `opencode debug config`.
- **An isolated clone per run, never reused, and never a worktree of `$REPO`.** Each arm starts from the pinned baseline with no other branch reachable - see the isolation finding below for why that second property needed its own fix. Clean up with `rm -rf "$wt"` once graded, not before, because the diff is the evidence; there is no `git worktree remove` step since `$wt` was never registered as a worktree of `$REPO`.
- **Per-run gate is `nix fmt -- --ci` plus the host build, not full `nix flake check`.** Sixteen full flake checks build every VM test in `checks/`, and almost none of them are reachable from these two tickets. The host build catches evaluation and build failures, which is where a bad change lands. **Run the full `nix flake check` on the finalists only** — the honest gate is what CI runs, and it is what the winning diff must pass before anything merges.
- **Hosts:** `xps15` for #178 (it owns hyprlock), `homelab01` for #159 (it is the gateway, so it owns the digital garden). Pass an empty host for the docs-only smoke test on #167.
- **The session export is written to a file before jq touches it.** Piping `opencode export` straight into `jq` truncates on large sessions — verified, and it fails as a parse error rather than as a wrong number, but only sometimes, which is worse. The `.json` file per run is also the raw evidence for grading, so it is worth keeping regardless.
- **`used_skill` is read from the export, not grepped out of the log.** Tool calls live at `.messages[].parts[] | select(.type=="tool") | .tool`; the default run log is human-formatted and cannot be parsed reliably. `tool_calls` comes from the same place and is worth watching: a run with very few tool calls that still claims success usually did not read enough of the repo.
- **`exit` and `commits` are separate columns for a reason.** A run can exit 0 having decided to explain what it would do rather than do it. `commits = 0` with `insertions > 0` means it worked but never committed; `commits = 0` with `insertions = 0` means it did nothing at all. Both are failure modes specific to unattended operation and both are invisible in a pass/fail column.

#### Step 3 — run order

Order matters: the smoke test shakes out mechanics, the repeat pair calibrates noise before any comparison is attempted, and the holdout runs last with nothing changed.

```bash
# 3a. Smoke test — not scored. Confirms auth, skills, permissions, commit shape.
for m in deepseek-v4-flash deepseek-v4-pro glm-5.3 glm-5.3-flash; do
  pilot-run 167 "$m" high 1 ""
done

# 3b. Noise calibration FIRST. If these two disagree, the design is under-powered
#     and everything downstream is a coin flip — stop and add repeats.
pilot-run 178 deepseek-v4-flash high 1 xps15
pilot-run 178 deepseek-v4-flash high 2 xps15

# 3c. The rest of the primary ticket.
for m in deepseek-v4-pro glm-5.3 glm-5.3-flash; do
  for r in 1 2; do pilot-run 178 "$m" high "$r" xps15; done
done

# 3d. Calibration ceiling: same ticket, same baseline, Claude Code on Opus 5,
#     from a worktree created by hand. Not a candidate — the reference line.

# 3e. Effort arm, once the winner of 3b–3c is known. Extended to both ends of
#     the range, not just `max` — see the blind-ranking finding above.
pilot-run 178 <winner> low 1 xps15
pilot-run 178 <winner> max 1 xps15

# 3f. Holdout, prompt frozen, one run per surviving arm.
for m in <survivors>; do pilot-run 159 "$m" high 1 homelab01; done
```

Two cheap experiments to fold in while the caps are being watched anyway:

- **Off-peak pass-through (item 10).** Run `pilot-run 167 deepseek-v4-flash high 9 ""` once inside a peak window (01:00–04:00 or 06:00–10:00 UTC, weekday) and once outside it, then compare the `cost` column for the same token counts. Costs a few cents and settles the ADR's open question outright.
- **Cap headroom.** After 3c, read the cost column: total spend across eight runs of one ticket is the number that says whether serial AFK operation fits inside $12 per five hours.

#### Step 4 — review stage

Run `pilot-review <run-id> <issue> <model>` only against runs that passed step 3's gate. It starts a **fresh session** against the same worktree — that separation is the whole point of item 6, and reusing the implement session would defeat it.

The function prints the `task`-tool count, which is the number that matters beyond the findings themselves: **`subagents=0` means the two axes collapsed into a single context**, and item 6's premise — that review is a genuinely separate pass — fails silently rather than erroring. Expect 2. Record alongside it whether the review caught the defects already found by hand during grading: a review pass that misses what a human found in five minutes is not a review stage.

#### Step 5 — grading

1. **Objective pass first**, from `results.tsv`. Any run with `fmt != 0` or `build != 0` is eliminated. No discussion, no partial credit — CI would reject it.
2. **Spec-pass**, against the checklists below, one column per run.
3. **Blind pairwise ranking** of the survivors' diffs. Strip the identities first:

   ```bash
   # Each run's branch lives only inside its own clone under $PILOT now (see the
   # isolation finding above), not in $REPO, so the listing walks $PILOT's
   # directories rather than $REPO's refs.
   ls -d "$PILOT"/i178-*/ | xargs -n1 basename | shuf | nl -w1 -s$'\t' > "$PILOT/blind-key.tsv"
   # review `git -C "$PILOT/<run-id>" diff $BASE` by row number; unseal the key only afterwards
   ```

   Rank rows against each other rather than scoring each in isolation, and write the _reason_ beside each placement.

4. **Cost breaks ties**, from cost per _successful_ run, not per run.
5. Record the outcome in the results table below, then append a `### Built` note naming the chosen model and variant, the numbers behind it, and — most valuable for item 5 — the recurring failure reasons from step 3.

### Grading checklists

Written before any run, taken from the tickets' own acceptance criteria. Each is scored pass/fail with a one-line reason; partial credit is recorded as a fail with the gap named.

**#178 — the lock screen is off-palette**

One discrepancy in the ticket, found while writing this and left in place deliberately: it says "six colour literals" but `modules/home/desktop/hyprlock.nix` holds five (`outer_color`, `inner_color`, `font_color`, `check_color`, `fail_color` at lines 42-51; the `capslock_color = -1` family are "don't change" sentinels, not colours). Grade against five. It is worth watching whether any arm notices the mismatch and says so, versus inventing a sixth to satisfy the count — that distinction is more informative than the checklist itself.

- [ ] A build-time check exists that fails on any raw hex or `rgb()` literal in `hyprlock.nix` not sourced from the shared palette
- [ ] The check was written so it fails against the baseline's literals, not retrofitted to pass afterwards (verifiable: run the new check against `$BASE`)
- [ ] After the change, every colour in `hyprlock.nix` traces to `lib/kanagawa-wave.nix` via `config.lib.stylix.colors`
- [ ] Input field radius is 12 and border is 2, per item 6's geometry scale
- [ ] The `path = "screenshot"` background has an explicit recorded decision — kept, changed or dropped — with the privacy/aesthetic tradeoff named, rather than being left untouched and unmentioned
- [ ] Follows the item 5 pattern (the deployed file is the check's output) rather than adding a test under `checks/`
- [ ] No files outside the ticket's scope modified; nothing under `.github/workflows/`, `secrets/`, `.sops.yaml` touched
- [ ] Work is committed to the branch, with a message matching the repo's convention

**#159 — the filter refuses a shelf-name collision**

- [ ] The filter detects two distinct folders whose leaf names slugify to the same shelf
- [ ] On collision the render fails, and the message names both colliding paths _and_ the shared slug
- [ ] A vault with no collision renders exactly as before
- [ ] The failure is reachable by the existing sync-health alerting
- [ ] A test invokes the filter **directly** against a colliding vault — not through the served site
- [ ] That test's fixture is separate from the VM check's vault fixture and leaves it undisturbed
- [ ] The ticket's stated reasoning for _why_ the test must be structured this way is followed, not merely the surface requirement
- [ ] No files outside scope modified; work committed

### Holdout, 2026-09-08

Prompt frozen, one run each for the two surviving candidates. Both converged and both avoided the trap the ticket names explicitly - neither asserts through the served site, both invoke the filter directly via a plain `runCommand` (no VM boot), both keep their fixture separate from the existing VM check's vault.

They diverge past that point. `glm-5.3-flash`'s test includes the explicit no-collision control the checklist asks for (a clean vault, asserted to stage normally with the right shelf topics on each note); `deepseek-v4-pro`'s test only exercises the collision case, leaving that acceptance criterion untested.

That gap turned out to hide a real bug. `deepseek-v4-pro` places its shelf-collision check in the filter's first pass, before the pass that drops notes with unparseable frontmatter; `glm-5.3-flash` places it after, with its own comment stating why - "a note that will not publish cannot merge a shelf." Built a fixture to settle which one actually holds: two folders both named `Meetings`, one with a normal published note, the other with a note whose frontmatter says `publish: true` but is genuinely broken YAML underneath (so it will never publish - no real collision exists). Run directly against both filters:

```
=== glm-5.3-flash ===
unparseable frontmatter, not publishing: B/Meetings/bad.md
published 1 notes, 0 attachments, skipped 1
exit=0

=== deepseek-v4-pro ===
published notes' shelves collide; rename one of each folder:
  A/Meetings
  B/Meetings  (both slugify to shelf 'meetings')
exit=1
```

`deepseek-v4-pro` refuses a vault that has no actual collision - a false positive, and exactly the failure acceptance criterion 3 exists to prevent. Its own completion report claims the no-collision case is "covered," which is not true; it was never tested, and does not hold. This is the precise thing #159 was chosen to measure: both models wrote nearly identical prose explaining that only actually-published notes can collide, but only `glm-5.3-flash` carried that invariant through to where the check runs rather than only into the comment beside it.

**`glm-5.3-flash` passes the holdout cleanly, including the edge case; `deepseek-v4-pro` does not.** Recorded here rather than only in the results table because the reasoning matters for item 5's prompt: "explains the invariant correctly" and "enforces the invariant correctly" are not the same claim, and grading on the former would have missed this.

### Results

Filled in as runs complete. Cost in US$, time in seconds, fix-distance in minutes.

| Run                                                   | Ticket | Model                | Variant     | Rep | Gate | Spec                               | Skill tool | Cost                     | Time                     | Fix-distance     | Blind rank                         | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------------- | ------ | -------------------- | ----------- | --- | ---- | ---------------------------------- | ---------- | ------------------------ | ------------------------ | ---------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `i178-deepseek-v4-flash-high-r1`                      | 178    | deepseek-v4-flash    | high        | 1   | pass | fail                               | true       | $0.1147                  | 986s                     | not yet measured | 6th of 7                           | 8/8 on the written checklist, but the palette's `#RRGGBB` strings are almost certainly unparseable by hyprlock's config grammar (comment char is `#`; its own example config uses only `rgba()`/`rgb()`) - checklist-green, likely non-rendering. See the finding above.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `i178-deepseek-v4-flash-high-r2`                      | 178    | deepseek-v4-flash    | high        | 2   | fail | fail                               | true       | $0.2918                  | 3601s (timeout)          | n/a - no commit  | pending                            | Hit the 3600s cap with zero commits. 87 of 117 tool calls were `bash`, spent re-deriving facts (stylix internals, hyprlock colour syntax) instead of converging; never touched `hyprlock.nix`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `i178-deepseek-v4-flash-high-r3` (contaminated, void) | 178    | deepseek-v4-flash    | high        | 3   | —    | —                                  | true       | $0.2004                  | 1598s                    | —                | **disqualified**                   | Ran `git log --all` / `git show` and read repeat 1's full committed solution before writing its own - contaminated by the worktree-sharing bug fixed above. Not counted.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `i178-deepseek-v4-flash-high-r3` (re-run, isolated)   | 178    | deepseek-v4-flash    | high        | 3   | pass | fail                               | true       | $0.0764                  | 829s                     | not yet measured | 7th of 7 (last)                    | 7.5/8 on the checklist (radius/border correct value but hardcoded rather than read from `lib/geometry.nix`); correctly flagged the five-vs-six literal discrepancy; kept `path = "screenshot"` with a well-reasoned tradeoff (valid alternative to repeat 1's choice). Same rendered-conf colour bug as repeat 1, independently arrived at - see the finding above. Cheapest and fastest #178 run so far.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `i178-opus5-r1` (3d, calibration - not a candidate)   | 178    | Claude Code / Opus 5 | interactive | 1   | pass | pass                               | n/a        | not tracked the same way | not tracked the same way | not yet measured | 1st of 7 (reference, not eligible) | Driven by hand, not `--auto`. Fixed the colour-grammar bug (`rgb(FF9E3B)`, confirmed in the rendered conf), and is the only run in the pilot to make `outer_color` track hyprlock's own idle→checking→failed states (`accent`→`warning`→`danger`) rather than a static colour, and to also colour the greeting/clock labels - both outside the ticket's literal scope. Its check validates the _rendered_ conf against the palette's actual colour set (four literal syntaxes normalised), not just the module source - the most rigorous of all seven, though it checks colour _identity_ against the palette rather than hyprlock's literal _grammar_, so it would not itself have caught the bare-hex bug had Opus produced it. Correctly flagged the five-vs-six discrepancy. A clean diff, not a rough one - so if anything in the checklist still trips on this ticket, that now points at the ticket rather than at the Go models. |
| `i178-deepseek-v4-pro-high-r1`                        | 178    | deepseek-v4-pro      | high        | 1   | pass | pass (rendered-colour check added) | true       | $0.9885                  | 2134s                    | not yet measured | 3rd of 7                           | Diagnosed the colour-grammar bug itself and fixed it: `rgb = colour: "rgb(${lib.removePrefix "#" colour})"`, confirmed in the rendered conf (`check_color=rgb(98BB6C)`). Background changed to `config.stylix.image`, with reasoning. Radius/border correctly read from `lib/geometry.nix`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `i178-deepseek-v4-pro-high-r2`                        | 178    | deepseek-v4-pro      | high        | 2   | pass | fail                               | true       | $0.7616                  | 2151s                    | not yet measured | 5th of 7                           | Same arm, same ticket, did **not** fix the colour bug this repeat - rendered conf shows bare `check_color=#98BB6C`, identical to arm A's failure. Within-arm inconsistency on the exact question repeat 1 answered correctly.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `i178-glm-5.3-high-r1`                                | 178    | glm-5.3              | high        | 1   | pass | fail (wrong role)                  | true       | $3.1050                  | 1767s                    | not yet measured | pending                            | Fixed the colour-grammar bug via a new `rgb` helper added to `lib/kanagawa-wave.nix` (addition only, no existing values touched; homelab01/02 still evaluate) - rendered conf confirms `rgb(126, 156, 216)`, valid syntax. But mapped `check_color` to `roles.info` (blue) rather than `roles.success` (green), with no stated rationale, when a role named exactly for this purpose already exists. By far the most expensive run of the pilot so far - one run is over a quarter of the $12/5h cap.                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `i178-glm-5.3-high-r2`                                | 178    | glm-5.3              | high        | 2   | pass | fail (wrong role)                  | true       | $1.7172                  | 1022s                    | not yet measured | pending                            | Same fix, same `info`-not-`success` choice as repeat 1 (consistent within the arm, unlike deepseek-v4-pro). Still expensive relative to every other arm.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `i178-glm-5.3-flash-high-r1`                          | 178    | glm-5.3-flash        | high        | 1   | pass | fail (debatable role, justified)   | true       | $0.0544                  | 950s                     | not yet measured | 2nd of 7                           | Fixed the colour-grammar bug (`rgb(FF9E3B)`, hex-compressed, valid). Mapped `check_color` to `roles.warning` (amber) rather than `success`, but with an explicit rationale: the _baseline_ itself used amber for this exact field, and `warning` is the role that preserves that. Cheapest run of the entire pilot, arms A-D included.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `i178-glm-5.3-flash-high-r2`                          | 178    | glm-5.3-flash        | high        | 2   | pass | fail (debatable role, justified)   | true       | $0.0359                  | 719s                     | not yet measured | 4th of 7                           | Same fix and same `warning` choice as repeat 1. Added a small `rgbOf` helper to `lib/kanagawa-wave.nix` (addition only; homelab01 still evaluates). Cheapest and fastest run of the pilot.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `i178-glm-5.3-flash-low-r1` (3e)                      | 178    | glm-5.3-flash        | low         | 1   | pass | fail (see finding below)           | true       | $0.0572                  | 1666s                    | not yet measured | not blind-ranked                   | Correct fix (`rgb(255, 158, 59)`, valid), geometry sourced from `lib/geometry.nix`, `warning` role, background kept with reasoning - and a sixth distinct check architecture: a home-manager `assertions` entry, no separate script or package at all. But never touched `docs/plans/desktop-design.md` - item 17's status and build note are left unwritten - and its own log shows it verified "five" literals red against the baseline, then reverted to "six" in the final commit message anyway. Smallest diff of any converged run (58 insertions, one file).                                                                                                                                                                                                                                                                                                                                                                       |
| `i178-glm-5.3-flash-max-r1` (3e)                      | 178    | glm-5.3-flash        | max         | 1   | pass | pass                               | true       | $0.0859                  | 1772s                    | not yet measured | not blind-ranked                   | Correct fix (`rgb(FF9E3B)`, valid), geometry sourced, `warning` role, background kept. Closest to Opus's rigor of any Go run: the gate checks both the module source (no literal at all) and the rendered conf (every colour must be one the palette actually names), and it explicitly diffed the gated conf against home-manager's own output to confirm only the intended lines changed. Correctly flagged the five-vs-six discrepancy and recorded it in the plan doc. Largest diff of any run in the pilot (322 insertions, 4 files) - two new files for the check alone.                                                                                                                                                                                                                                                                                                                                                            |
| `i159-glm-5.3-flash-high-r1` (3f, holdout)            | 159    | glm-5.3-flash        | high        | 1   | pass | pass                               | true       | $0.0420                  | 893s                     | not yet measured | n/a (holdout)                      | 8/8. Includes the explicit no-collision control test the checklist asks for, and empirically survives the unparseable-frontmatter edge case (see the holdout finding above) - a note that will never publish correctly cannot trigger a false collision. Full `nix flake check` (24 checks, all hosts) passes outright - see the review-stage finding for the one gate it can't see.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `i159-deepseek-v4-pro-high-r1` (3f, holdout)          | 159    | deepseek-v4-pro      | high        | 1   | pass | fail                               | true       | $0.3758                  | 866s                     | not yet measured | n/a (holdout)                      | Missing the no-collision control test, and for a real reason: its shelf-check runs before the unparseable-frontmatter filter, so it falsely refuses a vault with no actual collision (reproduced - see the holdout finding above). Self-report claims this case is covered; it is not.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

### Review-stage sub-agent check, 2026-09-08

The one question item 1's original findings deferred to "confirm during the pilot's review stage rather than assuming it": whether `code-review` actually spawns genuinely separate sub-agents under OpenCode, which item 6's whole design leans on. Run once, `pilot-review` against the #159 holdout winner (`i159-glm-5.3-flash-high-r1`). The answer is no, and there is a worse problem underneath it.

**`subagents=0`.** The `task` tool was never called - whatever ran was not the parallel standards-plus-spec pass item 6 assumes.

**The session left its assigned worktree and reviewed a different one instead.** Its own log: it ran `for d in i159-*/; do ...; done` from inside `~/pilot/`, one level above where it was launched, found a sibling worktree (`i159-deepseek-v4-pro-high-r1`), and reasoned - in its own words - that because `i159-glm-5.3-flash-high-r1-review.log` "already has a review log," it would review the sibling instead. That "already has a review log" is the file the shell redirects its own stdout into, which exists as soon as the shell opens it, before the session has written a single line. It mistook its own output file for evidence of prior work, then substituted a different target entirely rather than flag the confusion. Nothing in the guard config stopped it: the permission overlay denies specific destructive commands (`git push`, `git commit`, `gh pr*`, ...), not lateral movement - `bash` and `cd` are otherwise unrestricted, so an agent that reasons its way toward a neighbouring worktree is not contained from reaching it.

**It also reported the `code-review` skill as unavailable** ("only `customize-opencode`") and quietly ran a manual review instead of stopping to say so - a second silent substitution stacked on the first.

**The manual review it produced anyway found something real, independent of which workspace it reviewed.** Both #159 holdout implementations add a new file under `checks/`, and this repo's own CI lint job (`.github/workflows/ci.yml`, "Every flake check is in the matrix") fails the build if a flake check exists that the workflow's matrix doesn't list - which neither implementation's new check is, because the pilot's frozen prompt forbids touching `.github/workflows/` at all. That is not a defect in either model's diff; it is the path denylist (item 2) and the repo's own checks-need-a-matrix-entry convention colliding, for any ticket that adds a new check under `checks/` - which item 5 explicitly names as the established pattern to follow. Confirmed directly: `digital-garden-shelf-collision` is in `nix eval .#checks.x86_64-linux` but absent from the ci.yml matrix on both branches. The full `nix flake check` (24 checks, all hosts) on the holdout winner passes outright - the matrix mismatch is a GitHub Actions lint step, not a Nix-level failure, so this is the one gate `nix flake check` cannot see. **This is a structural finding for item 2 and item 5, not a pilot footnote** - the denylist as currently scoped would block any agent from ever landing a mergeable PR for a ticket that needs a new `checks/*.nix` test, since the one file that must also change is the one file it can never touch.

**Net, as read on the day: item 6 as designed does not hold up under this harness yet.** Before it is built: the runner's review-stage prompt needs an explicit worktree-containment instruction (this is not something the permission overlay currently buys for free), a check that the `skill` tool was actually invoked with `code-review` rather than assumed, and abort-and-report rather than silently-substitute behaviour when a named skill isn't found. And item 2's denylist needs to account for the checks-matrix conflict before item 5 can trust "follow the checks/ pattern" as guidance that can actually pass CI.

**Corrected while building item 6, later the same day: the three failures above are one failure, and it is the harness's, not the model's.** The diagnosis stands as originally written above because the observations are all accurate; the attribution was wrong, and it was wrong in the direction that would have been expensive to believe.

`opencode run` resolves its project - and with it skill discovery - from the directory it is launched in, and `pilot-review` launched it one level above the run's worktree, in `~/pilot`. Everything follows from that single fact:

- **The skill error was real, not a hallucination, and not a compatibility gap.** The export shows `skill` called first, before any other tool, with `{"name":"code-review"}`, erroring with `Skill "code-review" not found. Available skills: customize-opencode`. Reproduced exactly: `opencode debug skill` run in `~/pilot` returns exactly that one built-in skill, because `~/pilot` is not a git repository and holds no `.agents/skills/`. Run in the same run's worktree it returns 26, `code-review` among them; run in a `git worktree add` checkout of this repository, 25. So item 1's original discovery finding was right all along - **nothing needs inlining, and `.agents/skills/` resolves fine through a worktree.**
- **Nothing "left its assigned worktree", because it was never in it.** From `~/pilot` the sibling run directories are simply what is there, and the session picked one. Its "already has a review log" reasoning was it trying to find a target, not abandoning one.
- **`subagents=0` follows from the skill error rather than from a missing capability.** The skill call is what would have told it to fan out, and it failed. `opencode debug agent build` reports `task: true` and `skill: true`, with a native `general` subagent available, so the fan-out was never unavailable.

The fix is one flag - `--dir`, pinning the session to the worktree explicitly instead of inheriting it from a `cd` - and it is what item 6 is built on. The prompt-level containment and skill-verification the paragraph above asked for are worth having anyway and were built too, but as the belt to that braces rather than as the mechanism: `bash` and `cd` are unrestricted whatever `--dir` says, and a stage whose every failure looks like a pass has to be checked from outside.

**What this does not rescue is item 6's premise.** With the harness corrected, the stage was measured properly, and the result is in the finding below. The mechanics were never the interesting question.

### Built, 2026-09-08

**`opencode-go/glm-5.3-flash` at `high`, chosen over `deepseek-v4-pro` and `deepseek-v4-flash`.**

The numbers: across every #178 and #159 run, `glm-5.3-flash` cost $0.036-$0.086 per converged run against `deepseek-v4-pro`'s $0.76-$0.99 (roughly 15-25x) and `deepseek-v4-flash`'s $0.08-$0.29; convergence was 6/6 for `glm-5.3-flash` and `deepseek-v4-pro` against 2/3 for `deepseek-v4-flash` (the noise-calibration pair that started this - see the finding above); the blind pairwise ranking placed `glm-5.3-flash` 1st and 3rd of six real candidates against `deepseek-v4-pro`'s 2nd and 4th and `deepseek-v4-flash`'s last two places; and the holdout, the run designed specifically to catch pattern-matching over reasoning, is where the gap became concrete rather than statistical - `deepseek-v4-pro` shipped a real false-positive bug that its own completion report incorrectly claimed was covered, while `glm-5.3-flash` got the same edge case right. `deepseek-v4-flash` is dropped entirely; `deepseek-v4-pro` is kept on the record as the fallback if `glm-5.3-flash` ever regresses, but nothing in this pilot asked for it.

`high` over `low` or `max`: correctness did not vary across the three on #178 (all three fixed the colour-grammar bug and sourced geometry correctly), so the variant knob acted on scope rather than accuracy - `low` was narrowest but dropped the plan-doc bookkeeping and lost its own mid-run discovery of the five-vs-six discrepancy by the time it wrote its commit message; `max` was most thorough but produced the largest diff of any run in the pilot for a ticket that never needed that much. `high`'s two repeats sit in between and were what both the blind ranking and the holdout were actually run against.

Recurring failure reasons, for item 5's prompt to consume directly:

- **Sourcing the right file is not sourcing a value the target format can parse.** Three separate runs (including a clean, uncontaminated repeat) sourced hyprlock's colours correctly from the shared palette and still shipped a value hyprlock's own config grammar cannot read, because the palette's string format matches its CSS consumers and not this one. Render the actual output and inspect it against the consuming tool's grammar - do not stop at "traces to the right file."
- **An invariant explained correctly in a comment is not the same as an invariant enforced in the right place.** `deepseek-v4-pro`'s holdout run wrote the same reasoning `glm-5.3-flash` did about only-published-notes-can-collide, then placed the check one pass too early anyway. Check placement against the stated boundary, not just the presence of prose explaining it.
- **A self-reported "all covered" is not verification.** The same run's completion report claimed the no-collision case was tested; it never was, and does not hold. Treat a model's own summary of what it verified as a claim to spot-check, not a fact.
- **The reasoning-effort variant reads as a thoroughness dial on this model, not an accuracy dial.** More effort meant more files and more elaborate checks, not more correct output - budget for scope creep at `max`, not for a quality bump.
- **A discrepancy caught mid-run and lost by the final commit message is a real failure mode.** `glm-5.3-flash low` verified "five, not six" literals while testing its own gate, then reverted to "six" in its write-up. Whatever gets asserted about the ticket in the final report should be re-derived from what was actually done, not from what the ticket originally said.
- **Preference signal, not a bug report:** narrow scope and a check that needs no separate script or package (an eval-time throw or a bare `assertions` entry) consistently outranked wider ones that were equally correct - carry this into how the runner's prompt frames "write a build gate" for item 6's review stage to weigh against.

### Off-peak probe: skipped, 2026-09-08

Not run. It only ever tested whether OpenCode Go passes through DeepSeek V4's peak-pricing discount, and the winning arm is not a DeepSeek model - the question has no bearing on the pipeline's actual cost regardless of the answer. Independently confirms the same conclusion the procedure's own metadata read already pointed at (no peak/off-peak field anywhere in Go's catalog, for any model), just from the other direction: the discount question is moot now not because Go lacks the field, but because the chosen model was never in the discount's scope to begin with.

### Cost sustainability, 2026-09-08

The pilot itself spent $7.88 across 17 runs - sunk, not recurring, and worth recording only as a ceiling under everything above. The number that actually matters going forward is `glm-5.3-flash` alone: **$0.28 across its six runs, $0.14 across the four at `high`** (the chosen variant) - $0.006 for the docs-only smoke test, $0.035-$0.054 for the three real implement runs on #178 and #159. Call it **4-6 cents per implement attempt** as the planning number.

Projected onto the real pipeline: a typical ticket (one implement pass, one review pass, both `glm-5.3-flash`) costs on the order of **$0.08-$0.10**; a worst case that burns the full retry budget (item 5's three implement attempts, plus one review and one fix-and-recheck per item 6) costs on the order of **$0.25-$0.30**. Against the $12/5h cap, that is 40-150 worst-case tickets before the rolling window binds - and concurrency is 1 (ADR 0004 §8), with each observed `glm-5.3-flash` run taking 12-30 minutes wall-clock, so the pipeline physically cannot process more than roughly 10-20 tickets in any 5-hour window regardless of cost. At $0.30 each that is $3-6 - comfortably inside the cap with room to spare, and nowhere near the $30/week or $60/month ceilings either.

**No cost-based restriction is needed for `glm-5.3-flash`.** This is a different answer than the one item 10 was written against: its problem statement frames the $12/5h cap as the binding constraint "now justified... rather than by the discount" - true for `deepseek-v4-pro`-level costs (~$0.76-$0.99/run, where the same 5-hour window's worst case would sit close to the cap), false at `glm-5.3-flash`'s. **Item 10 is dropped** on this finding - see its entry below.

### Testing

No automated test — this is a manual spike. The result (model choice, cost/time/quality numbers, the skills-compatibility finding, and the off-peak pass-through answer) gets recorded directly in this file once it is run.

### Done when

A model _and_ reasoning-effort default is chosen with real numbers behind it, the noise-calibration pair either supports or undermines that choice explicitly, the skills-compatibility findings above are confirmed under load rather than only at discovery time, and the recurring failure reasons are written down in a form item 5's prompt can consume.

---

## 2. Triage: AFK eligibility

### The problem

ADR 0004 §5 restricts AFK eligibility with a path denylist, enforced twice, but deliberately does not fix the list. The list is triage vocabulary and lives here and in `docs/agents/afk-eligibility.md`: **`.github/workflows/`, `secrets/`, `.sops.yaml`** - denied regardless of how well-specified the ticket is.

There is a second rule the ADR does not carry, because it is not a path question: an unattended agent may only take a ticket whose success it can determine for itself. A criterion only a human at a screen can judge gives the runner nothing to act on - it either reports a success it cannot justify, or stops for a reason item 8's stuck path cannot tell apart from a real failure.

### Approach

Wherever `ready-for-agent` gets applied today (manually, or by a future triage automation), apply both rules; anything failing either gets `ready-for-human`. Both live in `docs/agents/afk-eligibility.md`, linked from `docs/agents/triage-labels.md` so they travel with the rest of the triage vocabulary.

The two are enforced differently, and the document says so. The denylist binds at three moments - triage, the runner's pre-claim re-check (item 5), and mid-run discovery, which is a stuck-path exit (item 8). Self-verifiability is applied **at triage only**: it is a judgement on ticket prose, and a false rejection at pre-claim time would be indistinguishable from a real bail, so a runner that finds mid-run it cannot tell whether it succeeded takes the stuck path rather than a pre-claim reject.

Self-verifiability is written per acceptance criterion rather than per ticket, splitting criteria into gates (machine-decidable), confirmations (a human looks after the gates pass; cannot change what was built) and judgements (a human decision taken mid-flight, which determines the work). Gates and marked confirmations are fine; a judgement is not. That split is what makes the rule actionable instead of a vibe, and it is what lets a ticket keep a look-and-see criterion - established practice here - without that criterion becoming the agent's success signal.

**Recorded as triage vocabulary, not as an ADR 0004 decision.** ADR 0004 bounds eligibility by paths only. If this rule turns out to carry more weight than vocabulary, it earns its own ADR rather than an amendment to 0004.

### Settled: the checks-matrix conflict, 2026-09-08

Item 1 surfaced a collision this item had to resolve before item 5 could trust "follow the `checks/` pattern" as guidance that can actually pass CI. Adding `checks/foo.nix` also requires adding `foo` to the hand-written matrix in `.github/workflows/ci.yml`, which the denylist forbids; the resulting PR has a correct diff, a passing `nix flake check`, and a red lint job. The matrix is hand-written deliberately (discovery would cost a serialised job ahead of every shard, against the wall-clock budget the sharding exists to protect), so both sides of the collision were deliberate.

Two alternatives were considered and rejected. **Leave it red** and let the reviewer add the matrix line: simple and honest, but an AFK PR that is always red trains the reviewer to ignore red. **Hold the line**, making any check-adding ticket `ready-for-human`: costs the most, since `AGENTS.md` asks for a check whenever observable service behaviour changes.

**Chosen: a narrow mechanical exception.** `ci.yml` may be changed only by adding entries to `jobs.checks.strategy.matrix.check` - no other workflow file, nothing else in `ci.yml`, no entry removed or altered, and every added entry matching `^[a-z][a-z0-9-]*$` and naming a check that exists in `nix eval .#checks.x86_64-linux`. The full statement and its rationale are in `docs/agents/afk-eligibility.md`.

The character class is not decoration. `${{ matrix.check }}` is interpolated directly into a `run:` script, so the entry is shell context rather than data, and Nix attribute names can carry arbitrary characters when quoted - and the agent writes `checks/default.nix` too. "It has to name a real check" is therefore not on its own enough to make the string safe. Found while specifying the exception, not by the pilot.

This is the one place the denylist is not purely path-shaped, and the only one that widens it rather than narrowing it. Recorded as triage vocabulary rather than as an ADR 0004 §5 amendment, on the same footing as the self-verifiability rule; the ADR delegates the denylist's content here, and reversing this would be a text edit rather than a return to its alternatives. Revisit if the denylist's shape is reopened.

### Testing

No automated test while triage stays manual. Once the denylist is enforced in code — the runner's own re-check in item 5 — that's where it becomes a real assertion; see item 5's testing note. Self-verifiability gets no automated assertion at all: it is applied at triage, by a reader.

### Done when

Both rules are written down in one place that a human triaging by hand and the runner's own check (item 5) can reference, and the checks-matrix conflict has a chosen resolution rather than a workaround.

---

## 3. AFK identity (`AFK_AGENT_TOKEN`)

### The problem

A PR needs to be opened and pushed by something other than `GITHUB_TOKEN`, or the required `nixos ci` check never fires and the PR hangs unmergeable - the same trap `flake-update.yml` already routes around with `FLAKE_UPDATE_TOKEN`.

### Approach

An installation token from a GitHub App installed on this repo (ADR 0006; a credential of the runner's own rather than `GITHUB_TOKEN`, and - amending ADR 0004 §4 - an App rather than the fine-grained PAT that clause named, though §4's no-second-account reasoning is upheld, since an App is not a second account). This plan owns the naming the ADR delegates to it: branches it pushes use an **`afk/*`** prefix, and PRs it opens carry an **`afk-agent`** label, giving the same at-a-glance distinction `deps/*` already provides. Both are cosmetic and may be changed here without touching the ADR.

The permission set is this plan's to fix too, and it is the smallest one the runner's verbs need:

| Permission    | Level          | What needs it                                                  |
| ------------- | -------------- | -------------------------------------------------------------- |
| Contents      | Read and write | push the `afk/*` branch, and delete it again afterwards        |
| Pull requests | Read and write | open the PR and label it (item 7)                              |
| Issues        | Read and write | claim by label, comment, relabel (items 5 and 8)               |
| Metadata      | Read-only      | mandatory; GitHub selects it as soon as a repository is chosen |
| Workflows     | Read and write | item 2's `ci.yml` checks-matrix exception - see below          |
| Checks        | No access      | the runner opens a PR and stops - it never reads check status  |

**Workflows is granted, which is what makes item 2's `ci.yml` exception exercisable.** GitHub rejects any push touching `.github/workflows/` from a fine-grained PAT that lacks the permission, so without it the checks-matrix exception in `docs/agents/afk-eligibility.md` could not be used at all: the runner would produce a correct diff and then fail at the push, unattended, with the ticket already claimed.

What it costs is the one enforcement of the denylist that does not depend on the agent behaving. All three of the moments `afk-eligibility.md` names are now the agent checking itself, which promotes the diff check sketched there from an extra to the only control - and it has to run **before the push**. A pushed branch becomes a PR, a PR runs the head branch's workflow with the repository's secrets before anyone reads it, and after the push there is nothing left to gate.

So the ordering constraint moves from the token to the runner: **item 4 does not enable `cg.service.afk-agent.enable` until item 5's pre-push gate exists and its harness covers it.** That is the condition on the first switch-on rather than a preference. Narrowing the permission back to `No access` is an edit in place rather than a re-issued token, so it stays available if the gate proves harder to trust than expected.

### What this token cannot be stopped from doing, 2026-09-08

Item 2 left this question here (`docs/agents/afk-eligibility.md`, rule 1). The answer is that ADR 0004 §9 cannot be a ruleset, and the reason is §4.

`protect-main` requires a pull request and the `nixos ci` check and has an empty bypass list, but its `required_approving_review_count` is `0`. Nothing at GitHub's end stops a PR this token opened from being merged by the same token. Raising the count is not available: §4 rejects a second GitHub account, so an AFK PR is authored by `corygyarmathy`, and GitHub does not let an author approve their own pull request. A count of `1` would deadlock every PR in this repo, human ones included. **The no-second-account decision and ruleset-enforced review are mutually exclusive** - a consequence of §4 to know about, not a gap to close.

What the ruleset does still enforce against this token: it cannot push to `master` at all, cannot force-push or delete it, and cannot merge a PR that is not green and up to date with `master`. What is left is exactly one thing - merging its own green PR - so §9 is a property of the runner's code rather than of the repository. Item 7 opens the PR and stops; nothing in the runner calls `gh pr merge`, with or without `--auto`. That is reviewable rather than enforced, which is why item 5's harness asserts it directly. The `afk-agent` label carries the other half: a merge that did happen is attributable at a glance.

The same shape, one ref over, and a ticket rather than a paragraph: `Contents: write` is repo-wide rather than per-branch, and `protect-deploy` restricts only deletion and non-fast-forward pushes, not who may push, so this token can fast-forward `deploy` directly - as `FLAKE_UPDATE_TOKEN` can today. `afk-eligibility.md` reaches `deploy` the long way round, through a workflow that runs before anyone reads the PR; the short way is open to any credential with write access. Raised as #190, to be answered before item 4 switches the runner on, because it is a question about the deployment gate rather than about this item.

**Answered, 2026-09-09.** `deploy` now restricts updates, and the only actor exempt is CI's `ci-promote-deploy` deploy key ([ADR 0005](../adr/0005-only-a-deploy-key-may-move-deploy.md)). So this token cannot fast-forward `deploy` at all, and neither can `FLAKE_UPDATE_TOKEN` nor the operator's own credential - a fine-grained PAT acts as the repository owner, and the owner is not on the bypass list either. `GITHUB_TOKEN` could not be the exception, which is why the identity is a deploy key rather than the obvious thing: GitHub refuses the GitHub Actions app as a ruleset bypass actor on a user-owned repository, the same organization-only shape as merge queues. What is unchanged is the long way round - the key is a repository secret, and a `pull_request` event runs the head branch's workflow - so `afk-eligibility.md`'s denylist and item 7's pre-push gate are now the only things standing in the only path that remains. Item 4's switch-on no longer waits on this one.

### Corrected, 2026-09-09 (#200)

The section above concludes that "the no-second-account decision and ruleset-enforced review are mutually exclusive". That is wrong, and worth leaving in place with the correction next to it, because it was reasoned twice from the same wrong premise - here, and again in #200's own framing.

§4 was never what blocked it. ADR 0006 tested the instrument against the real API and the obstacle is in GitHub's merge path, not in the account count: an `update` rule over `refs/heads/master` does block a merge, but it blocks it for **every** actor including one on its own bypass list, because a pull request's mergeability is computed for the branch rather than for a viewer. The only way through is the admin override, which also skips `nixos ci`, and auto-merge stops draining entirely - which would take `flake-update.yml`, `dependabot-auto-merge.yml` and `automerge-nudge.yml` with it.

So the conclusion of the section above survives: **ADR 0004 §9 is a property of the runner's code, asserted by item 5's harness, and not something the repository enforces.** Only its reason changes. What the second account does buy is item 12's author filter and item 15's move of the findings into a comment, neither of which needed the ruleset.

One sentence in the `deploy` answer above goes stale with it. "A fine-grained PAT acts as the repository owner, and the owner is not on the bypass list either" covered every token here at once precisely because there was only one account. Once the runner authenticates as a GitHub App that is no longer an argument about it. The conclusion holds for a better reason - `restrict-deploy-updates` exempts only a deploy key, and an App installation is not one - but it is now two facts rather than one, so the runner's credential was checked against `deploy` directly: `gh api repos/{owner}/{repo}/rules/branches/deploy`, under the installation token, still lists `update`.

### Built, 2026-09-08

`AFK_AGENT_TOKEN` exists: a fine-grained PAT named `dotfiles-afk-agent`, scoped to `corygyarmathy/dotfiles` alone, stored as `gh-ci/dotfiles-afk-agent-PAT` in `secrets/homelab01.yaml` - the file homelab01 reads, since homelab01's module is what will declare it (`secrets/README.md`). Not an Actions secret: the runner is a service on a host, not a workflow. It was provisioned by a throwaway wizard that also ran the verification below and cleaned up after itself; the wizard is not kept, because re-issuing a PAT is a browser task either way and the permission table above is the part worth having.

Proven the only way it can be, live. PR #189, opened by the token on `afk/token-smoke-test` and labelled `afk-agent`, ran `nixos ci` to green and was closed again. That is the whole claim: the same PR opened under `GITHUB_TOKEN` would have sat forever with its required check never firing. The narrowing was checked at the same time, from the other side - a private repo the token was not granted returns 404 to it.

### Replaced by an App installation token (#200)

**Partly done.** The identity exists: the GitHub App `corygyarmathy-afk-agent`, App ID `4882603`, installed on `corygyarmathy/dotfiles` alone, carrying the permission table above as its installation permissions. Its bot login is `corygyarmathy-afk-agent[bot]` and its user id is `326868600`, so commits it authors carry `326868600+corygyarmathy-afk-agent[bot]@users.noreply.github.com` - the parameter item 12's filter needs. The private key is in `secrets/homelab01.yaml`.

The key is stored as `gh-ci/afk-agent-app-private-key`, grouped with the other CI credentials in that file rather than at the top level, because `checks/secrets.nix` matches on the name a host declares and the module's declaration has to agree with the file. That is the name `modules/services/afk-agent.nix` should reference.

**The credential swap is done; the revocation is not.** `modules/services/afk-agent.nix` no longer loads a PAT: `credentials` now reads `github-app-key = "gh-ci/afk-agent-app-private-key"`, and the App id sits beside the repository name as an ordinary constant, because it is not a secret - it is in the App's settings URL. `gh-ci/dotfiles-afk-agent-PAT` is still in `secrets/homelab01.yaml` and nothing reads it; `checks/secrets.nix` only fails on a name a host _declares_ and its file lacks, so an orphaned entry passes. Revoking the PAT and dropping that entry is the last step, and it is a browser task.

**The commit identity moved with it, and that was the point.** `commitName` and `commitEmail` were the operator's name and address, so `git log` could not distinguish a commit a person wrote from one generated overnight - the exact ambiguity #200 exists to remove, sitting in the one place a reviewer actually looks. They are now the bot's, with GitHub's noreply shape `<user id>+<login>@users.noreply.github.com`; the id is what makes the address resolve to the App rather than to nobody. `checks/afk-agent-runner.nix` already read the expected author out of the script rather than restating it, so that assertion followed the change without being touched.

**The mint is not a one-off at unit start, and that was the one genuinely new piece of code this cost.** An installation token lives one hour, while `attemptTimeout` is 3600 and `maxRuntime` covers three attempts plus their gates, so the token expires mid-run as the normal case rather than the exceptional one. The JWT is RS256 over `{iat, exp, iss}` with `exp` ten minutes out, signed with `openssl dgst -sha256 -sign`; the installation id comes from `GET /app/installations` under that JWT and the token from `POST /app/installations/{id}/access_tokens`, both through `curl`, since `gh` can only speak as a token that already exists. `openssl` and `curl` joined the toolchain and the preflight's assertions with it.

Two decisions in that code worth naming, because neither is the obvious one:

- **`gh` is a shell function**, `gh() { refresh_gh_token; command gh "$@"; }`, rather than a refresh called at each stage boundary. Every call site then gets a live token without knowing the token has a lifetime, and a stage added later cannot forget. `command gh` keeps the mock the check substitutes in play. The push is the one exception and asks for itself: it borrows the credential through `gh auth git-credential`, which git runs in a shell of its own making that reads `GH_TOKEN` from the environment, so it never passes through the wrapper - and it is the furthest point in a run from the last refresh, which is precisely where a one-hour token would have died.
- **The cache is a file, not a variable.** Most `gh` calls here sit inside `$(...)`; a variable set by the refresh would be set in the subshell and thrown away with it, so the token would be re-minted on every single call rather than once an hour. The file is 0600 under a 0700 `StateDirectory`, and an `EXIT` trap removes it - a token that outlives the run that minted it is a standing credential, which is the property this whole change exists not to have.

The check keeps one seam, `AFK_GH_TOKEN`, because it drives a mocked `gh` against a fixture origin and has no App key to mint from. Everything else about the credential path is under test as written: that the key is required, that the tools are present, and that the push refreshes before it runs.

Both claims under Testing were re-proved under the new identity rather than inherited, on throwaway PR #214. `nixos ci` fires: `event: pull_request`, `triggering_actor: corygyarmathy-afk-agent[bot]`, thirty check runs queued before it was cancelled. And `deploy`'s `update` rule applies to the installation token, which is the ADR 0005 re-check below. The narrowing claim is now structural rather than a property of a scope list: an App installed on one repository has no reach to another, and there is no equivalent of a PAT's repository selector to get wrong.

### Testing

No automated test. Verified once, by hand: open a PR with `AFK_AGENT_TOKEN` and confirm `nixos ci` actually runs against it — the same kind of live, manual verification `deploy-rs` used (deployment-hardening.md item 6), since what's being proven is GitHub's own behaviour, not something a VM test can see.

Two claims, not one, because only the first is visible from the token page. **That it is narrowed:** a _private_ repo it was not granted must 404 for it. A public repo proves nothing - `dotfiles` itself is public, and any token can read public data - so the probe has to be a repo that needs a grant. **That its PRs raise workflow events:** the failure this token exists to prevent is a silent one, a PR waiting forever on a required check that never fires, so the check is that a workflow run exists for the PR's head commit at all.

### Done when

`AFK_AGENT_TOKEN` exists, is scoped to this repo only, and a manual `gh pr create` using it opens a PR that `nixos ci` actually runs against.

---

## 4. `modules/services/afk-agent.nix`

### The problem

Following `AGENTS.md`'s own convention (`cg.service.<name>.enable`), the whole pipeline should be a real, toggleable NixOS service - not a script someone remembers to run.

### Approach

A module on `homelab01` wrapping the poller (item 5) as a systemd service + timer, with `cg.service.afk-agent.enable` as the kill switch. Secrets (item 11) flow in the same way every other service's secrets do.

### Testing

A `pkgs.testers.runNixOSTest` under `checks/`, following the `monitoring`/`reverse-proxy` pattern (deployment-hardening.md item 4): instantiate the module with `cg.service.afk-agent.enable = true` and assert the poller's service and timer units exist and are enabled; instantiate again with `enable = false` and assert they're absent. This is the test that actually proves the kill switch — the module's whole reason for being a real service rather than a script.

If the test needs secrets present to start the service, it follows the existing `checks/stub-secrets.nix` convention — plaintext fixtures swapped in for `sops.secrets.<name>.path`, real values never entering the test.

### Built, 2026-09-08

`modules/services/afk-agent.nix`, `checks/afk-agent.nix`, and `afk-agent.enable = false` written down in `hosts/homelab01/default.nix` - off, per item 3's ordering constraint, and with the two things it is waiting on named at the switch rather than only here.

**The unit is everything around the runner, and the runner is a placeholder.** What this item settles is the schedule, the runtime ceiling, the service account, the credentials, the sandbox, and the toolchain on `PATH`; item 5 replaces one `ExecStart` and updates the check that covers it. Until then the placeholder asserts the plumbing it was handed - three credentials by name, five tools by name - and exits non-zero. Non-zero on purpose: a host that switches this on before item 5 should get a red unit that says why, not a green one that quietly does nothing.

Four decisions worth having written down, because each is a departure from what the rest of this repository does:

- **`Persistent = false`**, alone among the timers here. The others catch up work that had to happen; a poll has nothing to catch up on, and the tickets a missed poll would have found are still open at the next tick. A `Persistent` poller would also start a coding agent the moment a host finished booting - including the reboot at the end of every nightly upgrade.
- **`TimeoutStartSec` is an option (`maxRuntime`, default 4h), not a default.** A `oneshot` unit's start timeout is 90 seconds, which would kill every real run: the pilot measured 15-60 minutes, and item 5 allows two retries on top. The ceiling still has to exist, because concurrency here is one unit and a hung run blocks every later poll until something stops it.
- **Concurrency 1 is systemd's doing, not the runner's.** A single non-templated unit cannot have two live instances, so a poll firing mid-ticket cannot start a second one. Raising it means templating the unit - a deliberate act rather than something item 5 can do by accident.
- **Two hardening exclusions, both named in the module.** `ProtectSystem` is `full` rather than `strict`, because every `nix build` the runner does is a Nix daemon client and connecting to that socket needs write access to an inode under `/nix/var`. `MemoryDenyWriteExecute` is absent because opencode is a JIT'd JavaScript runtime - the same exemption the digital garden dropped when its Node toolchain went away.

**The credentials are handed over with `LoadCredential`**, which systemd reads as root before the unit drops to `afk-agent`. So the three `sops.secrets` declarations carry no `owner`: the sops-nix defaults (root:root 0400) are already right, and there is no per-secret ownership for this module to get wrong. That is also why `checks/afk-agent.nix` uses ordinary store fixtures rather than `private` ones - there is nothing a `private` fixture would catch here.

**The check boots the module both ways**, because "the module evaluates" cannot tell a `lib.mkIf` that guards everything from one that guards half of it. On the enabled node it asserts the timer is armed, that no `.wants` symlink anywhere pulls the service in at boot and that it is still inactive (the timer is its only trigger), that all three credentials and all five tools arrived, and - the one assertion about an absence - that no credential value reached the journal. On the disabled node: no timer, no service, no account, no state directory.

The boot-trigger assertion is written as a `.wants` glob rather than `systemctl is-enabled`, which reports every NixOS unit as `linked` whatever its `[Install]` section says and so cannot tell the two cases apart.

**What is not yet true.** The "Done when" below has two halves, and only the first is satisfied. `enable = false` does fully stop the pipeline - that is what the check proves. "Flipping it back on resumes polling with no other change needed" cannot be true until item 5 exists: flipping it on today gets a red unit that says so. The switch is meant to stay off until then anyway (item 3's ordering constraint), so this is the intended state rather than an oversight - but the item is closed as a scaffold, not as a working poller.

Two departures from the ticket worth recording rather than leaving to be rediscovered:

- **The service is asserted _not_ enabled.** The acceptance criterion asks that "the service+timer exist and are enabled". The timer is enabled; the service deliberately has no `[Install]` section, because a unit that both a timer and `multi-user.target` want would start a coding agent on every boot. So the check asserts the unit exists and that nothing wants it - which is the criterion's intent, inverted on the half where the literal reading would be a bug.
- **`opencode/username` is wired as a third credential.** Item 11 names two. The third was moved into `secrets/homelab01.yaml` alongside the other two by #169 and is declared here so that one place owns the set; if item 5 turns out not to need it, this is where to drop it.

One residual risk, named because item 5 is where it lands: the sandbox has only ever been run against the placeholder. `SystemCallFilter = [ "@system-service" ]` in particular has seen a shell script and nothing else, and a full `opencode run` meeting it for the first time may need a line loosened. `AF_NETLINK` is already in `RestrictAddressFamilies` for the same reason found in review rather than in production - Go and Node both read resolver state over netlink, so `gh` and `opencode` would have failed without it.

### Done when

`cg.service.afk-agent.enable = false` in host config fully stops the pipeline, and flipping it back on resumes polling with no other change needed.

---

## 5. Runner: claim → worktree → implement

### The problem

This is the actual unattended loop: find an eligible ticket, claim it, do the work, without colliding with a human working the same tracker.

### Approach

On each poll:

1. `gh issue list --label ready-for-agent --state open`, filtered to unassigned issues.
2. Re-check the path denylist (item 2) against the ticket's described scope - defense in depth, not trusting the label alone (ADR 0004 §5).
3. Claim it: `gh issue edit <n> --add-assignee @me`, reusing the exact convention `docs/agents/issue-tracker.md` already documents.
4. `git worktree add ../repo-<ticket-slug> -b afk/<ticket-slug>`, per the isolation pattern `AGENTS.md` already establishes for concurrent agent work.
5. Run OpenCode against the ticket body, equivalent to `/implement` (adapted per item 1's finding on skills compatibility) - tests, typecheck, and retries in the same session against a failing result, per ADR 0004 §6. **The retry budget is 2 retries (3 attempts total)**, owned here rather than in the ADR: a retry carries the prior failure as context, and three attempts cannot meaningfully threaten the Go caps. Raise or lower it here if the pilot's cost numbers say otherwise.
6. On success, hand off to item 6. On exhausting retries, or any other reason it can't proceed, hand off to item 8.

**Concurrency is 1** - one ticket in flight, no parallel worktrees. ADR 0004 §8 fixes the principle (serial while the pipeline is unproven); the number lives here, and is the obvious thing to raise once the runner has earned trust and the backlog justifies it.

### Testing

Not a NixOS VM test — this is script logic driving `gh` and `opencode`, neither of which can run inside the Nix build sandbox. A script-level test harness instead, with `gh` and `opencode` mocked: assert the poller only picks up unassigned `ready-for-agent` issues, claims via assignee before touching anything, re-checks the path denylist from item 2 and bails correctly on a ticket that would violate it, accepts a `ci.yml` diff that adds only a well-formed matrix entry while rejecting one that also changes anything else, removes an entry, or adds a name outside `^[a-z][a-z0-9-]*$`, and stops after 2 retries rather than looping indefinitely. It also asserts the absence of a thing: no `gh pr merge` anywhere in the runner's command surface, with or without `--auto`. ADR 0004 §9 is enforced by nothing else - see item 3's finding on why no ruleset can carry it. There's no prior art for this in the repo yet - script-level tests outside `checks/` are new here, so this sets the pattern rather than following one. Items 8 and 10 reuse this same harness rather than inventing their own.

### Built: poll → denylist → claim → isolate, 2026-09-08

The first half of this item, #171. `modules/services/afk-agent.nix` no longer holds item 4's placeholder: its `ExecStart` now polls, re-checks the denylist, claims, and cuts an isolated worktree, then stops and says that the implement stage is #172. `checks/afk-agent-runner.nix` is the harness described above; `checks/afk-agent.nix` keeps proving the plumbing around it.

**The candidate query has a trap in it.** `gh issue list --json blockedBy` returns `{nodes, totalCount}`, and `totalCount` counts every dependency edge including closed ones - #171 itself reports `totalCount: 2` with both blockers closed. So "unblocked" has to be counted from the nodes' `state`, and a reading that trusted the count would work on tickets that never had a blocker and quietly ignore every ticket that ever did. The check pins the distinction with two fixtures identical in `totalCount` and different in state.

**The denylist re-check reads prose, because prose is all there is before a line of code exists.** It matches the three denied paths against the ticket's title and body, and is deliberately biased towards rejecting: a ticket that merely mentions `secrets/` is refused along with one that means to edit it. A false rejection costs one ticket being worked by a human; a false accept is how a workflow edit reaches a branch that runs with the repository's secrets before anybody reads the PR. The consequence worth knowing: this file, `docs/agents/afk-eligibility.md` and ADR 0004 all name the denied paths, so a ticket about the AFK pipeline's own documentation will usually be refused by its own runner.

That also means this check is _not_ the `ci.yml` matrix exception. That one is diff-shaped, cannot be judged from a ticket body at all, and stays where afk-eligibility.md puts it - a pre-push gate, owned by item 7 (#174). The `enable` option's description says so at the switch, where somebody deciding to flip it will read it.

**A rejected ticket is skipped, not relabelled.** A rejection that stopped the poll would let one ineligible ticket block every eligible one behind it, and item 8's stuck path is not the answer either: a ticket refused here was never claimed, so there is nothing to hand back, and commenting on it every poll would be noise about a ticket nobody is working. The skip is cheap and silent, and it is triage that relabels the ticket - which is also why the pre-claim check reads the prose at all: the label a ticket keeps after a silent skip has to be one a human is still looking at.

**Concurrency 1 needed a second half after all.** Item 4 recorded that systemd enforces it, and that is true of two _live_ runs - but says nothing about a run that died: the runtime ceiling, or the kill switch, leaves a worktree on disk and the next poll would happily claim a second ticket beside it. So the runner refuses to start when `worktrees/` is non-empty, and refuses loudly - a red unit every quarter hour, on the grounds that a wedged pipeline should be noisy rather than quiet. Item 8 is what makes it self-clearing; until then the leftover is removed by hand.

**Worktrees are gathered under one directory** rather than dropped beside the checkout as siblings, which is the one departure from `AGENTS.md`'s `../repo-<task-slug>`. The sibling form is for a human's interactive tree; here both the in-flight guard above and item 8's clean-up need to enumerate what is in flight, and a directory they own is how they do that. The branch is cut from `origin/master`, never from whatever the checkout is sitting on, so a tree an earlier run left dirty cannot leak into the next ticket's diff.

**Found by running it, not by reading it: `git worktree add -b <branch> <path> origin/master` sets the new branch's upstream to `origin/master`.** With git's default `push.default` of `simple`, item 7's push would then aim at `master` rather than at the ticket branch. `protect-main` would refuse it, so the failure would have been loud rather than dangerous - but a runner whose push target is correct only because a branch protection rule holds is the wrong shape, so the worktree is cut `--no-track` and the harness asserts the branch has no upstream. Nothing before the push would have noticed.

**An issue title becomes a git ref and a directory name**, so the slug is validated against `^[0-9]+(-[a-z0-9]+)*$` rather than trusted - checked against what is allowed, not against a list of what is not.

**One assertion is about an absence**, and it is the only thing enforcing ADR 0004 §9: the harness greps the runner's whole command surface for `gh pr merge` and for `--auto`. Item 3 established that no GitHub ruleset can carry that decision here - ADR 0004 §4 rules out a second account, so an AFK PR is authored by the person who would approve it, and GitHub does not let an author approve their own PR.

**A second assertion is about drift.** ADR 0004 §5 asks for the denylist twice, and two readings only stay independent while they agree, so the harness compares the runner's own array against rule 1's list in `docs/agents/afk-eligibility.md`. A path added or dropped on one side fails the build rather than silently un-enforcing a control.

**Found in review, and worth recording because reading the code did not show it: `gh issue list` returns newest first.** The query took the first 100 and sorted them ascending, which is oldest-first only while the whole backlog fits in one page - and past that it is precisely the oldest tickets that fall off the end, so the ticket at the front of the queue would have become permanently unreachable at exactly the point a backlog got long enough to matter. Fixed by asking the API for the order (`--search "sort:created-asc"`) rather than sorting the page it chose to send; the local `sort_by` stays, so the ordering holds whatever the API does. The harness now reads the query back out of the mock's log, because a mock that answers whatever it is asked cannot otherwise tell you the runner stopped asking for the label at all.

**The pre-claim check's reach is now pinned by a fixture rather than left implicit.** A ticket that plainly means to edit `ci.yml` but never writes the path - "add a job to the CI matrix" - is claimed, because matching prose is all that is possible before a diff exists. The case asserts that outcome and says in place that it records a limit rather than blessing a bug: if a later change makes it rejected, that expectation is what will say so.

**Nothing here gives a claim back.** Past `gh issue edit`, a failure - an unsafe slug, a clone that fails, a branch that already exists - leaves the ticket assigned, and the assignment is also what filters it out of every later poll. So a failure after the claim is a ticket that quietly leaves the queue. That is item 8's job and is the main reason this half is not enough to switch the service on by itself; it is said at the claim in the runner as well as here.

**Also from review, and fixed rather than argued: `cg.service.afk-agent.repository` was an option nobody set.** One fleet, one value, no consumer - an option like that is a claim about configurability the repository does not honour, so it is a plain binding now.

Proven against deliberate breaks, the way every check here has been: trusting `blockedBy.totalCount`, removing the denylist re-check, moving the claim after the worktree, dropping the in-flight guard, adding a path to the runner that the document lacks, and letting `slugify` stop sanitising. Each failed the harness with a message naming what broke.

**Run by hand against the live tracker, unstubbed, on #171 itself** - the candidate list narrowed to that one ticket so the run could not claim something nobody had chosen, every `gh` call real. It claimed #171, cloned, and cut `afk/171-afk-agent-poll-claim-and-isolate-a-ticket` with a clean tree and no upstream. Then the two halves of "never double-processed": a second poll with the worktree still on disk refused and said why, and a third with the worktree cleared found nothing, because the assignee it had written was now filtering it out. An earlier dry run - real reads, the one write intercepted - went the whole way on the unnarrowed tracker and picked #156, the oldest eligible ticket.

**The sandbox has now met `git` and `gh` for real** - the VM check's run reaches its first `gh issue list` and fails there for want of a network, which is the expected result and is what that assertion now pins. `SystemCallFilter = [ "@system-service" ]` has still never seen an `opencode run`; #172 is where it first does.

### Built: implement, on a bounded retry budget, 2026-09-08

The second half of this item, #172. `modules/services/afk-agent.nix` no longer stops at an empty worktree: it opens an OpenCode session against the ticket, checks the result, and retries inside that same session until it passes or the budget runs out. `opencode-go/glm-5.3-flash` at `high`, three attempts, an hour each - item 1's numbers, carried across as plain bindings rather than options, for the same reason `repository` is one.

**The gate is this repository's own CI gate, not a cheaper proxy.** The pilot ran `nix fmt` plus one host build because it was paying for seventeen runs; a serial runner working one ticket has the opposite trade - an attempt costs cents, and the thing it is buying is a pull request that is not red. So the gate is `nix fmt -- --ci`, `nix flake check`, and a build of every host, with the hosts _discovered_ from the branch under test rather than listed, so a ticket that adds a host is gated on the host it added. CI names them by hand because discovery would cost it a serialised job ahead of a parallel matrix; nothing here is parallel, so nothing here pays for that.

**The checks-versus-matrix audit is in the gate too, and it is the only CI lint step reproduced here.** It is the one gate `nix flake check` cannot see - item 1's review stage found precisely this, on a diff that was otherwise correct - and without it the runner would keep declaring success on branches that go red for a reason the agent could have fixed. The remaining lint step, the `devShells`/`packages`/`apps` evaluation, is not reproduced: it is neither a test nor a typecheck, and nothing has yet gone wrong there. Reproducing a CI step at all can drift from the step it copies; the drift is visible rather than silent, since it surfaces as a branch green here and red on the PR, and there is no way to invoke a GitHub Actions step from outside GitHub Actions.

**Item 11's credential was loaded, asserted, and then never handed to anything.** The unit has read `opencode/api-key` since item 4, and `require_credential` proves it arrives - but opencode reads its providers from a file under its data directory, not from the environment, and the `afk-agent` account has never run `opencode auth login`. The pilot never saw this because it ran as a person who had. So the runner now writes that file, on every run rather than once, so a rotated secret takes effect at the next poll instead of whenever somebody remembers the file exists; the check asserts its shape and then asserts the value is absent from the journal, which is both halves of item 11's "done when". `opencode/username` is still wired to nothing, because nothing on the headless path consumes it - `--username` belongs to `--attach`, which this never uses - and it stays declared rather than dropped on that reasoning alone: item 4 recorded it as an open question, and a credential removed in error is the harder mistake to undo.

**The gate reached for `diff`, which a NixOS unit does not have.** A unit's default path is coreutils, findutils, gnugrep, gnused and systemd; `diffutils` is in none of them and in none of the packages the module already listed. Every attempt of every ticket would have died on "command not found" - and the harness could not have said so, because it ran the script with stdenv's PATH, and stdenv has `diff`. The fix worth recording is not the missing package: **the check now runs the runner under the unit's own evaluated `path`**, taken from the same evaluation the script comes from, plus a directory of mocks to shadow the three binaries that cannot run in a sandbox. A harness that proves the logic and a harness that proves it will run at all are different things, and this one was only the first.

**`checks/afk-agent.nix` reads its expectations out of the script too, now.** It listed the credentials and the tools by hand, so `diff` and `yq` joining the toolchain would have gone unasserted with nothing to say so. It greps `require_credential` and `require_tool` out of the unit's own `ExecStart` instead.

**Found by a check that expected a retry and did not get one: a gate called from `if ! gate` is not running under `set -e`.** Bash switches errexit off inside any command used as a condition, and it stays off all the way down - through the function, through its subshell, past an explicit `set -e` written inside that subshell (verified both ways). The gate as first written therefore ran every step, ignored every failure, and returned the status of its last command: a `for` loop over a host list that the failed discovery step above it had left empty, which is to say success. A gate that passes _because_ everything in it failed is the exact shape of a gate that has stopped gating, and reading the code did not show it - the check did, by asserting a count that came back 1 instead of 2. Every step now ends `|| exit 1` and leans on nothing, and an empty host list is its own explicit failure.

**Four ways an attempt fails, and two of them are not defensive padding.** A non-zero exit and a timeout are obvious. The other two are unattended-specific and both were measured in the pilot: a session that exits 0 having explained what it would do rather than doing it (`commits = 0`, which nothing downstream could tell apart from a ticket that needed no change), and work left in the working tree, which the push in item 7 would silently drop because it pushes commits and nothing else.

**The gate has a deadline, for the same reason an attempt has one.** `attemptTimeout` exists so a stuck attempt fails the runner's own way - countable, retried, about to become item 8's stuck path - rather than by systemd killing the unit mid-ticket. An unbounded gate handed that back: three serial `nix flake check`s and three sets of host builds have no natural bound, so a slow one reaches `TimeoutStartSec` and gets the unit killed anyway. It is one deadline for the whole gate rather than a ceiling per step, because per-step ceilings multiply where a deadline adds, and what has to fit under `maxRuntime` is three attempts _and_ three gates.

**There is one place ADR 0004 §6 does not apply, and it needed saying.** The runner first refused to retry whenever the session could not be read back, on the grounds that a fresh context is the thing the ADR rules out. That is right when a session existed; it is wrong when none did. An attempt that failed before opening one - a transient error on the first call - left no transcript, so the next attempt is not a degraded retry, it is the first real one, and it gets the original prompt. The two are told apart by whether the attempt exited cleanly or committed anything: either means a session existed, so failing to find it is the silent degrade, and the runner stops. Both branches have a case.

**The retry carries one thing across the boundary, and only one.** ADR 0004 §6 asks for a retry inside the failing session; `opencode run --session` is what makes that literal, and the consequence is that almost nothing needs to be handed back - the model already holds its own transcript. What it cannot have seen is the external verdict, so that is what the retry message contains: the reason and the tail of the gate log. If the session id cannot be read back at all the runner stops rather than retrying, because a "retry" in a fresh context is the thing the ADR ruled out, not a degraded version of it.

**ADR 0004 §9's absence-assertion caught the wrong flag, and was narrowed rather than dropped.** The harness grepped the runner's whole command surface for `gh pr merge` _or_ `--auto`, the flag that merges as soon as the checks go green. `--auto` is also `opencode run`'s unattended-approval flag, which an unattended runner cannot work without, so the grep now forbids `gh pr merge` outright and requires every `--auto` in the script to belong to an `opencode` invocation. Worth recording because the assertion was written broadly on purpose and the next stage's legitimate flag walked straight into it - a general prohibition aged into a false positive within one ticket.

**`maxRuntime` moved from 4h to 6h, and then to 7h when item 6 landed**, which is item 4's own guess being corrected twice by the things it was guessing about: three attempts at an hour each with a gate after every one does not fit under four, and adding the review pass's own ceiling brings the total to 5h45m, which left a 6h bound fifteen minutes for a clone, a fetch and everything else that is not one of those. It is the outer bound rather than an expected duration - a run that reaches it is killed mid-ticket and leaves the worktree the in-flight guard then refuses to poll past.

**Both stages pin their session to the worktree with `--dir`, and the implement stage gained that while item 6 was built.** It is recorded here rather than only under item 6 because it changes this stage: opencode resolves its project - and with it which `.agents/skills/` it can see - from the directory it is launched in, so a `cd` alone is load-bearing state that looks like none. Item 1's review-stage run is what that costs when it is wrong, and the correction to that finding is under item 1. A case asserts the flag on both stages. The permission overlays moved the same way, from an `export` that outlived its stage to an assignment scoped to the one command it governs - an inherited deny-set is the same class of ambient state, and the verbs each stage denies are ones a later stage needs.

**The prompt is item 1's frozen pilot prompt plus the two things the pilot found were missing from it.** The `ci.yml` matrix exception, without which "follow the `checks/` pattern" is advice that cannot pass CI; and the recurring failure reasons item 1 recorded specifically for this prompt to consume. It names the `implement` skill explicitly, because item 1 also established that discovery is not invocation - a real session on this repository made 41 tool calls without ever calling the `skill` tool. It lives as a file in the store rather than as anything the script quotes: prose this shape does not survive being a shell literal, and a heredoc's terminator inside a Nix indented string is coupled to Nix's dedent rule, so an edit to the prose can silently reindent the entire script. That is not hypothetical either - it happened once while writing this, and what it broke was the denylist-drift assertion, which reads the runner's array anchored at column 0.

**The prompt grants the `ci.yml` exception; nothing yet verifies the agent honoured it.** That the diff adds matrix entries and changes nothing else is a question about a diff, which item 7 (#174) asks before the push - the gate here only notices a removed entry, because that is the half `nix flake check` disagrees with. Until #174 lands, the only thing standing between the exception and a workflow edit is the prompt and the fact that the service is off, which is what the `enable` option already says. Worth writing down because this change is what opened the door: before it, nothing granted the exception at all.

**What denies the forbidden verbs is the permission overlay, not the prompt.** `git push`, `gh pr`, and the three `gh issue` writes are denied through OpenCode's own config, and the check reads the overlay back out of what the mock actually received rather than grepping the script, so what it asserts is that the guard reached the model. It is still a soft control - a pattern match on a command line, with a PAT that can push sitting in the environment - which is why the `enable` option still says to leave the service off until item 7 (#174) lands the gate that reads the diff.

`checks/afk-agent-runner.nix` gains nine cases and two more mocks. `opencode`'s mock does real work in the worktree - its `broken` step commits a file the `nix` mock refuses to build - because every verdict the runner reaches is read back out of git and out of the gate rather than out of anything opencode printed. The retry cases assert an exact attempt count from both ends: a loop around a paid API that retries until it succeeds has no natural stopping point, and the count is the only thing that tells "still trying" apart from "will never stop". Proven against deliberate breaks: raising the budget to four, letting the retry open a fresh session, retrying blind after a session was lost, removing the fresh-start branch, accepting a run that committed nothing, accepting a dirty tree, accepting a gate that discovered no hosts, dropping each gate step in turn, dropping `diffutils` from the toolchain, handing opencode an empty credentials file, echoing that credential into the journal, dropping the `gh pr*` deny from the overlay, dropping the `ci.yml` exception from the prompt, and putting the gate back on `set -e`. Each failed the harness with a message naming what broke.

**A fourth finding, from setting the live run up: the agent could not have committed anything.** The unit runs with `environment.HOME` pointed at its StateDirectory and sets no XDG variables, so git finds no global config and no `user.email`, and its fallback identity - username at hostname - is refused outright on a host whose hostname carries no domain (`fatal: unable to auto-detect email address (got 'afk-agent@homelab01.(none)')`). Every attempt would have committed nothing, been read as "nothing was committed", and burned the whole three-attempt budget on one error before handing the ticket to the stuck path. The runner now exports `GIT_AUTHOR_*` and `GIT_COMMITTER_*` as `corygyarmathy`, which is the only identity ADR 0004 §4 leaves available anyway - the PR is authored by that person regardless, so the commits inside it may as well match.

The reason the harness did not catch this is worth more than the bug. `checks/afk-agent-runner.nix` set `user.email` globally in the build sandbox's `HOME` while building its fixture origin, and the runner then read that config as ambient. The runs now use a second home carrying the plumbing settings (`init.defaultBranch`, `protocol.file.allow`) without an identity, which is what the unit actually gives them; with the exports removed the harness now fails at the first case that reaches a commit. The same shape - a harness leaving something lying around that production does not provide - is what hid the opencode credential, so it is worth stating as a rule: anything the unit does not set, the harness must not set either.

**Not done here, and the reason it is not.** The live half of this item's acceptance - a real `ready-for-agent` ticket carried the whole way to a commit on an `afk/*` branch - claims a ticket on the shared tracker and spends real budget against a model, so it is an operator's call rather than something to do while writing the code. It is the same by-hand run #171 did, with the candidate list narrowed to one chosen ticket.

Three things only that run can settle, and they are the reason it is not a formality. `SystemCallFilter = [ "@system-service" ]` has still never seen an `opencode run`, which #171 already flagged and this does not change. The credential file written above is asserted here on its shape, never against opencode itself, so "opencode authenticates from it" is a claim this harness cannot make. And the gate's wall-clock is a guess: `gateTimeout` is set generously against a cache CI keeps warm, and whether three gates and three attempts really sit inside `maxRuntime` is a measurement nobody has taken.

### Done when

**Met, across the two pull requests that built it.** A real `ready-for-agent` ticket, run through this loop by hand once, ends with a commit on an `afk/*` branch in an isolated worktree, with the source issue correctly claimed and never double-processed on a second poll.

Demonstrated in two halves rather than one run, which is worth writing down because the "Done when" reads as one: PR #194 ran the poll against the live tracker on #171 itself, claimed it, cut the branch clean, and then proved the guard from both sides - a second poll refused while the worktree stood, and a third found nothing once it was cleared, because the assignee it had written was doing the filtering. PR #195 ran the implement stage under the unit's own `ExecStart`, `PATH` and environment against #178, which converged on the first attempt to a commit on `afk/178-the-lock-screen-is-off-palette`.

The branch from that run was deliberately left unpushed: pushing is item 7's job (#174), and wiring it here would have put a push behind a gate that did not exist yet.

### Superseded in one line, 2026-09-09 (#200)

**Done.** The claim above was `gh issue edit <n> --add-assignee @me`, and ADR 0006 takes that away: the runner authenticates as a GitHub App, and GitHub refuses to assign an App to an issue. The work already done stands - what #194 demonstrated about the guard is still true, it just gets its filtering from a different field. Four places changed, and no more than that:

- `modules/services/afk-agent.nix`, the claim write. `--add-assignee @me` became `--remove-label "$label" --add-label "$working_label"`, in one `gh issue edit` rather than two, so the ticket is never briefly carrying both labels or neither.
- `checks/afk-agent-runner.nix`, the assertion that pins it, now over both flags on one line - plus a second assertion that no `--add-assignee` appears at all, because the first would still pass on a runner that relabelled _and_ tried to assign.
- `docs/agents/issue-tracker.md`, which carries the runner's claim as a clause beside the human one, and `docs/agents/triage-labels.md`, which now defines `agent-working`.
- Item 3's permission table, whose Issues row read "claim by assignee".

**What does not change is the frontier query.** Reading assignees still works perfectly well under an installation token - only the write is refused - so `--label ready-for-agent` plus `select((.assignees | length) == 0)` stays exactly as it is, and a ticket a human has parked on themselves is still skipped. The double-processing guard also keeps its shape: the claim removes the label the query filters on, so a second poll stops seeing the ticket for the same structural reason it used to stop seeing an assigned one.

**One parameter this still leaves open:** when `agent-working` comes off. The assignee never had to be cleaned up, because a closed ticket is out of the query either way. A label is more visible and more likely to go stale, so it wants an owner - most likely item 7, dropping it when the pull request is opened, with item 8's stuck path swapping it for `agent-stuck` instead. `agent-working` and `agent-stuck` both belong in `docs/agents/triage-labels.md` before either ships. (Item 8's half has since landed - #175 - and both labels are documented there; what is still open is only the successful run's half, which stays with item 7.)

---

## 6. Review stage

### The problem

`implement`'s own bolted-on self-review runs in the same context that just wrote the code - the weakest form of review. ADR 0004 §6 calls for a genuinely separate pass.

### Approach

After item 5 succeeds, invoke `code-review` in a fresh session against the same worktree - the existing skill's parallel standards + spec sub-agents, unchanged, and never `--session`. The session is pinned to its worktree with `--dir` rather than a `cd`, which is the whole lesson of item 1's corrected finding above. A failure here does not consume another retry from item 5's budget; it is a new stage with its own outcome.

Three things shape the rest of it, and the third changed after the stage was measured:

- **Report-only is enforced, not requested.** `edit: deny` plus the implement stage's bash denials and `git commit*`, so a review cannot quietly fix what it was meant to report and leave behind a commit nothing reviewed.
- **Nothing believes the session's own account of itself.** Every way item 1 saw this stage fail was silent, so the stage reads the transcript rather than the report: the `skill` tool must have completed a `code-review` call, and the two axes must show up as at least two `task` calls. Both are fatal, fail-closed - a review that cannot be shown to have happened is not a review that passed. The verdict itself is asked for as one fixed line, because a shell script cannot read prose.
- **The skill is unchanged; what it may _decide_ is not.** #173 asks for "its standards + spec parallel sub-agents, unchanged", and `.agents/skills/code-review/` is untouched - both axes run, both report, and both reach the pull request. But the prompt makes the standards axis non-fatal by construction, so half of what the skill produces can never gate. That is a deliberate deviation from the issue's wording and is named here rather than left to be inferred: a reviewer that cannot be trusted to catch a defect must not be trusted to invent one, and the measurement below is the evidence for reading it that way round.
- **No fix-and-recheck.** This item originally allowed one, and it is dropped deliberately. A finding handed back to the model that just wrote the code becomes a commit, and the gate cannot tell a correct change from a plausible green one - so a wrong finding would cost a real edit _and_ consume the finding. Findings are kept whatever the verdict says and travel to the pull request (item 7), where the human who has to merge it reads them beside the diff. A refusal hands the ticket to item 8, never to another attempt. The measurement below is what settled this: on this model a finding is at least as likely to be wrong as right.

### Measured, 2026-09-08

Run properly for the first time - `--dir` pinned, skill named, containment stated, verdict line asked for - against the pilot's own #159 holdout pair, which is the only diff in this repository with an independently graded right answer. Five runs, `glm-5.3-flash` at `high`, $0.0027-$0.0060 and 3-6 minutes each.

The mechanics all work, and every one of item 1's apparent blockers is gone: `subagents=2` on all five runs, the `skill` call completing on all five, no session leaving its worktree, and the verdict line emitted in the requested shape every time.

The findings are another matter.

| Subject                        | Human grading                                                            | Runs | Verdict                |
| ------------------------------ | ------------------------------------------------------------------------ | ---- | ---------------------- |
| `i159-deepseek-v4-pro-high-r1` | fails AC 3: a false positive that refuses a vault with no real collision | 3    | `pass`, `pass`, `pass` |
| `i159-glm-5.3-flash-high-r1`   | passes the holdout cleanly                                               | 2    | `pass`, `fail`         |

**It never caught the defect the holdout exists to expose.** Three runs out of three passed a diff whose check is placed one pass too early. What each did with acceptance criterion 3 is worth recording exactly, because the three runs fail in three different ways and the middle one is the worst:

- One **certified it outright**: "No-collision path behaviorally unchanged (the `hues` line change is whitespace-only)" - the same false claim `deepseek-v4-pro`'s own completion report made, arrived at independently in a fresh context.
- One **found the gap and rationalised it**: "Criterion 3 [...] is verified by absence-of-change plus the existing VM check, not by a dedicated clean-vault assertion in the new check. Defensible." That is the precise observation the human grading started from - the test never exercises the clean case - followed by a decision to wave it through. A reviewer that sees the untested criterion and argues itself out of it is less useful than one that misses it, because the finding was already in hand.
- One **did not mention criterion 3 at all.**

A fresh context removed the self-justification bias and left the capability ceiling exactly where it was: **the reviewer reproduced the implementer's error rather than catching it**, which is the one failure mode a separate pass was supposed to rule out.

**The one thing it did find, twice, is the thing a deterministic check already finds.** The `fail` on the clean implementation is not a false positive - it is correct, independently verified in the run's own words against `ci.yml`'s guard job and line numbers: the new check is missing from the checks matrix. That is the same finding item 1's broken review produced, and it is now caught by item 5's gate, which reproduces that audit directly. So the reviewer's demonstrated yield is a defect the gate sees anyway, and its demonstrated blind spot is the class of defect only a reviewer could see.

Set against item 1's own stated bar - "a review pass that misses what a human found in five minutes is not a review stage" - **this model's review does not clear it.** Recorded plainly because the stage was built anyway, and the reasons it was worth building are not the ones this item started with:

- The **provenance and containment half is deterministic and worth having on its own.** It is what turns "we ran a review" from a hope into a checked fact, and it is the half that would have caught item 1's silent failure on the day.
- The **findings are worth attaching even when the verdict is worthless.** The standards axis reported a real duplication smell across all five runs - the check re-creating the module's filter derivation byte-for-byte - which is a legitimate note for a human reviewer and is not something the gate can see.
- The **cost is genuinely negligible**: about half a cent and four minutes against the implement stage's 4-9 cents and 12-36 minutes, so the stage is roughly a 5% overhead on a ticket and cannot threaten the Go caps.

What is _not_ established, and should not be assumed by item 7 or anything downstream, is that a `pass` from this stage means anything. Treat it as "a review ran, was contained, and produced notes", not as "the diff is correct".

**The open question this leaves:** review costs 10-20x less than implementation, so it is the one stage that could afford a better model than the pipeline's default. `deepseek-v4-pro` is already on the record as the fallback and placed 2nd and 4th in the blind ranking against `glm-5.3-flash`'s 1st and 3rd - but the ranking measured implementation, not review, and the holdout says the two are not the same skill. Settled below.

### Measured again, on `deepseek-v4-pro`, 2026-09-09

The follow-up above, run: same prompt, same guard, same two subjects, same repeat counts, model the only variable. Grading rule written down _before_ the runs (`PREREGISTERED.md` in the run directory), because by this point the expected answer was known and the grader was not disinterested.

Five runs, $0.025-$0.129 each, $0.41 the lot - 15-25x `glm-5.3-flash`, the same ratio the pilot measured on implementation.

| Subject                                 | Runs | Verdicts               |
| --------------------------------------- | ---- | ---------------------- |
| flawed (`i159-deepseek-v4-pro-high-r1`) | 3    | `pass`, `fail`, `pass` |
| clean (`i159-glm-5.3-flash-high-r1`)    | 2    | `pass`, `pass`         |

**On the verdicts alone this looks like a marginal improvement. It is not what happened.**

- **Run 1 found the defect exactly, and passed.** Filed under the `code-review` skill's own category (c), _implemented but questionable_: "Collision detection runs in pass 1, before pass 2 drops notes with unparseable frontmatter, so a `publish: true` note dropped later still registers a shelf - consistent with the pre-existing `taken` URL check, so not a regression." That is the graded defect, named by mechanism, in the right category, and then argued away.
- **Run 2 found it too, and failed for something else.** It described the same bug as "a false-positive refusal", put it under "Minor, non-failing" on the grounds that "over-refusal is what the ticket prefers", and returned `fail` on the `ci.yml` matrix gap instead.
- **Run 3 did not mention it.**

So **2 of 3 runs saw the actual bug and neither gated on it**, where `glm-5.3-flash` went 0 of 3 on seeing it at all. Against the pre-registered rule the letter and the intent disagree, and both are recorded rather than the convenient one: by the letter run 2 is a catch (verdict `fail` _and_ findings naming criterion (ii)), so 1/3; by intent it is 0/3, because the `fail` was not caused by the defect - the defect was explicitly marked non-failing, and without the unrelated matrix gap that run returns `pass`. **The rule was imprecise**: it conflated "the verdict is fail" with "it fails _because of_ the defect", and a rule written to stop the grader moving the goalposts should not have left that gap.

**What this changes is the diagnosis, not the score.** On `glm-5.3-flash` the binding constraint looked like capability - it never saw the thing. On `deepseek-v4-pro` the constraint is the rubric: it sees the thing and declines to gate on it. Those call for different fixes, and only the second one is cheap.

**The rationalisations are not stupid, which is the uncomfortable part.** Both cite something real: the ticket does say a stale site is preferable to one stating something untrue, and the pre-existing `taken` URL check in the same file really does have the same pass-1 ordering. A stricter rubric would have to overrule a model that is reasoning correctly from the repository's own stated preference and its own precedent - so "tighten the rubric" is as likely to convert misses into false positives as into catches. That is the next experiment, and it is a prompt experiment rather than a model one. (Run, 2026-09-09: it converted them into neither. See below.)

**A separate measure of noise, worth more than the verdicts.** The `ci.yml` matrix gap is deterministic, always present, and present on _both_ subjects. It was mentioned in 1 of these 5 runs. `glm-5.3-flash` mentioned it in 2 of its 5. A condition a `grep` finds every time is found by the reviewer about a third of the time - which bounds how much any single `pass` from this stage can mean, on either model.

**Net: do not switch the review stage to `deepseek-v4-pro` on this evidence.** (Superseded 2026-09-09, see "Re-graded on findings quality" below: this conclusion was correct for a stage that gates, and the stage no longer does.) It is 15-25x the cost, it gates no more reliably, and its one `fail` was for a reason item 5's gate already catches. Keep `glm-5.3-flash` for both stages; the recorded reason to revisit is a rubric change, not a model change.

Raw evidence for both arms - the frozen prompt, the pre-registration, the harness, and every run's log and export - is in `~/pilot/review-arm/`, with a README. The plan states the conclusions; that directory is what they rest on.

### The rubric experiment, specified in advance, 2026-09-09

What the finding above leaves. Written out here so it is not re-derived, and so the arms are fixed before anyone sees a result. It has since been run; the results are the section after this one, and this section is left as it was written rather than tidied to match them.

**The claim under test.** The stage fails to gate not because the reviewer cannot see the defect but because the rubric lets it decline. Both `deepseek-v4-pro` runs that found the bug talked themselves out of it, and both cited something true - the ticket's own preference for over-refusal, and a pre-existing `taken` URL check in the same file with the same pass-1 ordering. So the question is whether a rubric can overrule that without simply converting misses into false positives.

**Run it on `deepseek-v4-pro`, not on the pipeline default.** This is the one place the extra cost is justified as an experiment rather than as a setting: a rubric change cannot help a model that never detects the defect, and `glm-5.3-flash` went 0 of 3 on detection. One cheap `glm-5.3-flash` arm is worth adding only to confirm that - a null result there is the control.

**Arms**, each 3 runs on the flawed subject and 2 on the clean one, exactly as before:

- **R2, precedent is not permission.** Add to the fail rubric: behaviour identified as wrong is a fail, and may not be downgraded because a similar pattern exists elsewhere in the repository, or because the ticket is inferred to tolerate it. If the ticket appears to tolerate it, say so _and_ fail.
- **R3, derive the verdict from the skill's own categories.** The `code-review` skill already asks its spec axis for "(c) requirements that look implemented but where the implementation looks wrong". Run 1 filed the defect under exactly that heading and passed anyway. So: any entry under (c) or (a) makes the verdict `fail`, mechanically, with no judgement step between finding and verdict. This is the arm most likely to work and most likely to be noisy, which is why the clean subject matters as much as the flawed one.

**Fix the pre-registration before reusing it.** `~/pilot/review-arm/PREREGISTERED.md` defines a catch as "verdict `fail` AND the findings name the defect", which conflated two things and made one run gradeable both ways. A catch is: **the verdict is `fail` and the stated ground for that verdict includes the defect.** A `fail` whose stated ground is only the `ci.yml` matrix gap is not a catch, on either subject.

**What each outcome means, decided now.**

- A rubric arm that gates on the flawed subject _and_ leaves the clean one passing is the result that reopens the model question, because a review that actually catches things is worth 15-25x when the stage costs cents either way.
- An arm that gates on both subjects has bought false positives, not catches, and makes the stage worse than advisory - a false refusal costs a human a hand-off for nothing.
- No arm gating on the flawed subject retires the idea of review-as-gate on this pipeline. Make the stage advisory: keep the provenance checks and the findings on the pull request, drop the verdict, and reword item 6's first acceptance criterion rather than leaving it open forever.

**Cost:** about $0.80 for both `deepseek-v4-pro` arms, plus a few cents for the `glm-5.3-flash` control. Under a dollar to settle whether this stage can gate at all.

### The rubric experiment, run, 2026-09-09

The section above, executed exactly as it specifies: three arms, `review-prompt.txt` byte-verbatim as the base with only an appended fail rubric, 3 runs on the flawed subject and 2 on the clean one each, 15 runs, $1.01. Every run reached a model call, completed a `code-review` skill call and fanned out to 2 axes; no run was discarded. The corrected catch definition was written down first (`~/pilot/review-arm/PREREGISTERED-RUBRIC.md`): **a catch is a `fail` whose stated ground for the verdict includes the defect**, and a `fail` grounded only on the `ci.yml` matrix gap is not a catch on either subject.

| Arm                                     | Model             | Flawed: catches | Flawed: detected | Clean: false positives | Clean: matrix-gap fails | Cost  |
| --------------------------------------- | ----------------- | --------------- | ---------------- | ---------------------- | ----------------------- | ----- |
| R2, precedent is not permission         | `deepseek-v4-pro` | 0/3             | 2/3              | 0/2                    | 0/2                     | $0.43 |
| R3, verdict from the skill's categories | `deepseek-v4-pro` | 0/3             | 0/3              | **2/2**                | 0/2                     | $0.57 |
| R3 control                              | `glm-5.3-flash`   | 0/3             | 1/3              | 0/2                    | 1/2                     | $0.02 |

**No arm gated the flawed subject. The claim under test is false as stated**: the rubric was not what stood between this stage and a catch.

**R2 changed nothing, and changed it in an interesting way.** The addendum told the reviewer that behaviour identified as wrong is a fail, may not be downgraded for precedent or for an inferred ticket preference, and that if the ticket appears to tolerate it the answer is to say so _and_ fail. Detection held at 2/3 - the same as the un-augmented prompt - and both detecting runs obeyed the first half of that instruction and not the second. Run 1 named the defect by mechanism and by consequence ("a _phantom_ collision ... refusing a build that would have rendered cleanly"), then filed it as "a residual risk rather than a wrong implementation". Run 2 put it under "Two lower-severity gaps (reported, **not the fail driver**)" and failed on the matrix gap instead. Run 3 missed it and praised the placement: "refusal fires in pass 1 before anything is written". A rubric that forbids the specific rationalisation gets a different rationalisation, not a different verdict.

**R3 gated on everything, which is the same as gating on nothing.** Deriving the verdict mechanically from the skill's own spec-axis categories produced `fail` on 5 of 5 runs across both subjects - and 0 catches. Its three fails on the flawed subject were grounded on the matrix gap once and on incidental (c) findings twice; the defect went undetected in all three, less often than under R2. Its two fails on the clean subject are true false positives, grounded on neither the matrix gap nor anything that makes the diff wrong: "AC4 reachability is asserted in comments but not backed by a test", "AC3 'renders exactly as it does today' is only approximated". One of them states "Collision detection itself is correct" and refuses anyway. **This is the plan's second outcome exactly - an arm that gates on both subjects has bought false positives, not catches.**

**The control did its job and revised one earlier conclusion.** `glm-5.3-flash` under the same mechanical rule also failed 3/3 on the flawed subject and caught nothing, confirming that a rubric cannot manufacture a catch out of a model that is not looking. But it detected the defect once - "unparseable-frontmatter notes count toward collisions in pass 1 but drop in pass 2" - where the first arm went 0/3. So `glm-5.3-flash`'s blind spot is not the hard capability ceiling the first "Measured" note read it as. It can surface the mechanism and still rank it beneath a `grep`-findable confound.

**The most useful thing measured here is what the mechanical rule does to a model's own judgement, in the model's own words.** From `r3-glm-flawed-r3`, failing on an (a) entry it had just argued was satisfied: "The entry's own text concedes the criterion is met and the existing VM check covers it, so the human merging this may well judge it acceptable; **the verdict here is applied by the rule, not by re-weighing it.**" That is a gate reporting that it does not believe its own output. A refusal like that costs a human a hand-off and tells them nothing.

**One finding sharpens why the rubric could not work.** Reviewing the _clean_ subject, `r3-pro-clean-r2` invented a pass-ordering false positive against correct code: a note dropped later in the write loop "would still have counted toward a shelf collision". The same reasoning shape as the real defect, on a diff that does not have it. The finding is not tracking the defect; the shape is available on any diff, and a rubric that gates on that shape gates on both subjects. Three separate runs, meanwhile, read the clean subject's ordering correctly and approvingly ("detection ... runs after unparseable notes are dropped"), so the two subjects do differ on exactly the axis the holdout tests - the reviewer's problem is deciding, not seeing.

**Taken with the two arms before it: 15 runs on the flawed subject across five arms - two models and three prompts, 0 catches.** The defect was detected in 5 of those 15 and gated on in none of them. Detection per arm, which is the breakdown the aggregate hides: R1/`glm-5.3-flash` 0/3, R1/`deepseek-v4-pro` 2/3, R2/`deepseek-v4-pro` 2/3, R3/`deepseek-v4-pro` 0/3, R3/`glm-5.3-flash` 1/3. Against item 1's bar - "a review pass that misses what a human found in five minutes is not a review stage" - review-as-gate does not clear it on this pipeline, and the plan's third outcome applies. The stage is now advisory.

**What that changed, 2026-09-09.** `reviewPrompt` no longer asks for `AFK-REVIEW-VERDICT` and tells the review its findings are advisory and read by a person; it asks instead for the closing summary every measured run produced unprompted, naming the worst finding on each axis. The runner drops the verdict grep and its `case`, and with them the only two branches that ended a ticket on a review's opinion. Everything else stands unchanged and still fails closed: the skill call, the two named axes, the containment, the report-only overlay, and a non-empty closing report - that last one still fatal, because the findings are now the entire output of the stage and a review that verifiably ran and then said nothing has left the pull request nothing to carry. `checks/afk-agent-runner.nix` still drives eighteen review runs, and the mock's review flavours lose the three that existed only to police the verdict - `fail`, `noverdict` and the quoted-sentinel decoy. Replacing them: a case asserting a review with a serious finding does _not_ stop the ticket and its findings still reach the file item 7 attaches, and a case asserting the prompt never asks for a verdict. Both were confirmed to fail when the behaviour is removed - the second needed `! grep ... || fail` rather than `grep ... && fail`, which under the check's `set -e` would have aborted on the passing branch and been dead from the day it was written.

**What item 7 must not do with this.** There is no longer a verdict to mistake for a decision, and that is deliberate rather than incidental: a stray `pass` in a findings file attached to a pull request reads to the person merging as a judgement that was made. The findings go on the PR as notes from a contained reviewer, and the deterministic gate (item 5) plus the human are what decide.

Raw evidence: `~/pilot/review-arm/`, alongside the two earlier arms - `PREREGISTERED-RUBRIC.md`, `review-prompt-r2.txt`, `review-prompt-r3.txt`, `probe-rubric.sh`, `results-rubric-arms.tsv`, `GRADING-RUBRIC.md` with the per-run grading, and every run's log and export.

### Re-graded on findings quality, 2026-09-09

The arms all asked "can this stage gate?". It cannot, so the question changed: with the stage advisory, its entire output is notes a person reads, and nothing had measured whether those notes are worth reading. This re-grades the 25 runs already paid for against that question. It costs nothing and it is **weaker evidence than the arms**: no run used the prompt that now ships, model is confounded with prompt, and the cells are n=3. Full working in `~/pilot/review-arm/REGRADE-FINDINGS-QUALITY.md`.

**Accuracy was never the problem.** Nine recurring finding-themes were checked against both subjects' actual source - the ordering defect, empty-slug handling, ragged refusal lines for 3+ colliding folders, the redundant `rel.parent` guard, the duplicated filter assembly, the `hues` reflow, the `ci.yml` matrix gap, `lib` bound-but-unused, the alert-name drift. All nine are true, on both models. **This stage does not invent defects.**

**It vouches for things it did not test, and that is the defect the verdict hid.** On the flawed subject, **9 of 15 runs affirmatively wrote that the criterion the diff breaks is satisfied**. And the part that matters:

> **4 of the 5 runs that detected the defect also certified, elsewhere in the same report, that the criterion it breaks holds.**

A person reading one of those gets the bug and its refutation with nothing to separate them - worse than a report that missed it. Every one of those runs emitted a perfectly well-formed verdict line while doing it, which is why no amount of verdict grading could see it. Fixed at the prompt: the review is now forbidden to write "met", "verified" or "unchanged" for anything it did not run, and invited to say what it left unchecked. Pinned by a case.

**One clean mechanical difference between the models.** Counting each lead session's own tool calls:

|                                                       | `deepseek-v4-pro` | `glm-5.3-flash` |
| ----------------------------------------------------- | ----------------- | --------------- |
| Runs that executed `nix build`/`eval` to test a claim | **8 / 15**        | 2 / 10          |
| Runs using **no tool at all**                         | **0 / 15**        | **4 / 10**      |

Four of ten `glm-5.3-flash` runs wrote a full review report having personally read nothing, run nothing and searched nothing, relaying their sub-agents wholesale.

**And one find nobody else made, including the human grading.** `r2-pro-clean-r1`, reviewing the implementation graded as _correct_: a non-root folder whose leaf slugifies to `""` becomes a live collision key, "reusing the string reserved for 'root, no shelf'". Verified: the clean subject's collision loop skips root notes but has no `if topic:` guard, so two folders that both slugify to nothing are refused as colliding - while the `- {""}` one screen below says `""` cannot collide. **The clean subject over-refuses where the flawed one under-detects, and the holdout's own grading missed it.** One run in twenty-five found it.

**So the review stage moves to `deepseek-v4-pro`, and the earlier "do not switch" is superseded rather than reversed.** That conclusion's stated reason was "it gates no more reliably at 15-25x the cost", and it was correct on its own terms - it just does not survive the stage no longer gating. Review is one pass with no retry budget, which is what makes ~10c affordable where it would not be on implement's three attempts: a ticket goes from 4-9c to roughly 14-19c, still a rounding error against the $12-per-5-hours cap. `model` and `reviewModel` are now separate bindings, and a case fails if a future edit collapses them.

**What this is not evidence for**, and the write-up says so in the module too: that `deepseek-v4-pro` reviews better in general. Detection of the graded defect was 2/3 for it on the base prompt and 0/3 under R3, where `glm-5.3-flash` managed 1/3. Those cells point both ways and are noise. The verification counts are the only part of this that is exact.

**A correction to the arm write-up above.** R3's two clean-subject refusals are recorded there as having "bought false positives". The pre-registered letter scores them that way and that score stands - re-scoring after seeing the code is the goalpost-moving the pre-registration exists to prevent. But the findings underneath are **true**, including `r3-pro-clean-r2`'s pass-ordering claim, described above as invented. It is not: the write loop at `publish-filter.py:884` does drop notes whose link rewriting breaks their frontmatter, and the clean subject's detection runs before it. The accurate diagnosis of R3 is **severity miscalibration, not hallucination** - it refused correct work over true but immaterial observations. That is a different fault with a different fix, and the certification clause above is aimed at the same underlying thing: a reviewer that cannot rank what it found.

### Built, 2026-09-08

`modules/services/afk-agent.nix` gains `reviewPrompt`, `reviewOverlay`, `reviewTimeout` (1800s, an order of magnitude above the 3-6 minutes measured) and `reviewAxes` (2), and the runner gains the stage itself where it previously logged that the stage did not exist. `checks/afk-agent-runner.nix` gains sixteen cases and a review half to its `opencode` mock, which now answers `session list` and `export` as well as `run` and tells the two kinds of `run` apart by their prompt rather than their flags - so a runner that stopped titling its review session fails those cases rather than quietly falling through to the implement path.

Two things in the runner are worth knowing about before editing it:

- **`--dir` is not a stylistic choice.** It is the fix for item 1's corrected finding, and dropping it puts the session back where skill discovery fails and every sibling checkout is in reach. A case asserts it.
- **The verdict grep ends in `|| true`, and that is load-bearing.** `grep` exits 1 when it matches nothing, and an unguarded command substitution in an assignment aborts the script under `set -euo pipefail` - before either branch written to diagnose a missing verdict can print anything. The operator would get a bare non-zero exit and no reason. The same applies to reading the transcript, which is why it is validated with `jq -e .` before anything is read out of it rather than left to abort on the first unguarded read.

### Testing

Automated in `checks/afk-agent-runner.nix`, against the same mocked-`opencode` harness the implement stage uses, extended with a `review` plan per case: eighteen runs covering both acceptance criteria and every failure mode named above - a fresh session rather than a continued one, `--dir` pinned to the worktree, the report-only overlay, findings kept outside the diff, a serious finding _not_ stopping the ticket, a prompt that never asks for a verdict, a missing or wrong skill call, collapsed axes, two sub-agents sent elsewhere, an absent closing report, a timeout, a crash, an unfindable session, an unparseable transcript, and review neither spending nor being spent by the implement budget.

Every one of those was confirmed to fail when the behaviour it asserts is removed from the runner. That discipline has now caught three dead assertions in this stage: two in the first draft, where an unguarded `grep` in a command substitution aborted the script under `set -e` before either branch written to diagnose a missing verdict could run - both branches have since been deleted along with the verdict itself - and one in the advisory rewrite, where `grep ... && fail` would have aborted the check on its own passing branch.

The live half - does a real model catch a real defect - is the finding above, and it is not automatable: it drives an LLM call rather than a VM.

### Done when

**Both criteria are met, and the first one has been reworded rather than met as it stood.** It read: "a deliberately flawed implementation is caught rather than proceeding to PR-raising". It now reads: **a review of every implementation demonstrably ran, was contained and report-only, and left findings on the pull request; the flawed and the clean implementation both proceed, and neither is stopped by the reviewer's opinion of it.** "A clean implementation proceeds through unchanged" holds as it always did, and is tested.

The rewording is the outcome the section above committed to before the arms were run, applied as written. It is not a lowered bar - it is a bar moved off a thing that was measured 15 times and never once happened. Across two models and three prompts, no run ever refused the graded diff _for the defect in it_: the defect was seen in 5 of the 15 and gated on in 0, and the rubric that refused most reliably refused the correct implementation just as often. Keeping "is caught" as a criterion would have meant keeping this item blocked on a property nothing in reach makes true, while shipping a gate whose refusals cost a person a hand-off and, in its own words, were "applied by the rule, not by re-weighing it".

What is built and tested: the stage runs `code-review` in a genuinely separate, contained, report-only context; it proves from the transcript that it did so rather than assuming it; it fails closed on every way that proof can be missing, and on a review that produced no report at all; it keeps the findings for the human who merges; and it never hands a finding back to the model that wrote the code.

What this stage does not do, and no longer claims to: decide whether the diff is correct. That job belongs to item 5's deterministic gate and to the person who merges the pull request. The one defect class this stage's own findings surface at all often is the class a `grep` also finds - the `ci.yml` matrix gap, which is present on every subject, which item 5's gate catches every time, and which the reviewer mentioned in 7 of 25 runs across all five arms.

**Reopen this only on evidence, not on a new model.** The recorded trigger is a review arm that gates the flawed subject _and_ leaves the clean one passing, on the frozen prompt and the same holdout pair. `deepseek-v4-pro` at 15-25x the cost is on the record as not being that, and neither of its two rubrics was either.

---

## 7. Raise the PR

### The problem

This is the step `implement` never does today - nothing currently pushes or opens a PR.

### Approach

Push the `afk/*` branch and open the PR with `AFK_AGENT_TOKEN` (item 3), `afk-agent` labelled, body linking back to the source issue. No auto-merge (ADR 0004 §9) - it lands exactly like any other PR, waiting on human review.

**This item owns the pre-push denylist gate**, and it is the last moment anything can. `docs/agents/afk-eligibility.md` sketches the diff check for the `ci.yml` matrix exception and says why it cannot wait: the push becomes a PR, and a `pull_request` event runs the workflow file _from the head branch_ with the repository's secrets before a human reads it. Item 5's pre-claim check does not cover this - it reads ticket prose, and whether a diff is additions-only to the matrix is a question about a diff that did not exist at claim time. `AFK_AGENT_TOKEN` carries the Workflows permission (item 3) precisely so the exception can be exercised, so nothing at GitHub's end refuses the push either. Run it against `git diff` before the push, and refuse the push rather than the PR.

### Testing

Manual, alongside item 3's verification: the resulting PR should show `nixos ci` running and the `afk-agent` label applied. Nothing to test for auto-merge, since ADR 0004 rules it out entirely for this path.

### Built, 2026-09-09

The runner now ends a successful ticket with a pull request open and nothing in flight. Three things, in this order, and the order is the whole of it: a gate that reads the diff, a push, a pull request.

**The pre-push gate is `push_gate` in `modules/services/afk-agent.nix`**, and it runs immediately before the push rather than as soon as the implement stage converged - which would have been cheaper by one review on a ticket that ends up refused. The review session is denied `edit` by a pattern match on a command line rather than by a capability boundary, so a gate placed before it is a gate something after it can still get past. Ten cents against the fleet is not a trade worth taking. It refuses `secrets/` and `.sops.yaml` outright, refuses every file under `.github/workflows/` except `ci.yml`, and lets a `ci.yml` diff through only when yq makes both sides identical once `jobs.checks.strategy.matrix.check` is deleted, no entry has been removed, and every added entry matches `^[a-z][a-z0-9-]*$` and names a check the flake exposes. The last of those is redundant today - item 5's gate already demands the matrix and the flake's checks agree exactly - and it is kept anyway, because this check is the last one standing between a workflow edit and a run holding the repository's secrets and must not be a reading of another check's homework.

**The push hands its credential to git through `gh`**, as `-c credential.helper='!gh auth git-credential'` with an empty helper ahead of it, so the PAT never reaches `.git/config`, a remote URL, or a command line that `ps` can read. The refspec is explicit (`HEAD:refs/heads/<branch>`) rather than relying on `push.default` or on an upstream item 5 deliberately did not set.

**The body carries the implementer's own words as well as the reviewer's.** The branch's commit messages are quoted into it under a heading of their own, oldest first, before the review section - because a reader who gets only the findings gets someone's critique of a diff they have not been told the shape of. Quoted rather than summarised: a summary would be another paid call producing prose nothing checks, which is the shape item 6 spent 25 runs learning to distrust, and a session summarising its own work is the self-account this pipeline refuses everywhere else. The commit messages are already the one piece of implementer prose that gets audited - the review prompt names a false claim in one as a finding worth the most - so they arrive having been read against the diff.

**The pull request carries the review's findings and a paragraph saying what they are not.** Item 6 left this stage advisory and its findings are the whole of what it produces; the body appends `findings.md` verbatim under a heading that says the review decided nothing, names the two things the 25 measured runs showed it doing badly - certifying criteria it never tested, and never once refusing a diff for the defect in it - and says plainly that no person has read the diff. A reader who takes those findings for an approval is making exactly the mistake dropping the verdict was meant to prevent, so the caveat travels with them rather than living here. The title is the commit's own subject when the branch is one commit, because a squash merge puts it in `master`'s history and the implement stage already wrote it in house style; where a ticket took several attempts no single subject describes the branch, and the ticket's title is the honest answer.

**`HEAD` is pinned across the review stage**, and this one is interim. Report-only is asked for in the prompt and denied in `reviewOverlay`, and neither is a capability boundary - both are pattern matches on a command line, and `git -C . commit` matches neither. The implement stage's own checks run before the review rather than after it, so without the pin a commit the review wrote would be pushed having never been gated, and a clean working tree would not show it. Item 13 opens the pull request before this stage runs, which makes the same guarantee structural and this check dead code to delete. **Done, 2026-09-09**: item 13 landed and the pin is gone; what is left in its place is a log line, because a review session that got past both controls is worth knowing about even when it can no longer do any harm.

**A finished ticket now tears its own worktree down**, which was not in this item's brief and belongs in it anyway: the in-flight guard refuses to poll past any leftover worktree, so a successful run that left one behind would be a pipeline that works exactly once. Item 8 (#175) still owns the same clean-up for a run that _failed_, where there is also a claimed ticket to hand back. The local branch stays - `git worktree remove` leaves it, it costs nothing, and it is what makes the "branch already exists" check refuse a ticket whose pull request is still open. The removal is deliberately not forced: the tree was asserted clean before the gate, the gate writes nothing into it and the review cannot edit, so a removal that fails means something happened none of those allow for, and it is worth being loud about.

`checks/afk-agent-runner.nix` grew fifteen cases for all of it, and two changes underneath them that are worth knowing about. The fixture repository now carries a real `.github/workflows/ci.yml` with a checks matrix, and **`yq` is no longer mocked**: the exception turns entirely on what yq makes of both sides of a `ci.yml` diff, and a mock standing in for it would be the harness agreeing with itself about the one question that matters. The `nix` mock answers the checks eval from `$NIX_CHECKS`, so a case can move the flake's checks and the matrix together - which every ci.yml case has to do, since a diff must pass item 5's gate before it can reach this one.

Two existing cases moved rather than broke, and both moves are honest ones. `mixed` used to assert the shape of the worktree it cut; a run that reaches the push takes its worktree with it, so the isolation assertions moved to a new case that stops before the push, and everything else is now read out of the checkout, which outlives the run. And the assertion that the review stage leaves the working tree clean is no longer an observation: `git worktree remove` without `--force` refuses a dirty tree, so a run reaching a pull request at all is the proof, and it holds in production rather than only in the harness.

### The half of this that only a live run can prove, 2026-09-09

The acceptance criterion is a pull request _opened this way_ showing `nixos ci` actually running, and that cannot be met from a build sandbox. What exists is its two halves, each proven separately:

- **That a PR opened with `AFK_AGENT_TOKEN` runs `nixos ci`** - item 3, live, on PR #189, opened by the token on `afk/token-smoke-test` and closed again once green. That is the claim ADR 0004 §4 rests on and it is settled.
- **That this code path pushes and opens a PR** - the harness, against a fixture origin and a mocked `gh`, including the branch reaching origin at the reviewed commit and nothing reaching it when the gate refuses. The push invocation itself, credential helper and explicit refspec included, was run by hand against `github.com` while raising #174's own pull request.

What is left is the join: the runner, on homelab01, under `AFK_AGENT_TOKEN`, opening one. That happens on the first real ticket after `cg.service.afk-agent.enable` goes true, which is gated on #190 and on item 8 rather than on anything here - so this item is done as code and its "Done when" is carried by the first live run, which is the same shape item 5's was.

### Done when

A PR opened this way shows `nixos ci` actually running (proving the token choice from item 3 works end to end, not just in isolation). **Outstanding, and deliberately so** - see the note above: the code is done and both halves are proven, and the join needs the service switched on.

---

## 8. Stuck path

### The problem

Ambiguous ticket, unfixable failure, missing credential, denylisted scope discovered mid-run - none of these should fail silently.

**Item 13 changed the shape of this**, and the change is worth stating before it is built. This item was written when a failing run could not have produced a pull request; since #201 it can, because the pull request is opened before the review and before CI is watched. So a failure past the push leaves an open pull request, unlabelled, on top of the claimed ticket and the worktree this item was already going to have to clear. ADR 0007 §2 settles that leaving it open is right - it holds real work, and withholding the hand-off label is the signal - but this item now has to reach it: say on the pull request what stopped, as well as on the issue. Before the push nothing has changed, and ADR 0004 §6's "never a PR" still holds there in full.

### Approach

Comment on the issue with what was tried and why it stopped, relabel (`ready-for-agent` → something like `agent-stuck`, added to `docs/agents/triage-labels.md`), and notify (item 9). Where a pull request is already open, comment on that too and leave it open without the hand-off label. No WIP branch left dangling for a run that never pushed - `git worktree remove` cleans up.

### Testing

Same script-level harness as item 5: feed the runner a ticket engineered to fail (an impossible acceptance criterion), and assert it produces the issue comment and relabel, sends a notification (item 9), and leaves no branch or worktree behind afterward.

### Done when

A ticket engineered to fail (an impossible acceptance criterion) ends with a clear comment, the relabel, a notification, and no open PR.

### Built, 2026-09-09 (#175)

Landed as two hand-backs in the runner plus one guard rewrite, all in `modules/services/afk-agent.nix` and pinned by `checks/afk-agent-runner.nix`:

- **`hand_back` is every exit a claimed ticket can take once it has been tried**, in both halves the problem statement above splits: before the push (retry exhaustion, a session that cannot be continued, every denylist refusal on a first push, a failed first push, a pull request that failed to open) and past the push (the CI watch's three no-verdict ends, exhausted rounds, a CI fix that cannot be continued or that failed its round, a failed fix-push, a hand-off that could not be written, every review refusal). Each is one call: the reason goes to the journal and to the ticket as a comment, `agent-working` becomes `agent-stuck` in a single edit (the same one-edit shape the claim uses, so the ticket is never briefly carrying both or neither). The exit stays 1: the hand-back is the designed outcome and it is still a failure somebody has to act on. The relabel deliberately does not re-apply `ready-for-agent` - ADR 0006 §2's text said the stuck path would re-add the claim marker, which is now corrected there and in `docs/agents/issue-tracker.md` (no decision changed; the clause described a mechanism that did not exist yet and would have looped an unfinishable ticket straight round the frontier query).
- **The pull-request half is the part item 13 added.** Past the push the hand-back comments on the pull request with the same story and leaves it open without the hand-off label, which is the whole of what says from outside that nobody has finished with it (ADR 0007 §2); the worktree goes and the branch stays, locally and on origin, because it is what the pull request is made of. A run that pushed and never opened a pull request keeps its branch too, with the comment saying a pull request can be opened from it by hand - the plan's "no WIP branch left dangling" is scoped to a run that never pushed, and pushed work that passed the gate is not destroyed for want of a tracker call.
- **The in-flight guard's other half is `hand_back_dead_run`.** A worktree left by a run that died (killed by `maxRuntime`, or by the kill switch) is no longer a wedge every later poll refuses to start on: the guard reads the ticket number out of the worktree's slug, and the decision item 8 owns here is **tear-down, not resume** - the dead run's prompt, logs and attempt count died with it, and resuming unattended work nobody can vouch for is the shape ADR 0004 §6 exists to prevent. The comment says what is known, which is not much, and says it rather than guessing. Three questions are asked before anything is torn down or written: whether a pull request is open for the branch (a finished run's orphaned worktree - clear it, touch nothing, the ticket is not stuck), whether the dead run's branch reached origin (pushed work is kept, on the same rule as the hand-back past the push; unpushed work and its local branch go), and whether the ticket already carries `agent-stuck` (a hand-back whose teardown failed last poll - finish the teardown, comment nothing twice).
- **Failures before anything is tried unclaim instead.** A failed clone, fetch or worktree cut is infrastructure the ticket did not choose: the claim is undone (`agent-working` back to `ready-for-agent`) and the next poll retries. Handing such a ticket to a human would be wrong, and leaving it `agent-working` would strand it - invisible to the frontier query, and with no worktree behind, invisible to the guard too.

Two things are deliberately not here. The notification is item 9 (#176) and stays there - the "and a notification" half of this item's own Done-when is the only part still open. And when `agent-working` comes off a _successful_ run's ticket remains item 7's open parameter (the finding in item 5), untouched.

One window this leaves open, recorded rather than closed: a run killed in the handful of milliseconds between the claim and the worktree cut leaves a ticket carrying `agent-working` with no worktree behind it - invisible to the frontier query, and with no leftover for the guard to find. Handing that back would mean the poll scanning for `agent-working` tickets and reconciling them against the disk, a new query this item does not owe; the window is the gap between two adjacent shell commands in one run.

The harness grew the plan's own test - three attempts that can never pass the gate, ending in a comment that carries the gate's verdict, the one-edit relabel, and no worktree, branch, push or pull request - plus both halves of the post-push hand-back (the hand-off that fails, and the pull request that never opened), the dead-run guard from both sides (never pushed, and pushed-then-killed, with the branch kept the second way), the open-PR leftover, the duplicate-comment guard, the unidentifiable leftover that stops the run, the comment that fails without stopping the hand-back, and the unclaim. One older case moved rather than broke: the isolation assertions (`isolate`) are now read from a record the `opencode` mock keeps from inside the worktree, because every exit past the isolation - success and every kind of hand-back - tears the worktree down, so nothing survives to be inspected afterward.

### Done when, after #175

A ticket engineered to fail (an impossible acceptance criterion) ends with a clear comment, the relabel, and no open PR - **met, by `checks/afk-agent-runner.nix`**, for the shape the Done-when was written against: a failure before the push. The post-push half item 13 added is met by the same harness - the hand-off that fails and the review that fails leave the pull request open, commented on, and without the hand-off label. The notification waits on item 9 (#176). It no longer waits: #176 landed the same day, and every hand-back - the runner's own and the dead-run guard's - now pushes as it comments and relabels.

---

## 9. Notifications

### The problem

Two things need to reach a human without them polling GitHub themselves: a PR is ready, or the agent got stuck. A third, added during design: OpenCode Go's usage is approaching a cap.

### Approach

Reuse the existing self-hosted ntfy setup and its severity conventions. PR-ready is low-priority/informational; stuck is a step up, since it needs a decision; a usage-cap threshold alert (e.g. 80% of the weekly or monthly Go cap) sits alongside it now that Zen billing is funded.

### Testing

If the AFK alerts route through the existing Alertmanager/ntfy stack, add them as cases to the existing `checks/monitoring.nix` VM test, which already asserts alert routing and severity through `amtool` (deployment-hardening.md item 4) - reuse rather than a new test file. If they're instead sent directly from the runner, it's a script-level assertion in item 5's harness that the right ntfy call fires for each of the three conditions.

### Done when

All three conditions produce a distinguishable ntfy notification, tested by hand once each.

### Built, 2026-09-09 (#176)

Landed as one `notify` verb, one spend ledger, and three call sites in the runner (`modules/services/afk-agent.nix`), pinned by `checks/afk-agent-runner.nix`:

- **They publish straight to ntfy, not through Alertmanager.** These are pipeline events only the runner knows about - a pull request handed over, a ticket handed back, a spend record landing - not metric states for Prometheus to scrape, so wrapping them in an exporter and a recording rule would be machinery in front of a message that is already in hand. The route is the self-hosted server on loopback (ntfy.nix owns the port; the bridge's public base URL would make the runner's own notifications depend on the tunnel standing up, which is what a tunnel alert would be competing with), the same topic the push lane publishes to, and the same access token the bridges publish with (`monitoring/ntfy/alerts-token`, added to the runner's credential set - it is already read by both hosts' bridges, so no new secret exists to mint or rotate). The token reaches curl as a header file under the run's scratch directory rather than as an argument, on the same reasoning that puts the App key on a path: a command line is readable through /proc.
- **Severity follows the push lane's vocabulary, minus the criticals.** PR-ready is `low` - silent, informational, the level warnings get, because nothing is wrong and nothing here is urgent. Stuck and the cap threshold are `default` - a step up, since both need a decision, still short of the `urgent` buzz reserved for fleet criticals, which is what keeps a stuck ticket at 03:00 from buzzing. Distinguishability is title and tag on top of priority: `AFK agent: PR ready for review (#n)` with `white_check_mark`, `AFK agent stuck on #n` with `octagonal_sign`, `OpenCode Go usage at N% of the five-hour cap` with `chart_with_upwards_trend`. Publishing to the same topic rather than a new one was the smallest change and needs no new subscription; a dedicated topic is a one-line change if it ever wants separate muting.
- **The spend ledger is the runner's own accounting, recorded per session, once.** Every paid session's cumulative cost - the implement session (whose CI-fix turns land in it, so the record is taken after the CI watch), the review session (read from the transcript the stage already exported, no second export asked for) - is appended to `usage.tsv` and checked against the caps at that moment. A session is counted once, ever, by a slot file: the hand-back and the success path both try to record the implement session, and the next poll's dead-run guard tries to record a dead run's, and the cumulative number would double-count every time it was read twice. The alert fires on the _crossing_ - the window sum below the threshold before this record, at or above it after - not on the state, which would re-notify on every later record until the window slid. Records older than the longest window are pruned. What it cannot see is said in the alert: only this runner's sessions on this host are counted; interactive use of the same Go account is invisible to it.
- **The caps are the ones item 1 measured** - $12 per rolling five hours, $30 per week, $60 per month, at 80% - read as one spec out of the module so the alert's numbers are the behaviour under test, not fixture values. The windows are rolling rather than aligned to a billing boundary; the error direction (a session's whole cost lands at its last export, so a session spanning a boundary is counted inside the later window) overcounts, which is the safe direction for an alert that says "slow down".
- **Best-effort, everywhere.** A notification that cannot be sent is one line in the unit's journal; a failed export costs a log line and leaves the session's slot unclaimed so a later call can retry it; a failed prune is housekeeping, not a crash. The one thing that _does_ page through the existing stack is a runner that dies outright: `die` leaves the unit failed, which `SystemdUnitFailed` and the journal-tail enrichment already report.
- **The harness asserts the POST, not just the event.** `curl` left the runner's `runtimeInputs` (in production it is on the unit's PATH through the toolchain either way), so `checks/afk-agent-runner.nix` records every notification the way it records `gh` calls: a clean run publishes exactly one, at `low`, carrying the pull request URL; a handed-back ticket publishes exactly one, at `default`; a first session costing $10 against the $12 five-hour cap publishes exactly one cap alert at 83% and nothing else; a publish that fails changes nothing about the hand-back; and the hand-back does not double-count the session its success path already recorded. `awk` joined the toolchain for the window arithmetic, found the way `diff` was: not on a NixOS unit's default path, and invisible to a build sandbox that has it.

With this, item 8's own Done-when ("a comment, the relabel, a notification") is fully met: #175 built the comment and the relabel and left the notification to this item.

The Done-when's "tested by hand once each" remains the human half: the three notifications go to the `alerts` subscription Cory already has, and the first real PR, the first stuck ticket, and the first cap crossing are the live test of the phone's rendering.

---

## 10. Peak-hour scheduling — dropped, 2026-09-08

Proposed to make the poller's systemd timer exclude DeepSeek's weekday peak windows (01:00-04:00, 06:00-10:00 UTC), on two justifications in turn: avoiding DeepSeek V4's 2x peak pricing, and, once item 1 found Go does not pass that discount through, avoiding the $12/5h rolling cap instead. Both were written against a `deepseek-v4-pro`-level cost profile (~$0.76-$0.99/run).

Dropped once item 1 actually finished: the winning model is `glm-5.3-flash`, not a DeepSeek model, so the discount question never applied to it; and at its real measured cost (4-6 cents per implement attempt), item 1's cost-sustainability finding shows the pipeline cannot get near the $12/5h cap regardless of when it runs - concurrency is 1 and a real run takes 12-30 minutes, so a 5-hour window physically fits at most ~10-20 tickets, costing $3-6 worst case. Neither justification survived contact with the model actually chosen, so there is nothing left for this item to protect against. Item 4's timer runs unrestricted; its testing note no longer needs to assert a peak-window exclusion (see item 4). Revisit only if a future model change reintroduces a real per-run cost or a real pricing discount worth chasing.

---

## 11. Secrets

### The problem

`AFK_AGENT_TOKEN` and the OpenCode Go API key need to reach the systemd service on `homelab01` without touching plaintext.

### Approach

SOPS entries alongside the rest of `secrets/`, following the existing convention exactly - no new secrets-handling design needed here.

### Testing

No test of secret content, by design - see item 4's note on `checks/stub-secrets.nix` for how the module test avoids needing real values.

### Done when

The service starts and authenticates using both, with neither value ever appearing in a build log or committed file.

---

## 12. Revision loop: the human's review, back to the agent (#196)

### The problem

The pipeline is one-shot. Item 7 opens a pull request and stops; nothing reads what the human says about it. So the only ways to act on a review comment are to fix the diff by hand or to close the PR and re-file the ticket - and the second throws away a claimed ticket, a worktree and three attempts' worth of context to change one line.

That is a gap rather than a decision. ADR 0004 §9 settles that _merge_ stays a human act; it says nothing about whether the agent may revise its own PR when the human asks it to, and no item covers it.

It is also the point at which item 6's outcome starts to cost something. The review stage is advisory, so the reviewer's notes and the human's notes now arrive in the same place with the same standing, and only one of them can currently be acted on without a person editing files.

### Not the fix-and-recheck this plan already rejected

Item 6 dropped fix-and-recheck deliberately, and this item has to say why it is not that, or it will read as a reversal.

What was rejected: handing **the reviewer's** findings back to the model that wrote the code. The stated objection was that a wrong finding costs a real edit _and_ consumes the finding, and the gate cannot tell a correct change from a plausible green one. Item 6 then measured the reviewer's findings and found the objection well-founded: 15 runs, 0 catches, and refusals grounded on things that were true but immaterial.

What this is: handing **the human's** findings back. The objection does not transfer, because its whole weight rested on the findings being unreliable. A comment written by the person who has to merge the change is the most reliable input in this pipeline, and it is the only input that currently has no path to the code.

The distinction is worth keeping structural rather than trusting prose to hold it: this stage takes review comments from a human account and never the contents of `findings.md`.

### Approach

A second entry point on the same runner, not a new service.

- **Trigger: a label the human applies**, `agent-revise`, rather than the presence of unresolved review threads. A half-written review should not start a run, and a label is the cheapest way to say "I have finished thinking". Added to `docs/agents/triage-labels.md` alongside the others.
- **Resume rather than claim.** The runner's existing path cuts a fresh branch from a fresh worktree; this one re-establishes the worktree at the PR's head branch. That is the real new machinery, and it is where the in-flight guard and the denylist have to be re-derived rather than assumed - the diff being revised is not the diff that was claimed.
- **The comments are the prompt.** Fetched with `gh pr view --json reviews,comments`, threaded, and handed to the implement stage as its instruction, against the same bounded retry budget and the same gate. Nothing else about the implement stage changes.
- **Author filtering is a safety property, not a nicety.** Only comments from accounts other than the agent's own are read. Without it, the agent's own PR body - which carries the advisory review's findings - becomes an instruction to itself on the next pass, which is precisely the loop item 6 refused.
- **The filter is a login comparison, and it works as written since #200.** Drop every comment whose `author.login` is the runner's own, keep the rest. It was unimplementable while ADR 0004 §4 stood, because under one account the set it selects for was empty and the only distinction available was positional - body versus comment. ADR 0006 gives the runner an identity of its own, so the filter now selects the thing it was always described as selecting. The login is `corygyarmathy-afk-agent[bot]`, and it is a parameter rather than a constant - it belongs next to the branch prefix and label above. It cannot be read back from the credential the way a PAT's owner could be: `gh api user` returns `403 Resource not accessible by integration` under an installation token, which carries no user context. Derive it from the App slug the runner already needs in order to mint a token, so that a re-provisioned App changes it in one place rather than silently breaking the filter.
- **A revision budget, the way implement has one.** Three rounds per pull request, then the ticket goes to the stuck path (item 8). A disagreement between a person and a model is otherwise unbounded spend, and the failure mode is not a crash but a slow argument nobody is watching.
- **Push to the same branch, comment on the PR saying what was addressed and what was not.** Never force-push over a commit the human wrote themselves.
- **Re-run the review stage on the revision**, advisory as before. It costs cents and the notes ride along.

### What is deliberately not in scope

- **Resolving review threads.** The agent says what it did; the human decides whether that closed the point. Marking your own homework resolved is the same class of error as the verdict item 6 just removed.
- **Any merge behaviour whatsoever.** ADR 0004 §9, unchanged.
- **Acting on comments from the agent's own account**, including its own PR body.

### Testing

The same mocked-`opencode` harness in `checks/afk-agent-runner.nix`, extended with a `gh pr` half: a PR carrying two human comments produces one implement session whose prompt contains both; a PR whose only comments are the agent's own produces no session at all; the budget stops a fourth round and hands to item 8; a revision that fails the gate consumes a retry and not a round; and the branch is pushed rather than replaced.

The one thing the harness cannot answer is whether the model does what the comment asked, which is the same live half item 6 has, and the same answer: it is a person's judgement on the resulting diff.

### Done when

A pull request this pipeline opened, given a review comment and the `agent-revise` label, comes back with a commit that addresses the comment, a PR comment saying what was addressed, and the branch's own CI green - without a person editing a file.

### Depends on

Item 7 (#174) first: there is no pull request to revise until something opens one. Item 8 (#175) for where an exhausted revision budget goes.

---

## 13. Open the pull request before the review, and watch CI (#201)

### The problem

Item 7 raises the pull request after the review, and that ordering was decided when the review was a gate. Item 6 removed the gate: across 25 runs the stage never once refused a diff for the defect in it, so it advises and decides nothing. Nothing downstream of it depends on it any more, and what is left is an order nobody would choose now.

Two things the current order costs. CI - the only check that runs the real workflow on the real runner - starts last, after a stage whose output no longer decides anything; and the review sits between the gate and the push, where a session that committed would have its commit pushed having never been gated. Item 7 pins `HEAD` across the review against exactly that, which is a check standing in for a structure.

### Approach

Implement, gate the diff, push, open the pull request, watch its checks, feed a red run back into the implement session, then review and write the findings onto the pull request that already exists.

- **The pre-push denylist gate moves with the push** and stays immediately before it, with nothing between them. It is still the only enforcement of `docs/agents/afk-eligibility.md` on the push path.
- **CI becomes the correctness gate and the review becomes a quality pass**, which is what each is good at. The runner's local gate is a reproduction of CI's steps and item 5 already records that it can drift; CI additionally runs what only CI has.
- **A red run is fed back into the implement session** (ADR 0004 §6), on a bounded number of rounds, and pushed to the same branch. Whether a round spends a retry from the budget of three or gets its own is this item's to settle, and `maxRuntime` is already 7h of ceilings.
- **Record what CI catches that the local gate did not.** If the answer is never anything, this stage is latency for its own sake; if it is drift, the drift is worth fixing where it starts.
- **The hand-off label** says CI is green and a review has run. Not `ready-for-human`, which already means "requires human implementation" as an issue triage role and would read as "an agent could not do this" - a new label in the `agent-*` family `agent-stuck` (item 8) and `agent-revise` (item 12) are already forming. It is a signal, not a control: nothing prevents a merge before it is applied.
- **Findings need a home that is not the creation-time body.** Interim: edit the body afterwards, which keeps the body/comment separation item 12 depends on. Item 15 moves them to a comment.

### The decision this needs before code

ADR 0004 §6 ends "never a PR" for a ticket that cannot proceed, and PR-first is in tension with that sentence: a review that cannot be shown to have run no longer means no pull request. Per `docs/agents/domain.md` this earns its own ADR rather than a quiet amendment, the way item 2's rule 2 did. Settle it first.

**Settled, 2026-09-09: [ADR 0007](../adr/0007-the-pull-request-opens-before-the-review.md).** "Never a PR" is narrowed rather than dropped - it still holds everywhere it was aimed, because before the push nothing has created one; what changes is what "can't proceed" means afterwards, which is that the pull request is left open and the signal saying it is finished is withheld. ADR 0004's status line now names the amendment, and §9 is untouched.

### Testing

The same harness, with `gh pr checks` mocked the way `gh issue list` is: a run that goes green first time, one that goes red and is fixed on a retry, one that never goes green and exhausts its rounds, and one where a required check never arrives at all - which has to be told apart from a slow one.

### Built, 2026-09-09

The runner's order is now claim → isolate → implement → denylist gate → push → pull request → watch CI → fix a red run and push it to the same branch → review → write the findings onto the pull request and label it → tear the worktree down. Eight things are worth recording about how it came out.

**The pre-push gate became a function, and that is the whole of §6's enforcement now.** `push_branch` in `modules/services/afk-agent.nix` is `push_gate` followed by `git push` and nothing else, and it is the only thing in the runner that pushes. The old placement argument - it has to sit _after_ the review, which is denied `edit` by a pattern match rather than by a capability boundary - died with the reorder; what replaced it is that a run now pushes more than once, and a CI fix round's push can put a workflow file on a branch that runs with the repository's secrets exactly as the first one could. The harness reads the function itself as well as exercising it, so an edit that puts something between the gate and the push fails there.

**CI is read from the pull request's head commit, not from `gh pr checks`.** `gh pr view --json headRefOid,statusCheckRollup` comes back as one snapshot, so the verdict arrives with the commit it belongs to. That is not fastidiousness: for a window after a fix is pushed, GitHub still reports the _previous_ commit's checks - which, for a round that got this far, are red. A watch that trusted them would spend its second round refusing the fix it had just made, before anything had looked at it. A rollup whose `headRefOid` is not the commit that was pushed reads as "nothing has reported yet", and the harness pins that with a case that answers green on the wrong SHA.

**Both bounds are counted in polls rather than seconds**, and that is what makes them testable. Ten polls with nothing reported for the pushed commit is "CI was never triggered"; forty-five polls without a settle is "it has stopped reporting rather than slowed down"; the interval is 60s and is the one thing the harness overrides. Written as deadlines in seconds, the harness would either have taken three quarters of an hour or would have had to override the numbers too - and then the bound under test would have been the fixture's rather than production's.

**A red run gets its own budget: two rounds, one fix.** The alternative - drawing on the implement stage's three attempts - was rejected in ADR 0007 because the two bound different failures, and a ticket that needed all three attempts is if anything _more_ likely to earn a CI round. Two rather than three because nobody yet knows how often CI is red on a branch this gate already passed; two is the smallest number that lets a red run be fixed at all, and raising it costs an hour of ceiling each and should be paid for with evidence. There is a harness case that spends all three implement attempts and then still gets its CI round, which is that decision pinned in the code.

**A CI fix gets one session and no retry**, which is a deliberate asymmetry with the implement stage. The local gate has already passed on this branch, so a fix that fails it is the model going backwards rather than failing to converge - and unlike the implement stage there is now a pull request a human can pick up, which is most of what a retry budget was buying. The fix is judged by exactly the four checks an implement attempt is, through a shared `attempt_verdict` function rather than a second copy of them, measured against the commit that was pushed rather than against `master`.

**Three ways the watch ends without a verdict about the diff** - the checks never arrived, they never settled, or the run was cancelled - and none of them is fed back to a model, because none of them is something a diff can fix. Each leaves the pull request open without the hand-off label, which is what says from the outside that nobody has finished with it.

**The body is rendered twice over the same path.** At creation time there are no findings and no CI outcome, so the body is the intro plus the branch's own commit messages, and it says in as many words that a missing "Handed over" section means the run has not finished. The hand-off re-renders the whole body with the section in it and writes it with `gh pr edit --body-file` - one call, carrying the label too, so a pull request never carries the label while its body still lacks the findings. Re-rendered rather than appended to, so a CI fix round's commits are in the body's list of what the branch does.

**What CI catches that the local gate did not is logged, on the line that names both.** That is the question ADR 0007 §8 leaves open and this stage exists to answer: if the answer is never anything, this stage is latency for its own sake and should be cut; if it is drift, the drift belongs fixed in the local gate, which is the reproduction. The harness asserts the line is printed on a red run; only live runs can fill in the tally.

`maxRuntime` went from 7h to 9h, and it is still the honest sum of every ceiling underneath it: three attempts and three gates (5h15m), two CI watches (1h30m), one CI fix and its gate (1h45m), one review (30m). Concurrency is one, so that is also how long a hung run can block the pipeline - the reason to keep the numbers small rather than generous.

`checks/afk-agent-runner.nix` grew fifteen cases and two mock verbs. `gh pr view` answers from a per-case plan, one line per poll, repeating its last line once the plan runs out - which is what makes "never settles" a one-word plan rather than forty-five of them - and it takes the SHA it reports from the fixture origin rather than inventing one, so the head-commit check is exercised rather than assumed. Two existing cases changed meaning rather than breaking. The body cases now assert two documents, because the creation-time body is overwritten by the hand-off and the mock keeps a copy of each. And `review-commits` inverted: it used to assert that a commit the review wrote was refused, and now asserts that the ticket finishes and that commit is nowhere near the pull request - a stronger property, because it holds without anything having to notice.

### Left for later, deliberately

- **The tally.** Nothing yet says what CI actually caught. The line is logged; the answer needs live runs.
- **The stuck path (item 8) now has a pull request to reach**, not only an issue. Every failure past the push leaves one open, unlabelled, with a claimed ticket and a worktree behind it.
- **The findings stay in the body** until item 15 (#202) moves them to a comment. The interim `gh pr edit --body-file` was chosen precisely because it keeps the body/comment separation item 12's author filter depends on.

### Done when

A ticket opens its pull request before the review starts, a red CI run comes back green after the agent fixes it, and the hand-off label arrives only once CI is green and the review has run. **Done as code and under the harness; the live half is carried by the first real run**, the same shape items 5 and 7 have - it needs `cg.service.afk-agent.enable` to go true, which is gated on #190 and on item 8.

---

## 14. The runner's own GitHub account (#200)

### The problem

ADR 0004 §4 rejected a second account on the cost of a second set of credentials and 2FA, before any of the pipeline existed. Three things have since turned up that the decision blocks, none of them visible then.

Nothing the agent writes is distinguishable from something the human wrote - both are `corygyarmathy`. Item 12 plans to read "comments from accounts other than the agent's own", and under one account that set is empty, so the filter it calls a safety property cannot be implemented as written. The only distinction that survives today is positional: the body is the agent's, comments are the human's, which is why item 15 has to wait.

The token's ceiling is the owner's role, because a fine-grained PAT cannot exceed the permissions of the account that issued it, and that account is this repository's admin.

And merge stays a human act only because the runner's script does not merge it. Item 3 recorded that no ruleset can carry ADR 0004 §9 here, reasoning from the single account.

### Approach

A distinct identity for the runner, with item 3's permission table unchanged. ADR 0006 settles which one: a GitHub App installed on this repository, rather than the machine account this item first assumed.

The question worth the most is not the one item 3 framed. `required_approving_review_count: 1` is the wrong instrument - the reviewer advises rather than approves, and requiring an approval binds human pull requests too. The right question is whether a ruleset can restrict **who may merge to `master`**, with the human as a bypass actor: the same shape #190 is weighing for `deploy`. If it works, §9 stops being a property of a shell script.

Verify that against the real API before designing around it. This repository has already been bitten by an org-only ruleset feature on a user-owned repo (merge queues, `422 invalid rule 'merge_queue'`).

### Testing

None automated, and for item 3's reason: what is being proven is GitHub's own behaviour. A pull request opened by the new identity must still run `nixos ci`, and the merge-restriction answer must be got from the API rather than from documentation.

### Answered, 2026-09-09

The merge-restriction question is settled, and the answer is no - for a reason that is not the one this item expected. Full evidence in ADR 0006's Verification; the short form:

| Probed against the real API                             | Result                                      |
| ------------------------------------------------------- | ------------------------------------------- |
| `update` rule targeting `refs/heads/master`             | accepted - not another org-only feature     |
| Does it apply to a pull request merge, not just a push? | yes - `mergeable_state: blocked`            |
| Does a `RepositoryRole` bypass actor restore the merge? | **no** - blocked for the bypass actor too   |
| Is there any path through?                              | `--admin` only, which also skips `nixos ci` |
| Does auto-merge still drain?                            | **no** - armed, check green, still blocked  |

A pull request's mergeability is computed for the branch rather than for a viewer, which is why the same rule works on `deploy` (a push, evaluated against the pusher) and not here. Adopting it would cost the CI gate on every human merge and the nightly lock pipeline entirely, so ADR 0004 §9 stays where item 3 put it: in the runner's code, asserted by item 5's harness.

A distinct identity is still worth having, on the two grounds that never depended on the ruleset - item 12's author filter and the permission ceiling. ADR 0006 records both, and settles the identity as a GitHub App.

**Still open:** that the runner's own credential is refused the merge. It is not refused by its permissions - `Contents: write` and `Pull requests: write` are what pushing a branch and opening a pull request need, and they are also what merging needs - so §9 was never going to be enforced by the token. The `--admin` override is separately out of reach, since the installation reports no repository role at all, but that is inference from the permission set rather than an observed refusal.

### Also answered, 2026-09-09: a GitHub App cannot hold the claim (#200)

The identity question was reopened by an observation worth more than the article that prompted it: a GitHub App would _satisfy_ ADR 0004 §4's objection rather than override it. §4 refused a second account because of what a second account drags in - an email address, a 2FA secret, recovery codes - and an App has none of the three. So `corygyarmathy-afk-agent` was created and installed on this repository to test it, and the test was ADR 0004 §3's claim, because §3 uses `gh issue edit <n> --add-assignee @me` as the guard against double-processing and GitHub's REST documentation says an invalid assignee is _silently ignored_. A guard that fails silently is worse than no guard: the symptom is two runners on one ticket rather than an error.

| Probed against the real API                                 | Result                                                                                                                 |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `GET /repos/{repo}/assignees/corygyarmathy-afk-agent[bot]`  | `404`                                                                                                                  |
| `suggestedActors(capabilities: [CAN_BE_ASSIGNED])`          | only `corygyarmathy`                                                                                                   |
| REST `POST /issues/{n}/assignees` naming the bot            | `403 Forbidden`                                                                                                        |
| GraphQL `addAssigneesToAssignable` naming the bot           | `FORBIDDEN` - _"Could not assign agent: `corygyarmathy-afk-agent[bot]` cannot be assigned to issues or pull requests"_ |
| _control:_ the same call naming `corygyarmathy`             | assigned                                                                                                               |
| _control:_ the same call naming a login that does not exist | `200`, assignee silently dropped                                                                                       |

The two controls are the point of the table. The silent-ignore behaviour is real and reproducible, so the failure mode §3 would have to fear does exist - but an App does not hit it. It is refused down a separate path, loudly, by both APIs, and GitHub's own assignable-agent feature is an allowlist a custom App does not inherit.

An App identity therefore cannot use §3's claim as written. The marker has to move to something an App can hold, and the cheapest one already exists: the runner's frontier query is scoped by `ready-for-agent`, so dropping that label _is_ the claim. That leaves the assignee convention in `docs/agents/issue-tracker.md` untouched for humans reading the same tracker, and the stuck path (item 8) hands a ticket back as `agent-stuck` rather than re-applying this label - re-applying it would send an unfinishable ticket straight round the frontier query again.

Two consequences found while checking, recorded before they are forgotten:

- An installation token lives one hour, and `attemptTimeout` is already 3600 with `maxRuntime` covering three attempts plus their gates. The token expires mid-run as the normal case rather than the exceptional one, so reading `GH_TOKEN` stops being a file read and becomes a mint-and-cache with an expiry check.
- Item 12's `gh api user --jq .login` does not work under an installation token, which carries no user context. The login has to come from the App's slug instead - still a parameter, just a differently-sourced one.

**Verified, and the whole App path rested on it:** a pull request opened by an installation token does run `nixos ci`. `GITHUB_TOKEN` suppresses workflow events, and `GITHUB_TOKEN` is itself an installation token - of the `github-actions` App - so the suppression had to be shown to be specific to the default token rather than general to installation tokens, since that suppression is this repository's entire reason for holding a token of its own. A bot-authored commit was pushed under the App and PR #214 opened by it: `NixOS CI` started on `event: pull_request` with `triggering_actor: corygyarmathy-afk-agent[bot]` and thirty check runs queued. The run was cancelled and the branch deleted once the answer was visible.

### Done when

The runner has an identity of its own and a credential minted under it, the old PAT is revoked and out of `secrets/homelab01.yaml`, a pull request it opens runs `nixos ci`, and the merge-restriction question is answered either way and written down.

Three of the four are met. The identity exists and the runner authenticates as it - `modules/services/afk-agent.nix` mints installation tokens from the App key and commits under the bot. PR #214 proved the `nixos ci` trigger. The merge question is answered above, at length, and the answer is no.

What is left is the revocation, and it cannot be done first: `homelab01` runs whatever `deploy` points at, so the PAT has to keep working until this change has actually reached the host. Deploy, watch one poll, then revoke the PAT in the browser and drop `gh-ci/dotfiles-afk-agent-PAT` from `secrets/homelab01.yaml`.

---

## 15. The review's findings become a pull request comment (#202)

### The problem

The findings sit in the pull request body because that is the only place a single GitHub account makes them distinguishable from the human's own review. That is a workaround holding up a safety property in item 12, not a choice about where findings read best.

### Approach

Both of its blockers have landed - item 14 gave the agent its own identity (ADR 0006) and item 13 opened the pull request before the review runs (ADR 0007), which is what leaves a pull request in existence for a comment to attach to. So the findings move to a comment: resolvable, out of the body, and in the same channel item 12 already has to read. The caveat travels with them rather than staying in the body - a reader meeting the findings in a comment must still meet the paragraph saying the stage certified criteria it never tested in 9 of 15 runs.

One comment rather than one per finding: the `code-review` skill's output is prose with no line anchors, so inline comments would be invented positions.

### Testing

The harness, asserting the comment is posted and the body no longer carries the findings; and item 12's filter exercised against a pull request carrying both the agent's comment and a human's.

### Done when

The findings arrive as a comment with the caveat attached, the body still says what the branch does, and item 12 can tell the two apart.
