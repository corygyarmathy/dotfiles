# Plan: the AFK agent pipeline

Status: in progress — item 1 is done (`opencode-go/glm-5.3-flash` at `high`; see its Built note and cost-sustainability finding); item 2 is done (both eligibility rules written down, and the checks-matrix conflict settled with a narrow exception); item 3 is done (the token exists, is scoped to this repo alone, and was proven on a live PR); nothing else has started. Follows [ADR 0004](../adr/0004-afk-agent-runs-self-hosted-with-a-harness-split.md), which covers the architectural decisions (platform, harness split, identity, trigger, retries, kill switch) and the alternatives rejected along the way; this plan is the work items that implement it.

The engineering skills (`.agents/skills/`) already carry a ticket from idea through `to-tickets`, which publishes a GitHub issue labelled `ready-for-agent` per `docs/agents/triage-labels.md`. `implement` already runs `/tdd`, tests, and a self-review, then commits. Everything below starts at the gap right after that: nothing currently claims a `ready-for-agent` ticket unattended, pushes it, opens a PR, or tells anyone.

Item 1 gates the stages that depend on a model choice - item 5's implement step and item 6's review step - because building either around a guess would be the wrong order (ADR 0004 §2 leaves the model deliberately undecided). Items 2, 3 and 4 do not depend on it and can proceed in parallel with the pilot.

| #  | Item                                 | Size   | Status      |
| -- | ------------------------------------ | ------ | ----------- |
| 1  | Measured pilot                       | medium | done |
| 2  | Triage: AFK eligibility              | small  | done        |
| 3  | AFK identity (`AFK_AGENT_TOKEN`)     | small  | done        |
| 4  | `modules/services/afk-agent.nix`     | medium | not started |
| 5  | Runner: claim → worktree → implement | large  | not started |
| 6  | Review stage                         | small  | not started |
| 7  | Raise the PR                         | small  | not started |
| 8  | Stuck path                           | small  | not started |
| 9  | Notifications                        | small  | not started |
| 10 | Peak-hour scheduling                 | small  | dropped     |
| 11 | Secrets                              | small  | not started |

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

The fix is a real, isolated clone per run rather than a worktree: `git clone --no-local --no-tags --single-branch --branch master`, then checkout the pinned baseline onto a new branch. Both flags are load-bearing. `--single-branch --branch master` keeps every ref but master out of view. `--no-local` is easy to miss and just as necessary - a same-filesystem clone otherwise hardlinks the *entire* object store regardless of `--single-branch`, so a run that already had a commit hash could still `git show` it even with the ref hidden; verified by reproducing exactly that before adding the flag. Overhead is about 8 seconds per run, against a 15-60 minute `opencode run` - negligible. `pilot-run` and this document's copy of it are both updated.

**Passing the checklist is not the same as being mergeable, and repeat 1 is the proof.** Repeat 1 scored 8/8 against the checklist below, including "every colour traces to `lib/kanagawa-wave.nix`" - true of the wiring. But the palette's roles are plain `#RRGGBB` strings (correct for the CSS consumers waybar and rofi already use them for), and hyprlock's config grammar is not CSS: its own shipped example config uses only `rgba(...)`/`rgb(...)`, `#` is its comment character, and the rendered `hyprlock.conf` from repeat 1's build reads `check_color=#98BB6C` - a value that almost certainly never parses as a colour at all. `nix fmt` and the host build both passed; the lock screen would very likely still render off-palette. Gate-pass and even a literal spec-pass checklist can both go green on a change that fails the ticket's actual acceptance criterion ("visually matches Kanagawa Wave"), which is exactly why this item weights the subjective "would I merge this" pass as the ground truth rather than the checklist alone. Recorded as a failure reason for item 5's prompt: **sourcing the right file is not the same as sourcing a value the target format can parse - verify against the consuming tool's actual grammar, not just against where the value came from.**

Net effect on the noise-calibration pair: repeat 1 (checklist-passing but likely non-rendering) and repeat 2 (timed out, zero commits) now disagree in a different way than first reported, but they still disagree - which still means arm A's flake rate on this ticket needs a clean third repeat, run under the fixed isolation, before 3c proceeds.

