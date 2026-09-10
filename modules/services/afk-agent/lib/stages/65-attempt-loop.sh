# shellcheck shell=bash
# The attempt loop the build lanes share (#243).
#
# Two lanes run sessions against a worktree and retry a failed one inside
# the session that failed (ADR 0004 §6): the ticket lane's implement
# loop, below its own `if [ "$flow" = issue ]` in 70-implement.sh, and
# the revision lane's round loop, below its own in 150-revise.sh. Both
# used to carry their own copy of the loop - the argument construction,
# the `--title`/`--session` switch, the session read-back, the three-way
# retry branch - and two copies of a retry policy drift independently:
# a fix to one that misses the other is a behaviour difference between
# the lanes that neither lane's check can see, because each pins its own
# copy. The loop below is one definition for both. What genuinely differs
# between the lanes is passed in: the log label, the opening message, the
# session title, the ref the verdict is measured against, and the
# continuation message's wording.
#
# `gate` and `attempt_verdict` are defined further down the script, with
# the implement stage's other shared pieces above its flow guard; a
# function body's names are resolved when it runs, by which point every
# definition is in place.
#
# The CI fix rounds (110-ci.sh, 150-revise.sh) are not loops: one session,
# judged once, no retry (ADR 0007). What they share with this machinery is
# the attempt's own shape - `run_build_session` - and the verdict and
# hand-back are theirs (`ci_fix_round`, which both fix rounds share).
#
# One attempt of the build lane: the argument construction, the
# `--title`/`--session` switch, and the subshell the loop and the fix
# rounds run their sessions through. `$1` is the session id to continue,
# `$2` the title to open a fresh session under, `$3` the message. The
# status is left in `build_rc` rather than returned, because every caller
# needs the verdict beside it and a status would be one more channel to
# keep straight.
#
# `--title` on the first attempt is what makes the session findable
# again; `--session` on every attempt after it is ADR 0004 §6.
#
# `|| exit 1` on the `cd` for the same reason as in the gate: this
# subshell is the left side of a `||`, so errexit is off inside it, and
# a failed `cd` would otherwise run the session against whatever
# directory the runner happened to be in.
#
# `--dir` says the same thing a second way, and it is not redundant.
# opencode resolves its project - and with it which `.agents/skills/`
# it can see - from the directory it is launched in, so an ambient
# working directory is load-bearing state that looks like none. Every
# stage that opens a session says it explicitly so that none depends on
# the `cd` above having done what it looks like it did.
#
# The overlay is scoped to the command, not exported for the rest of the
# run: a deny-set that outlives its own session is ambient state that
# looks like none, and the verbs this one denies are ones a later stage
# needs.
run_build_session() {
	local session=$1 title=$2 message=$3
	local opencode_args=(--agent build --model @MODEL@ --variant @VARIANT@)
	if [ -n "$session" ]; then
		opencode_args+=(--session "$session")
	else
		opencode_args+=(--title "$title")
	fi

	build_rc=0
	(
		cd "$worktree" || exit 1
		OPENCODE_CONFIG_CONTENT=@PERMISSION_OVERLAY@ \
			timeout @ATTEMPT_TIMEOUT@ opencode run --auto \
			--dir "$worktree" "${opencode_args[@]}" "$message"
	) || build_rc=$?
}

# The loop. Its parameters are the facts the lanes genuinely differ on,
# in call order:
#
#   $1  the per-attempt log label ("implement attempt";
#       "revision round N of M, attempt")
#   $2  the opening message
#   $3  the session title - what a fresh session is opened under and
#       what a failed one is read back by
#   $4  the ref the verdict measures new commits against
#   $5  the retry budget, in attempts
#   $6  the continuation message's head ("Attempt" / "Revision attempt")
#   $7  its tail ("this ticket is done" / "this revision round is done")
#   $8  the budget-exhaustion hand-back, with one %s where the verdict
#       belongs
#
# The session travels in `$session`, the runner's one session variable,
# seeded by the caller: the ticket lane has nothing to continue, the
# revision lane may have the session that built the branch, and
# 110-ci.sh's fix round continues whatever the loop converged in.
# `attempt` is the caller's too, and the loop increments it, so on
# success it is the number of attempts spent.
attempt_loop() {
	local label=$1 message=$2 session_title=$3 since=$4 budget=$5
	local retry_head=$6 retry_tail=$7 exhaust_message=$8
	local first_message="$message"

	while :; do
		log "#$number: $label $attempt of $budget"

		run_build_session "$session" "$session_title" "$message"

		attempt_verdict "$build_rc" "$since"

		if [ -z "$reason" ]; then
			break
		fi

		log "#$number: $label $attempt did not pass, because $reason"

		if [ "$attempt" -ge "$budget" ]; then
			# The verdict is spliced in where the %s sits rather than through
			# printf: the format is the caller's prose, and a variable format
			# string is exactly what shellcheck refuses (SC2059). The splice is
			# a split-and-concatenate rather than ${var/pat/repl}: in the
			# replacement of that form, `&` and `\` are special, and $reason
			# embeds gate output and git status, which contain both. The
			# exhaust message carries exactly one %s; splitting on it keeps
			# $reason as plain text in both halves.
			hand_back "${exhaust_message%%'%s'*}$reason${exhaust_message#*'%s'}"
		fi

		# Read back once and then reused: the id does not change, and
		# `session list` is a question with a cost.
		if [ -z "$session" ]; then
			session="$(session_id_for "$worktree" "$session_title")"
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
				"$retry_head $attempt of $budget did not pass, because $reason" \
				"Fix that here, in this worktree, and commit the fix. The gate is the only thing that decides whether $retry_tail.")"
		elif [ "$build_rc" -eq 0 ] || [ "$committed" -gt 0 ]; then
			# An attempt that exited cleanly, or committed, plainly had a session.
			# Not being able to find it means the next attempt would re-read the
			# ticket in a fresh context with no idea what just failed, which is
			# the degrade ADR 0004 §6 rules out rather than a lesser form of it.
			hand_back "$label $attempt ran, but no session titled '$session_title' can be found to continue; refusing to retry in a fresh context (ADR 0004 §6)"
		else
			# Nothing to continue, and nothing lost by not continuing: the attempt
			# failed before it opened a session, so there is no transcript for a
			# retry to carry. The next one is the first real attempt rather than a
			# context-free retry, so it gets the original prompt back.
			log "#$number: $label $attempt opened no session; the next one starts one"
			message="$first_message"
		fi

		attempt=$((attempt + 1))
	done
}

# A CI fix round: one build session inside the session that produced the
# red commit, judged by the same four checks an implement attempt is -
# against `$pushed_head`, the commit that was pushed rather than the base
# branch - and handed back if it did not pass. Judged once: a CI fix gets
# one session and no retry, which is a deliberate asymmetry with the
# implement stage rather than an oversight (ADR 0007): the local gate has
# already passed on this branch, so a fix that fails it is the model
# going backwards rather than failing to converge - and unlike the
# implement stage there is now a pull request a human can pick up, which
# is most of what a retry budget was buying.
ci_fix_round() {
	local session=$1 message=$2

	run_build_session "$session" "" "$message"

	attempt_verdict "$build_rc" "$pushed_head"
	[ -z "$reason" ] ||
		hand_back "the CI fix did not pass, because $reason. $pr_url is open with a red CI run on it; a CI fix gets one session and no retry (ADR 0007)"
}
