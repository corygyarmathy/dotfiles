# shellcheck shell=bash
# --- notifications (item 9, #176) --------------------------------------
#
# Two conditions have to reach a person who is not watching GitHub: a
# pull request is ready for review, and the pipeline is stuck on a
# ticket and needs a decision. They publish straight to the self-hosted
# ntfy server and topic the push lane already uses, at the priority that
# lane's conventions give each kind of event - the same vocabulary the
# alertmanager-ntfy bridge speaks, minus the criticals: both arrive at
# the informational level (priority low, silent, the level warnings get)
# because neither is wrong and neither should buzz a phone at 03:00, and
# they are told apart by title and tag so the phone still distinguishes
# a ticket that needs a read from a pull request that needs a review.
#
# Best-effort, like every other write this script makes from inside a
# run that has already decided its outcome: a notification that cannot
# be sent is one line in this unit's journal, and nothing downstream of
# it changes. The events it reports are already on the tracker or in
# this journal by the time it fires.
#
# The token reaches curl as a header file rather than as an argument,
# for the reason the App token reaches `gh` through the environment: a
# command line is readable by every process on the host through /proc,
# and neither credential is ever a log line or an argv element. The
# header file is written once per run next to `run_dir` below, 0600
# under the unit's umask inside a 0700 state directory.
notify() {
	local priority=$1 tag=$2 title body
	title="$(printf '%s' "$3" | tr -d '\r\n')"
	body="$run_dir/ntfy-body"
	# ntfy refuses a body over 4 KB. `|| true` because a body longer than
	# the cap makes `head` close the pipe early, and a notification
	# truncated at 3.8 KB is still a notification.
	printf '%s\n' "$4" | head -c 3800 >"$body" || true
	if ! curl -sS -m 30 \
		-H "@$run_dir/ntfy-auth" \
		-H "Title: $title" \
		-H "Priority: $priority" \
		-H "Tags: $tag" \
		--data-binary "@$body" \
		"$ntfy_url/$ntfy_topic"; then
		echo "afk-agent: the ntfy notification '$title' could not be published; the event it reports is in this journal" >&2
	fi
}

# The stuck notification the two stuck paths share: one title,
# tag and priority, differing only in the prose that names the ticket.
# The ticket URL is the one line both must carry - a stuck notification
# that does not point at its ticket is a phone alert pointing at nothing.
notify_stuck() {
	local reason=$1 status=$2
	notify low octagonal_sign "AFK agent stuck on #$number" \
		"$(printf '%s\n%s\n%s' \
			"$reason" \
			"$status" \
			"$(printf 'Ticket: https://github.com/%s/issues/%s' "$repo" "$number")")"
}
