# shellcheck shell=bash
# ADR 0007 §3: CI is the correctness gate on this path and the review is
# a quality pass. The local gate above is not redundant - it is cheap,
# immediate, and it is what decides whether the implement stage converged
# at all - but it is this runner's reproduction of CI's steps, and the
# gate's own comment already records that a reproduction can drift from
# what it copies. CI runs what only CI runs: a cold runner, the sharded
# check matrix, and every host built from an empty store.
#
# THE HARD PART IS TELLING A CHECK THAT NEVER ARRIVES FROM A SLOW ONE,
# and there is no fact that distinguishes them - only a bound. So there
# are two, counted in polls rather than seconds (see `ciPollInterval`
# above): how long a run may go with no check reported for the commit
# that was just pushed, and how long the whole watch may take. The first
# is a workflow that was never triggered, which is a configuration
# problem rather than a problem with the diff and so is never fed back to
# a model that would have nothing to fix.
#
# READ FROM THE PULL REQUEST'S HEAD COMMIT RATHER THAN FROM `gh pr
# checks`, and the difference is load-bearing. Immediately after a fix is
# pushed, GitHub can still be reporting the *previous* commit's checks -
# which for a round that got here are red. A watch that trusted them
# would spend its second round refusing the fix it had just made, before
# the fix had been looked at. `statusCheckRollup` comes back beside
# `headRefOid` in one snapshot, so the commit the verdict belongs to
# arrives with the verdict and can be compared to the one that was
# pushed.
ci_poll_interval="${AFK_CI_POLL_INTERVAL:-@CI_POLL_INTERVAL@}"

