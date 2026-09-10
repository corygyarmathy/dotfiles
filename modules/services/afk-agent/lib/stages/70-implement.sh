# shellcheck shell=bash
# ADR 0004 §6: a retry happens *inside* the session that produced the
# failure, because a retry that cannot see what it is retrying against is
# close to useless. `opencode run --session` is what makes that literal.
# The model keeps its own transcript, so the only thing this has to hand
# back across the boundary is the verdict it could not see for itself:
# this repository's gate, and what it said.
#
# Nothing here is written inside the worktree. A prompt or a log that
# landed there would show up in the diff being gated, and then in the
# pull request.
#
# `gate` and `attempt_verdict` are deliberately outside the `flow` guard
# below: the revision lane (150-revise.sh) runs sessions and judges them
# by exactly the same four checks and the same gate, and one definition
# is what keeps that from drifting into a second, weaker copy.
#
# The gate. Deliberately this repository's own CI gate rather than a
# cheaper proxy: the entire value of an unattended runner is that it does
# not hand a human a red pull request, and an attempt costs cents.
#
# `nix flake check` and the host builds are CI's `checks` and `build`
# matrices. The checks-versus-matrix audit is CI's lint job, reproduced
# here because it is the one gate `nix flake check` cannot see: adding
# `checks/foo.nix` without adding `foo` to ci.yml's hand-written matrix
# passes every Nix-level check and still fails CI, which is why the prompt
# above carries the narrow ci.yml exception docs/agents/afk-eligibility.md
# defines.
#
# Reproducing a CI step here can drift from the step it copies. That drift
# is visible rather than silent - it shows up as a branch that is green
# here and red on the pull request - which is the acceptable direction for
# it to fail, and there is no way to invoke a GitHub Actions step from
# outside GitHub Actions.
#
# Whether the ci.yml exception was *honoured* - a diff that adds matrix
# entries and does nothing else - is a different question, and it is
# asked of the diff itself by `push_gate` below, before the push.
#
# Hosts are discovered from the branch under test rather than listed, so a
# ticket that adds a host is gated on the host it added. CI names them by
# hand because discovery would cost it a serialised job ahead of a
# parallel matrix; nothing here is parallel, so nothing here pays for it.
#
# Every step ends in `|| exit 1` instead of leaning on `set -e`, and that
# is load-bearing rather than belt-and-braces. Bash switches errexit off
# inside any command used as a condition, and it stays off all the way
# down - through the function, through the subshell, past an explicit
# `set -e` written inside that subshell. The only place this is ever
# called from is `if ! gate`, so written the obvious way it would run
# every step, ignore every failure, and return the status of the last one:
# a `for` loop over a host list that the failed discovery step above it
# left empty, which is to say success. A gate that passes because
# everything before it failed is the exact shape of a gate that has
# stopped gating, and it was a check expecting a retry and getting none
# that found it, not reading the code.
gate() {
	(
		cd "$worktree" || exit 1
		set -x

		# One deadline for the whole gate, rather than a ceiling on each
		# step. Per-step ceilings multiply where this adds, and what has to
		# fit under `maxRuntime` is three attempts *and* three gates, not any
		# single command. `step` spends whatever is left of the budget on the
		# command it is given, and refuses once there is none.
		SECONDS=0
		step() {
			local left=$((@GATE_TIMEOUT@ - SECONDS))
			[ "$left" -gt 0 ] || return 1
			timeout "$left" "$@"
		}

		step nix fmt -- --ci || exit 1

		step nix eval --raw .#checks.x86_64-linux \
			--apply 'cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)' |
			LC_ALL=C sort >"$run_dir/flake-checks" || exit 1
		step yq -r '.jobs.checks.strategy.matrix.check[]' .github/workflows/ci.yml |
			LC_ALL=C sort >"$run_dir/matrix-checks" || exit 1
		step diff -u "$run_dir/flake-checks" "$run_dir/matrix-checks" || exit 1

		# Every check the flake exposes, one `nix build` each, rather than
		# the single `nix flake check` this used to be. Not a style
		# preference - `nix flake check` evaluates every output in one
		# process, and on this flake that is three `nixosConfigurations`
		# plus the NixOS system each VM test builds inside itself, all live
		# in one evaluator heap at once, and the kernel OOM-killed a run
		# that hit it.
		#
		# One process per check is what CI has always done - `ci.yml`'s
		# `checks` job is a matrix, one runner each - so this stops being a
		# cheaper proxy for CI and starts being the same shape as CI. The
		# `diff` immediately above is what makes the loop total: it has just
		# asserted that this list and ci.yml's matrix name the same checks,
		# so iterating it cannot silently skip one.
		#
		# What is lost is `nix flake check`'s own validation of the outputs
		# around the checks - devShells, formatter, the flake's shape. CI
		# does not gate on that either, and a gate that disagrees with CI is
		# the thing this whole function exists not to be.
		local check
		while read -r check; do
			[ -n "$check" ] || continue
			step nix build --no-link ".#checks.x86_64-linux.$check" || exit 1
		done <"$run_dir/flake-checks"

		local hosts
		hosts="$(step nix eval --raw .#nixosConfigurations \
			--apply 'cs: builtins.concatStringsSep " " (builtins.attrNames cs)')" || exit 1
		read -r -a host_list <<<"$hosts"
		# A discovery that came back with nothing is a gate that built
		# nothing, which must not read as a gate that passed.
		[ "${#host_list[@]}" -gt 0 ] || exit 1
		for host in "${host_list[@]}"; do
			step nix build --no-link \
				".#nixosConfigurations.$host.config.system.build.toplevel" || exit 1
		done
	) >"$run_dir/gate.log" 2>&1
}