**A clean repeat 3, run after the isolation fix, resolves more than it complicates.** It converged (committed, gate-pass, 7.5/8 on the checklist - the one gap being `rounding`/`outline_thickness` set to the correct numbers as bare literals rather than read from `lib/geometry.nix`, so a future change to item 6's scale would not reach it the way repeat 1's version would), it independently noticed and recorded the "five, not six" literal-count discrepancy that repeat 1 missed, and its architecture is arguably cleaner than repeat 1's (the deployed `hyprlock.conf` is literally the checked derivation's own output, rather than a side-derivation asserted alongside it). But rebuilding its `home-manager-generation` and inspecting the rendered conf shows the **identical** bug found in repeat 1: `check_color=#98BB6C`, bare and unquoted - repeat 3's own completion report even quotes that exact string as evidence the fix worked. Two independently-run, uncontaminated sessions reached the same wrong conclusion the same way, which reframes the finding: this is not per-run noise, it is a systematic blind spot in how this task gets approached - the palette file's roles are correct for the CSS consumers they were built for, nothing in the repo hints they need a different literal form for hyprlock, and neither run rendered its own output to check. It is reasonable to expect arms B-D to make the same miss, since nothing about it is model-specific.

That changes what the third repeat was for. Arm A's real convergence rate across three clean runs is 2/3 (one clean timeout, two clean commits) rather than a coin flip on output quality - the two that converged agree closely, including on the one thing both got wrong. That is enough to stop spending repeats on arm A and move to 3c, on two conditions: **add a fixed, uniform post-build check to the grading procedure** - after every run's host build, extract the rendered `hyprlock.conf` from `home.activationPackage`'s `home-files` output and grep for a colour literal not wrapped in `rgba(...)`/`0x...`, the same way this was caught by hand - so the bug is caught mechanically for arms B-D rather than requiring another manual rebuild-and-inspect; and **record the failure reason for item 5's real prompt** rather than editing this pilot's frozen prompt mid-run: sourcing the right file is not the same as sourcing a value the target format can parse, and a task that touches a Nix-configured surface should render and inspect its own output, not just re-check where the value came from.

### 3c (arms B-D), 2026-09-08

All six runs converged - gate-pass, one commit each, no isolation leaks (checked the same way as arm A's repeats: no run's `branch -a` shows anything beyond its own branch and `master`). That alone is a contrast with arm A's 2/3. Two things came out of grading them against the rendered-conf check the arm-A finding above called for.

**The colour-grammar bug is not universal - it is arm A's.** Every arm-A run that converged (repeats 1 and 3) got it wrong. Of arms B-D: `deepseek-v4-pro` fixed it in repeat 1 (`rgb = colour: "rgb(${lib.removePrefix "#" colour})"`, confirmed in the rendered conf) but *not* in repeat 2, which rendered the identical bare `#98BB6C` arm A produced - so it is not a clean model-tier split, but the cheap arm is now the one with a perfect miss rate rather than a mixed one. `glm-5.3` and `glm-5.3-flash` both fixed it in both repeats, via their own small helper added to `lib/kanagawa-wave.nix` (additions only - nothing existing changed, and `homelab01`'s config still evaluates under each). Revises the earlier "expect every arm to miss this" prediction: three of four arms mostly catch it, and the fourth is not simply "the weak one" - it split 50/50 on its own two repeats.

**A second, genuinely subjective question surfaced: which palette role is "correct" for `check_color`.** The palette has both a `success` role (springGreen) and a `warning` role (roninYellow) and an `info` role (a blue). `deepseek-v4-pro` r1 and both `deepseek-v4-flash` successes used `success`. `glm-5.3` (both repeats) used `info`, with no stated reason. `glm-5.3-flash` (both repeats) used `warning`, and gave one: the *baseline* itself painted this field amber (`rgb(204, 136, 34)`), and `warning` is the role that preserves that association rather than assuming "check-in-progress" means "success." The ticket names no role, so none of these is a checklist failure - but they are exactly the kind of reasoned-versus-arbitrary difference the blind pairwise ranking exists to surface, and `glm-5.3`'s unexplained choice is a weaker answer than either alternative regardless of which one is "right."

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