# One snapshot, reduced to a word and - for everything but green - the
# names behind it. Both check kinds GitHub reports through this field are
# handled: a `CheckRun` has a `status`/`conclusion` pair, a
# `StatusContext` has a single `state`, and a rollup can hold both.
#
# `|| rollup=""` on the `gh` call rather than a bare one, for the reason
# `session_id_for` carries a `|| true`: this whole function runs inside a
# command substitution under `set -euo pipefail`, so a transient API
# failure would abort the runner outright rather than counting as one
# poll that saw nothing. The same goes for the `|| printf` after `jq`,
# which catches an answer that parsed but was not a rollup.
ci_snapshot() {
	local head=$1 rollup
	rollup="$(gh pr view "$pr_url" --json headRefOid,statusCheckRollup 2>/dev/null)" || rollup=""
	[ -n "$rollup" ] || {
		printf 'absent\n'
		return 0
	}

	printf '%s' "$rollup" | jq -r --arg head "$head" '
    def bucket:
      if has("conclusion") then
        if .status != "COMPLETED" then "pending"
        elif .conclusion == null or .conclusion == "" then "pending"
        elif (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "pass"
        elif .conclusion == "CANCELLED" then "cancelled"
        else "fail"
        end
      else
        if .state == "SUCCESS" then "pass"
        elif .state == "PENDING" or .state == "EXPECTED" then "pending"
        else "fail"
        end
      end;
    def named($b): map(select(.bucket == $b) | .name) | join(", ");
    if (.headRefOid // "") != $head then "absent"
    else
      [ (.statusCheckRollup // [])[]
        | { name: (.name // .context // "an unnamed check"), bucket: bucket } ]
      | if length == 0 then "absent"
        elif (map(select(.bucket == "fail")) | length) > 0 then "red\n" + named("fail")
        elif (map(select(.bucket == "cancelled")) | length) > 0 then "cancelled\n" + named("cancelled")
        elif (map(select(.bucket == "pending")) | length) > 0 then "pending\n" + named("pending")
        else "green"
        end
    end' 2>/dev/null || printf 'absent\n'
}

# Poll until the checks on `$1` have settled, or until one of the two
# bounds runs out. Sets `ci_state` to one of green, red, cancelled,
# absent or unsettled, and `ci_failed` to whichever checks are behind it.
ci_state=""
ci_failed=""
watch_ci() {
	local head=$1 tick=0 unseen=0 answer state
	while :; do
		answer="$(ci_snapshot "$head")"
		state="$(printf '%s\n' "$answer" | head -n 1)"
		ci_failed="$(printf '%s\n' "$answer" | tail -n +2)"

		case "$state" in
		green | red | cancelled)
			ci_state="$state"
			return 0
			;;
		absent)
			unseen=$((unseen + 1))
			if [ "$unseen" -ge @CI_FIRST_CHECK_POLLS@ ]; then
				ci_state=absent
				return 0
			fi
			;;
		*)
			# Pending, and the only state worth waiting through.
			;;
		esac

		tick=$((tick + 1))
		if [ "$tick" -ge @CI_SETTLE_POLLS@ ]; then
			ci_state=unsettled
			return 0
		fi

		sleep "$ci_poll_interval"
	done
}

ci_round=1
while :; do
	pushed_head="$(git -C "$worktree" rev-parse HEAD)"
	log "#$number: watching CI on $pushed_head (round $ci_round of @MAX_CI_ROUNDS@)"
	watch_ci "$pushed_head"

	if [ "$ci_state" = green ]; then
		log "#$number: CI is green on $pushed_head after $ci_round round(s)"
		break
	fi

	# Three ways the watch ends without a verdict about the diff. None of
	# them is something a model can fix, so none is fed back to one; each
	# leaves $pr_url open, without the hand-off label, which is what says
	# from the outside that nobody has finished with it (ADR 0007 §2).
	case "$ci_state" in
	absent)
		hand_back "nothing has reported on $pushed_head after @CI_FIRST_CHECK_POLLS@ polls - either CI was never triggered for it, or GitHub could not be asked. Neither is something the diff can fix. $pr_url is open and unfinished"
		;;
	unsettled)
		hand_back "CI on $pushed_head has not settled after @CI_SETTLE_POLLS@ polls, and still has $ci_failed outstanding. $pr_url is open and unfinished"
		;;
	cancelled)
		hand_back "CI on $pushed_head was cancelled ($ci_failed), so it reached no verdict. $pr_url is open and unfinished, and a re-run is a human's call"
		;;
	esac

	# The reason this line names both gates: the local gate passed on this
	# exact commit; CI did not. If that never happens, this whole stage is
	# latency for its own sake and should be cut. If it happens, the
	# difference between the two readings is what to go and fix - in the
	# local gate, which is the reproduction, rather than in ci.yml.
	log "#$number: CI is red on $pushed_head where the local gate passed. Not green: $ci_failed"

	if [ "$ci_round" -ge @MAX_CI_ROUNDS@ ]; then
		hand_back "@MAX_CI_ROUNDS@ CI round(s) and $branch is still red ($ci_failed). $pr_url is open with the work on it and without the hand-off label; nothing merges it (ADR 0004 §9)"
	fi

	# ADR 0004 §6, applied to a failure it did not anticipate: the fix
	# happens inside the session that produced the failing commit, because
	# a fix that cannot see what it is fixing is close to useless. The
	# session id may never have been looked up - a ticket that converged on
	# its first attempt never needed it - so this is the same read-back the
	# retry path does, with the same refusal behind it.
	if [ -z "$session" ]; then
		session="$(session_id_for "$worktree" "$slug")"
	fi
	[ -n "$session" ] ||
		hand_back "CI is red on $pr_url, but no session titled '$slug' can be found to fix it in; refusing to fix in a fresh context (ADR 0004 §6)"

	# What crosses the boundary is what the model could not see for itself.
	# It is told which checks are not green and where to read them, and
	# told plainly that it is not the one who pushes - `gh pr*` is denied
	# to this session anyway, but a model that spends its round trying is a
	# round spent.
	#
	# `gh run view` is deliberately not denied. It is the only way to turn
	# a check's name into the log that explains it, and it can write
	# nothing.
	ci_message="$(printf '%s\n\n%s\n\n%s\n\n%s' \
		"The pull request for this branch is $pr_url, and CI on it is red on the commit at the head of this branch. This repository's local gate - the same one you have already passed - agreed with that commit, so this is something only CI sees: a cold runner, the sharded check matrix, and every host built from an empty store." \
		"$(printf 'These checks are not green:\n%s' "$ci_failed")" \
		"Read the failing job's log before changing anything: \`gh run view --log-failed --job <id>\`, where <id> is the last path segment of that check's link on the pull request. \`gh run list --branch $branch\` will find the run." \
		"Fix it here, in this worktree, and commit the fix. Do not push and do not touch the pull request - this runner pushes your commit to the same branch afterwards. The local gate has to pass on your fix as well, and there is no retry: this round is judged once.")"

	attempt=$((attempt + 1))
	log "#$number: feeding the red run back into session $session (implement session $attempt)"

	ci_fix_rc=0
	(
		cd "$worktree" || exit 1
		OPENCODE_CONFIG_CONTENT=@PERMISSION_OVERLAY@ \
			timeout @ATTEMPT_TIMEOUT@ opencode run --auto \
			--dir "$worktree" \
			--agent build --model @MODEL@ --variant @VARIANT@ \
			--session "$session" "$ci_message"
	) || ci_fix_rc=$?

	# Judged by the same four checks an implement attempt is, against the
	# commit that was pushed rather than against the base branch: what has
	# to be true here is that something NEW was committed on top of the red
	# commit.
	#
	# And judged once. A CI fix round gets one session and no retry, which
	# is a deliberate asymmetry with the implement stage rather than an
	# oversight: the local gate has already passed on this branch, so a fix
	# that fails it is the model going backwards rather than failing to
	# converge - and unlike the implement stage there is now a pull request
	# a human can pick up, which is most of what a retry budget was buying.
	attempt_verdict "$ci_fix_rc" "$pushed_head"
	[ -z "$reason" ] ||
		hand_back "the CI fix did not pass, because $reason. $pr_url is open with a red CI run on it; a CI fix gets one session and no retry (ADR 0007)"

	push_branch
	ci_round=$((ci_round + 1))
done

# Said once and appended to every hand-back below, because from here on
# it is the same fact each time and it is the fact ADR 0007 changed: a
# review that cannot be shown to have run no longer means no pull
# request, it means a pull request nobody has handed over. The label's
# absence is what says so from the outside, and the hand-back (#175)
# carries the fact onto the ticket and the pull request both.
unfinished="$pr_url is open and green, without the @HANDOFF_LABEL@ label; nothing merges it (ADR 0004 §9)"

# --- review, in a fresh context ---------------------------------------
#