# Four ways a session that was asked to write code fails, in the order
# they can be told apart. The middle two are not defensive padding: the
# pilot measured runs that exited 0 having explained what they would do
# rather than doing it, and work left in the working tree is work the
# push would silently drop.
#
# A function rather than a block inside the loop, because ADR 0007 adds a
# second caller: a CI fix round runs an implement session too, and it has
# to be judged by exactly these four things rather than by a second copy
# of them that can drift. `$2` is what "committed something" is measured
# against - `origin/master` for an attempt at the whole ticket, and the
# commit already pushed for a round that is fixing it. The revision lane
# passes the pull request's own head, for the same reason.
#
# `reason` and `committed` are set rather than returned: bash returns a
# status, and both callers need the prose as well as the verdict.
attempt_verdict() {
	local rc=$1 since=$2
	reason=""
	committed="$(git -C "$worktree" rev-list --count "$since..HEAD")"
	if [ "$rc" -eq 124 ]; then
		reason="it ran past its @ATTEMPT_TIMEOUT@s ceiling and was stopped"
	elif [ "$rc" -ne 0 ]; then
		reason="opencode exited $rc"
	elif [ "$committed" -eq 0 ]; then
		reason="nothing was committed to $branch"
	elif [ -n "$(git -C "$worktree" status --porcelain)" ]; then
		reason="$(printf 'work was left uncommitted:\n%s' \
			"$(git -C "$worktree" status --porcelain)")"
	elif ! gate; then
		reason="$(printf 'the gate failed. Its last @GATE_TAIL_LINES@ lines:\n\n%s' \
			"$(tail -n @GATE_TAIL_LINES@ "$run_dir/gate.log")")"
	fi
}

