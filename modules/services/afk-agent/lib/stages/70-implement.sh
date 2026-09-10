# shellcheck shell=bash
# The build lane's own pieces of the attempt machinery: the gate, and
# the four-way verdict the shared loop judges its attempts by. The loop
# itself - the argument construction, the `--title`/`--session` switch,
# the session read-back, the three-way retry branch - is the shared one
# in 65-attempt-loop.sh, and it is one definition for the ticket lane and
# the revision lane together, so a fix to the retry policy cannot land in
# one lane and miss the other (#243).
#
# ADR 0004 §6 is what the retry shape is: a retry happens *inside* the
# session that produced the failure, because a retry that cannot see
# what it is retrying against is close to useless. `opencode run
# --session` is what makes that literal. The model keeps its own
# transcript, so the only thing this has to hand back across the
# boundary is the verdict it could not see for itself: this repository's
# gate, and what it said.
#
# Nothing here is written inside the worktree. A prompt or a log that
# landed there would show up in the diff being gated, and then in the
# pull request.
#
# `gate` and `attempt_verdict` are deliberately outside the `flow` guard
# below: the CI fix rounds (110-ci.sh, 150-revise.sh) judge their one
# session by exactly the same four checks and the same gate, and the
# revision lane's loop consumes the verdict through the shared loop - one
# definition each is what keeps that from drifting into second, weaker
# copies.
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

# The loop is the shared one (65-attempt-loop.sh); what is this lane's is
# the prompt and the wording its retries carry. The verdict is measured
# against `origin/$base_branch`: what has to be true is that something
# was committed to the branch this run cut, on top of the base it was cut
# from. The loop's seed is the global `$session`, empty here: the first
# attempt opens the session, and later ones - and 110-ci.sh's fix round -
# continue it.
if [ "$flow" = issue ]; then
	sed "s/ISSUE/$number/g" @IMPLEMENT_PROMPT@ >"$run_dir/prompt"

	session=""
	attempt_label="implement attempt"
	attempt_loop \
		"$attempt_label" \
		"$(cat "$run_dir/prompt")" \
		"$slug" \
		"origin/$base_branch" \
		@MAX_ATTEMPTS@ \
		"Attempt" \
		"this ticket is done" \
		"@MAX_ATTEMPTS@ attempts and no passing implementation; the last one failed because %s"

	log "#$number: implemented on $branch, in $attempt attempt(s)"
fi

# --- the last denylist check, asked of the diff ------------------------
#