**Extending 3e to both `low` and `max`, not just `max` as originally scoped.** The written plan called for one run of the winner at `max` (the effort question was "does more reasoning help at all"); run at cost-per-run this low, there's no reason not to also ask "does *less* reasoning still work" - `glm-5.3-flash` supports `low`/`high`/`max`, `high` is already covered by ranks 2 and 4 above, and one run each of `low` and `max` costs and takes about as much as the `high` runs already did. Worth watching once the export lands: repeat 1 above used zero reasoning tokens even at `high` while repeat 2 used 12,443 - if the variant isn't actually changing this model's behaviour much, `low` landing close to `high` would say so directly, which the original one-armed design (`max` only) couldn't have shown.

### Effort variants, 2026-09-08

Both `low` and `max` converged, both fixed the colour-grammar bug, and both correctly sourced geometry from `lib/geometry.nix` - on this ticket, the effort knob did not touch correctness. What it moved was scope, and it moved it a lot: `low` touched one file for 58 insertions and used the plainest check mechanism of any run in the pilot (a bare home-manager `assertions` entry, no script, no package); `high`'s two repeats sat in the middle (150 and 174 insertions, one and three extra files respectively); `max` touched four files for 322 insertions and built a two-sided source-and-output check that comes closer to the Opus reference's rigor than anything else in arm D. Reasoning-token counts back this reading: 0 / 12,443 / 10,789 / 36,678 across high-r1, high-r2, low, max - noisy at the bottom, but `max` is a clear outlier at the top. For this model on this ticket, the effort variant reads less like an accuracy dial and more like a thoroughness dial - worth stating plainly in item 5's prompt rather than assuming "higher effort" means "more correct," since correctness was never actually in question here.

`low` has one real gap `max` does not: it never touched `docs/plans/desktop-design.md`, so item 17's status and build note go unwritten even though the code change itself is sound. Its own log is more interesting than its output here - it verified "five" literals red against the baseline while testing the gate, then reverted to citing "six" in its final commit message, so the discrepancy was noticed and then lost rather than never noticed at all. `max` caught it and kept it, recording it directly in the plan.

Not re-run through the blind-ranking artifact - by this point the ranking has already been unsealed, and re-blinding two more runs from an already-identified winning arm would not remove any bias worth removing. Graded directly instead, the same way the checklist and rendered-conf checks were applied throughout.

### What is still open

Only the first question: whether any Go model produces mergeable output on this codebase's tickets, at what cost, and at what reasoning effort. The rest of this item is the protocol for answering it.

### Approach

**Five arms.** The ADR names two; two is not enough to find the floor, and the leaderboard evidence says the top of the Go range is undifferentiated. Terminal-Bench 2.1 currently places GLM-5.3 at 88.2, Grok 4.6 at 88.4, DeepSeek V4 Pro at 87.9, Kimi K3 at 88.3 and Qwen3.8 Max at 86.6 — five models inside a 1.8-point band, which is smaller than the benchmark's own noise. The useful reading of that is not "they are all equally good", it is "public benchmarks cannot pick the winner here". What separates them on this repo will be harness fit — tool-call reliability across a thirty-turn run, whether the `skill` tool gets called, whether the model stops early — none of which any leaderboard measures.

| Arm | Model                           | Variant | Why it is in                                                                  |
| --- | ------------------------------- | ------- | ----------------------------------------------------------------------------- |
| A   | `opencode-go/deepseek-v4-flash` | `high`  | The cheap default ADR 0004 presumed                                           |
| B   | `opencode-go/deepseek-v4-pro`   | `high`  | The ADR's other named arm                                                     |
| C   | `opencode-go/glm-5.3`           | `high`  | The strong arm; tops the open-weights band and sets a realistic ceiling in Go |
| D   | `opencode-go/glm-5.3-flash`     | `high`  | Three times cheaper than A. If it passes, the budget question stops existing  |
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

| Stage | What                                | Runs      | Scored         |
| ----- | ----------------------------------- | --------- | -------------- |
| 3a    | Smoke test, #167, arms A–D          | 4         | no             |
| 3b    | Noise calibration, #178, arm A × 2  | 2         | yes            |
| 3c    | #178, arms B–D × 2 repeats          | 6         | yes            |
| 3d    | Calibration ceiling, #178, Opus 5   | 1         | no (reference) |
| 3e    | Effort arm, #178, winner at `low` and `max` | 2 | yes            |
| 3f    | Holdout, #159, surviving arms × 1   | up to 4   | yes            |
| —     | Off-peak probe, #167                | 2         | no             |
|       | **Total (original estimate)**       | **20–22** | **13 scored**  |

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