# The loop is the ticket lane's; the revision lane has its own, with the
# revision prompt as the opening message (150-revise.sh).
if [ "$flow" = issue ]; then
	sed "s/ISSUE/$number/g" @IMPLEMENT_PROMPT@ >"$run_dir/prompt"

	session=""
	message="$(cat "$run_dir/prompt")"

	while :; do
		log "#$number: implement attempt $attempt of @MAX_ATTEMPTS@"

		# `--title` on the first attempt is what makes the session findable
		# again; `--session` on every attempt after it is ADR 0004 §6.
		opencode_args=(--agent build --model @MODEL@ --variant @VARIANT@)
		if [ -n "$session" ]; then
			opencode_args+=(--session "$session")
		else
			opencode_args+=(--title "$slug")
		fi

		# `|| exit 1` on the `cd` for the same reason as in the gate: this
		# subshell is the left side of a `||`, so errexit is off inside it, and
		# a failed `cd` would otherwise run the session against whatever
		# directory the runner happened to be in.
		#
		# `--dir` says the same thing a second way, and it is not redundant.
		# opencode resolves its project - and with it which `.agents/skills/`
		# it can see - from the directory it is launched in, so an ambient
		# working directory is load-bearing state that looks like none. The
		# review stage below pins the
		# same flag; both stages say it explicitly so that neither depends on
		# the `cd` above having done what it looks like it did.
		# Overlay scoped to the command, not exported for the rest of the run,
		# for the reason the review stage below gives: a deny-set that outlives
		# its own session is ambient state that looks like none, and the verbs
		# this one denies are ones a later stage needs.
		attempt_rc=0
		(
			cd "$worktree" || exit 1
			OPENCODE_CONFIG_CONTENT=@PERMISSION_OVERLAY@ \
				timeout @ATTEMPT_TIMEOUT@ opencode run --auto \
				--dir "$worktree" "${opencode_args[@]}" "$message"
		) || attempt_rc=$?

		attempt_verdict "$attempt_rc" "origin/$base_branch"

		if [ -z "$reason" ]; then
			log "#$number: implemented on $branch, in $attempt attempt(s)"
			break
		fi

		log "#$number: attempt $attempt did not pass, because $reason"

		if [ "$attempt" -ge @MAX_ATTEMPTS@ ]; then
			hand_back "@MAX_ATTEMPTS@ attempts and no passing implementation; the last one failed because $reason"
		fi

		# Read back once and then reused: the id does not change, and
		# `session list` is a question with a cost.
		if [ -z "$session" ]; then
			session="$(session_id_for "$worktree" "$slug")"
		fi

		# Whether there is a session to continue decides both what the next
		# attempt is addressed to and what it is told, and the two have to move
		# together: a fresh session handed a message about a failure it cannot
		# see would be worse than either.
		#
		# The messages are built with printf rather than written as literals
		# spanning lines. A continuation line would have to start in column 0
		# to keep the script's own indentation out of the text, and a column-0
		# line inside a Nix indented string collapses the dedent for the whole
		# script - which is not theoretical, it happened while writing this.
		if [ -n "$session" ]; then
			log "#$number: retrying inside session $session"
			message="$(printf '%s\n\n%s' \
				"Attempt $attempt of @MAX_ATTEMPTS@ did not pass, because $reason" \
				"Fix that here, in this worktree, and commit the fix. The gate is the only thing that decides whether this ticket is done.")"
		elif [ "$attempt_rc" -eq 0 ] || [ "$committed" -gt 0 ]; then
			# An attempt that exited cleanly, or committed, plainly had a session.
			# Not being able to find it means the next attempt would re-read the
			# ticket in a fresh context with no idea what just failed, which is
			# the degrade ADR 0004 §6 rules out rather than a lesser form of it.
			hand_back "attempt $attempt ran, but no session titled '$slug' can be found to continue; refusing to retry in a fresh context (ADR 0004 §6)"
		else
			# Nothing to continue, and nothing lost by not continuing: the attempt
			# failed before it opened a session, so there is no transcript for a
			# retry to carry. The next one is the first real attempt rather than a
			# context-free retry, so it gets the original prompt back.
			log "#$number: attempt $attempt opened no session; the next one starts one"
			message="$(cat "$run_dir/prompt")"
		fi

		attempt=$((attempt + 1))
	done
fi

# --- the last denylist check, asked of the diff ------------------------
#