| Run | Ticket | Model | Variant | Rep | Gate | Spec | Skill tool | Cost | Time | Fix-distance | Blind rank | Notes |
| --- | ------ | ----- | ------- | --- | ---- | ---- | ---------- | ---- | ---- | ------------ | ---------- | ----- |
| `i178-deepseek-v4-flash-high-r1` | 178 | deepseek-v4-flash | high | 1 | pass | fail | true | $0.1147 | 986s | not yet measured | 6th of 7 | 8/8 on the written checklist, but the palette's `#RRGGBB` strings are almost certainly unparseable by hyprlock's config grammar (comment char is `#`; its own example config uses only `rgba()`/`rgb()`) - checklist-green, likely non-rendering. See the finding above. |
| `i178-deepseek-v4-flash-high-r2` | 178 | deepseek-v4-flash | high | 2 | fail | fail | true | $0.2918 | 3601s (timeout) | n/a - no commit | pending | Hit the 3600s cap with zero commits. 87 of 117 tool calls were `bash`, spent re-deriving facts (stylix internals, hyprlock colour syntax) instead of converging; never touched `hyprlock.nix`. |
| `i178-deepseek-v4-flash-high-r3` (contaminated, void) | 178 | deepseek-v4-flash | high | 3 | — | — | true | $0.2004 | 1598s | — | **disqualified** | Ran `git log --all` / `git show` and read repeat 1's full committed solution before writing its own - contaminated by the worktree-sharing bug fixed above. Not counted. |
| `i178-deepseek-v4-flash-high-r3` (re-run, isolated) | 178 | deepseek-v4-flash | high | 3 | pass | fail | true | $0.0764 | 829s | not yet measured | 7th of 7 (last) | 7.5/8 on the checklist (radius/border correct value but hardcoded rather than read from `lib/geometry.nix`); correctly flagged the five-vs-six literal discrepancy; kept `path = "screenshot"` with a well-reasoned tradeoff (valid alternative to repeat 1's choice). Same rendered-conf colour bug as repeat 1, independently arrived at - see the finding above. Cheapest and fastest #178 run so far. |
| `i178-opus5-r1` (3d, calibration - not a candidate) | 178 | Claude Code / Opus 5 | interactive | 1 | pass | pass | n/a | not tracked the same way | not tracked the same way | not yet measured | 1st of 7 (reference, not eligible) | Driven by hand, not `--auto`. Fixed the colour-grammar bug (`rgb(FF9E3B)`, confirmed in the rendered conf), and is the only run in the pilot to make `outer_color` track hyprlock's own idle→checking→failed states (`accent`→`warning`→`danger`) rather than a static colour, and to also colour the greeting/clock labels - both outside the ticket's literal scope. Its check validates the *rendered* conf against the palette's actual colour set (four literal syntaxes normalised), not just the module source - the most rigorous of all seven, though it checks colour *identity* against the palette rather than hyprlock's literal *grammar*, so it would not itself have caught the bare-hex bug had Opus produced it. Correctly flagged the five-vs-six discrepancy. A clean diff, not a rough one - so if anything in the checklist still trips on this ticket, that now points at the ticket rather than at the Go models. |
| `i178-deepseek-v4-pro-high-r1` | 178 | deepseek-v4-pro | high | 1 | pass | pass (rendered-colour check added) | true | $0.9885 | 2134s | not yet measured | 3rd of 7 | Diagnosed the colour-grammar bug itself and fixed it: `rgb = colour: "rgb(${lib.removePrefix "#" colour})"`, confirmed in the rendered conf (`check_color=rgb(98BB6C)`). Background changed to `config.stylix.image`, with reasoning. Radius/border correctly read from `lib/geometry.nix`. |
| `i178-deepseek-v4-pro-high-r2` | 178 | deepseek-v4-pro | high | 2 | pass | fail | true | $0.7616 | 2151s | not yet measured | 5th of 7 | Same arm, same ticket, did **not** fix the colour bug this repeat - rendered conf shows bare `check_color=#98BB6C`, identical to arm A's failure. Within-arm inconsistency on the exact question repeat 1 answered correctly. |
| `i178-glm-5.3-high-r1` | 178 | glm-5.3 | high | 1 | pass | fail (wrong role) | true | $3.1050 | 1767s | not yet measured | pending | Fixed the colour-grammar bug via a new `rgb` helper added to `lib/kanagawa-wave.nix` (addition only, no existing values touched; homelab01/02 still evaluate) - rendered conf confirms `rgb(126, 156, 216)`, valid syntax. But mapped `check_color` to `roles.info` (blue) rather than `roles.success` (green), with no stated rationale, when a role named exactly for this purpose already exists. By far the most expensive run of the pilot so far - one run is over a quarter of the $12/5h cap. |
| `i178-glm-5.3-high-r2` | 178 | glm-5.3 | high | 2 | pass | fail (wrong role) | true | $1.7172 | 1022s | not yet measured | pending | Same fix, same `info`-not-`success` choice as repeat 1 (consistent within the arm, unlike deepseek-v4-pro). Still expensive relative to every other arm. |
| `i178-glm-5.3-flash-high-r1` | 178 | glm-5.3-flash | high | 1 | pass | fail (debatable role, justified) | true | $0.0544 | 950s | not yet measured | 2nd of 7 | Fixed the colour-grammar bug (`rgb(FF9E3B)`, hex-compressed, valid). Mapped `check_color` to `roles.warning` (amber) rather than `success`, but with an explicit rationale: the *baseline* itself used amber for this exact field, and `warning` is the role that preserves that. Cheapest run of the entire pilot, arms A-D included. |
| `i178-glm-5.3-flash-high-r2` | 178 | glm-5.3-flash | high | 2 | pass | fail (debatable role, justified) | true | $0.0359 | 719s | not yet measured | 4th of 7 | Same fix and same `warning` choice as repeat 1. Added a small `rgbOf` helper to `lib/kanagawa-wave.nix` (addition only; homelab01 still evaluates). Cheapest and fastest run of the pilot. |
| `i178-glm-5.3-flash-low-r1` (3e) | 178 | glm-5.3-flash | low | 1 | pass | fail (see finding below) | true | $0.0572 | 1666s | not yet measured | not blind-ranked | Correct fix (`rgb(255, 158, 59)`, valid), geometry sourced from `lib/geometry.nix`, `warning` role, background kept with reasoning - and a sixth distinct check architecture: a home-manager `assertions` entry, no separate script or package at all. But never touched `docs/plans/desktop-design.md` - item 17's status and build note are left unwritten - and its own log shows it verified "five" literals red against the baseline, then reverted to "six" in the final commit message anyway. Smallest diff of any converged run (58 insertions, one file). |
| `i178-glm-5.3-flash-max-r1` (3e) | 178 | glm-5.3-flash | max | 1 | pass | pass | true | $0.0859 | 1772s | not yet measured | not blind-ranked | Correct fix (`rgb(FF9E3B)`, valid), geometry sourced, `warning` role, background kept. Closest to Opus's rigor of any Go run: the gate checks both the module source (no literal at all) and the rendered conf (every colour must be one the palette actually names), and it explicitly diffed the gated conf against home-manager's own output to confirm only the intended lines changed. Correctly flagged the five-vs-six discrepancy and recorded it in the plan doc. Largest diff of any run in the pilot (322 insertions, 4 files) - two new files for the check alone. |
| `i159-glm-5.3-flash-high-r1` (3f, holdout) | 159 | glm-5.3-flash | high | 1 | pass | pass | true | $0.0420 | 893s | not yet measured | n/a (holdout) | 8/8. Includes the explicit no-collision control test the checklist asks for, and empirically survives the unparseable-frontmatter edge case (see the holdout finding above) - a note that will never publish correctly cannot trigger a false collision. Full `nix flake check` (24 checks, all hosts) passes outright - see the review-stage finding for the one gate it can't see. |
| `i159-deepseek-v4-pro-high-r1` (3f, holdout) | 159 | deepseek-v4-pro | high | 1 | pass | fail | true | $0.3758 | 866s | not yet measured | n/a (holdout) | Missing the no-collision control test, and for a real reason: its shelf-check runs before the unparseable-frontmatter filter, so it falsely refuses a vault with no actual collision (reproduced - see the holdout finding above). Self-report claims this case is covered; it is not. |

### Review-stage sub-agent check, 2026-09-08

The one question item 1's original findings deferred to "confirm during the pilot's review stage rather than assuming it": whether `code-review` actually spawns genuinely separate sub-agents under OpenCode, which item 6's whole design leans on. Run once, `pilot-review` against the #159 holdout winner (`i159-glm-5.3-flash-high-r1`). The answer is no, and there is a worse problem underneath it.

**`subagents=0`.** The `task` tool was never called - whatever ran was not the parallel standards-plus-spec pass item 6 assumes.

**The session left its assigned worktree and reviewed a different one instead.** Its own log: it ran `for d in i159-*/; do ...; done` from inside `~/pilot/`, one level above where it was launched, found a sibling worktree (`i159-deepseek-v4-pro-high-r1`), and reasoned - in its own words - that because `i159-glm-5.3-flash-high-r1-review.log` "already has a review log," it would review the sibling instead. That "already has a review log" is the file the shell redirects its own stdout into, which exists as soon as the shell opens it, before the session has written a single line. It mistook its own output file for evidence of prior work, then substituted a different target entirely rather than flag the confusion. Nothing in the guard config stopped it: the permission overlay denies specific destructive commands (`git push`, `git commit`, `gh pr*`, ...), not lateral movement - `bash` and `cd` are otherwise unrestricted, so an agent that reasons its way toward a neighbouring worktree is not contained from reaching it.

**It also reported the `code-review` skill as unavailable** ("only `customize-opencode`") and quietly ran a manual review instead of stopping to say so - a second silent substitution stacked on the first.

**The manual review it produced anyway found something real, independent of which workspace it reviewed.** Both #159 holdout implementations add a new file under `checks/`, and this repo's own CI lint job (`.github/workflows/ci.yml`, "Every flake check is in the matrix") fails the build if a flake check exists that the workflow's matrix doesn't list - which neither implementation's new check is, because the pilot's frozen prompt forbids touching `.github/workflows/` at all. That is not a defect in either model's diff; it is the path denylist (item 2) and the repo's own checks-need-a-matrix-entry convention colliding, for any ticket that adds a new check under `checks/` - which item 5 explicitly names as the established pattern to follow. Confirmed directly: `digital-garden-shelf-collision` is in `nix eval .#checks.x86_64-linux` but absent from the ci.yml matrix on both branches. The full `nix flake check` (24 checks, all hosts) on the holdout winner passes outright - the matrix mismatch is a GitHub Actions lint step, not a Nix-level failure, so this is the one gate `nix flake check` cannot see. **This is a structural finding for item 2 and item 5, not a pilot footnote** - the denylist as currently scoped would block any agent from ever landing a mergeable PR for a ticket that needs a new `checks/*.nix` test, since the one file that must also change is the one file it can never touch.

**Net: item 6 as designed does not hold up under this harness yet.** Before it is built: the runner's review-stage prompt needs an explicit worktree-containment instruction (this is not something the permission overlay currently buys for free), a check that the `skill` tool was actually invoked with `code-review` rather than assumed, and abort-and-report rather than silently-substitute behaviour when a named skill isn't found. And item 2's denylist needs to account for the checks-matrix conflict before item 5 can trust "follow the checks/ pattern" as guidance that can actually pass CI.

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

A second fine-grained PAT scoped to this repo, under the existing account (ADR 0004 §4 - a PAT rather than `GITHUB_TOKEN`, and not a separate GitHub account). This plan owns the naming the ADR delegates to it: branches it pushes use an **`afk/*`** prefix, and PRs it opens carry an **`afk-agent`** label, giving the same at-a-glance distinction `deps/*` already provides. Both are cosmetic and may be changed here without touching the ADR.

The permission set is this plan's to fix too, and it is the smallest one the runner's verbs need:

| Permission    | Level          | What needs it                                                  |
| ------------- | -------------- | -------------------------------------------------------------- |
| Contents      | Read and write | push the `afk/*` branch, and delete it again afterwards        |
| Pull requests | Read and write | open the PR and label it (item 7)                              |
| Issues        | Read and write | claim by assignee, comment, relabel (items 5 and 8)            |
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

### Built, 2026-09-08

`AFK_AGENT_TOKEN` exists: a fine-grained PAT named `dotfiles-afk-agent`, scoped to `corygyarmathy/dotfiles` alone, stored as `gh-ci/dotfiles-afk-agent-PAT` in `secrets/homelab01.yaml` - the file homelab01 reads, since homelab01's module is what will declare it (`secrets/README.md`). Not an Actions secret: the runner is a service on a host, not a workflow. It was provisioned by a throwaway wizard that also ran the verification below and cleaned up after itself; the wizard is not kept, because re-issuing a PAT is a browser task either way and the permission table above is the part worth having.

Proven the only way it can be, live. PR #189, opened by the token on `afk/token-smoke-test` and labelled `afk-agent`, ran `nixos ci` to green and was closed again. That is the whole claim: the same PR opened under `GITHUB_TOKEN` would have sat forever with its required check never firing. The narrowing was checked at the same time, from the other side - a private repo the token was not granted returns 404 to it.

### Testing

No automated test. Verified once, by hand: open a PR with `AFK_AGENT_TOKEN` and confirm `nixos ci` actually runs against it — the same kind of live, manual verification `deploy-rs` used (deployment-hardening.md item 6), since what's being proven is GitHub's own behaviour, not something a VM test can see.

Two claims, not one, because only the first is visible from the token page. **That it is narrowed:** a *private* repo it was not granted must 404 for it. A public repo proves nothing - `dotfiles` itself is public, and any token can read public data - so the probe has to be a repo that needs a grant. **That its PRs raise workflow events:** the failure this token exists to prevent is a silent one, a PR waiting forever on a required check that never fires, so the check is that a workflow run exists for the PR's head commit at all.

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

### Done when

A real `ready-for-agent` ticket, run through this loop by hand once, ends with a commit on an `afk/*` branch in an isolated worktree, with the source issue correctly claimed and never double-processed on a second poll.

---

## 6. Review stage

### The problem

`implement`'s own bolted-on self-review runs in the same context that just wrote the code - the weakest form of review. ADR 0004 §6 calls for a genuinely separate pass.

### Approach

After item 5 succeeds, invoke `/code-review` in a fresh context - the existing skill's parallel standards + spec sub-agents, unchanged. A failure here does not consume another retry from item 5's budget; it's a new stage with its own outcome (fix-and-recheck once, or hand off to item 8).

### Testing

Manual, at least initially: run the stage against a deliberately flawed implementation (a clear spec violation, or a subtle bug) and confirm the fresh-context `/code-review` pass catches it before the PR reaches item 7. Same shape as how every `checks/` test in deployment-hardening.md item 4 was proven against a deliberate break — just not automatable the same way here, since this stage drives an LLM call rather than a VM.

### Done when

A deliberately flawed implementation, run through this stage, gets caught by the fresh-context review rather than sailing through on the strength of its own self-check.

---

## 7. Raise the PR

### The problem

This is the step `implement` never does today - nothing currently pushes or opens a PR.

### Approach

Push the `afk/*` branch and open the PR with `AFK_AGENT_TOKEN` (item 3), `afk-agent` labelled, body linking back to the source issue. No auto-merge (ADR 0004 §9) - it lands exactly like any other PR, waiting on human review.

### Testing

Manual, alongside item 3's verification: the resulting PR should show `nixos ci` running and the `afk-agent` label applied. Nothing to test for auto-merge, since ADR 0004 rules it out entirely for this path.

### Done when

A PR opened this way shows `nixos ci` actually running (proving the token choice from item 3 works end to end, not just in isolation).

---

## 8. Stuck path

### The problem

Ambiguous ticket, unfixable failure, missing credential, denylisted scope discovered mid-run - none of these should produce a PR, and none should fail silently.

### Approach

Comment on the issue with what was tried and why it stopped, relabel (`ready-for-agent` → something like `agent-stuck`, added to `docs/agents/triage-labels.md`), and notify (item 9). No draft PR, no WIP branch left dangling - `git worktree remove` cleans up.

### Testing

Same script-level harness as item 5: feed the runner a ticket engineered to fail (an impossible acceptance criterion), and assert it produces the issue comment and relabel, sends a notification (item 9), and leaves no branch or worktree behind afterward.

### Done when

A ticket engineered to fail (an impossible acceptance criterion) ends with a clear comment, the relabel, a notification, and no open PR.

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
