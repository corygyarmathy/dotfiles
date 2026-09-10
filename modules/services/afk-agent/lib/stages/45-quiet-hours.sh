# shellcheck shell=bash
# --- quiet hours (#211) ----------------------------------------------
#
# The busy windows are a spend boundary, not an availability one (see the
# option's description in afk-agent.nix): usage billing is priced by the
# hour, so a poll that would start a session inside a window starts
# nothing instead. The gate sits at the front of the poll - ahead of the
# dead-run guard and the revision frontier as well as the ticket queue -
# because the point is that nothing runs at all, and a tracker write this
# poll could have made can wait one window for the next poll that may
# make it.
#
# What this does not stop is a run already in flight when a window opens.
# Killing it would strand a claimed ticket behind a hand-back, which is a
# worse price than the API spend the window is there to save - and
# concurrency here is one (ADR 0004 §8), so a run in flight would have
# blocked every later poll regardless. A window is a scheduling
# restriction, and scheduling is what the poll is.
#
# `AFK_NOW` is the one seam this gate needs, in the shape AFK_CI_POLL_INTERVAL
# has for the CI watch: the check drives a decision that is about the wall
# clock, and a harness reading the real clock would be testing the time of
# day it happened to run at. Everything else about the gate - the windows,
# their format, the midnight span - is baked and under test as written.
#
# The end is exclusive and the start inclusive: 04:00 is inside
# `04:00-05:00`, 05:00 is not. A window whose start is after its end
# spans midnight (`23:30-06:30`), and the comparison below reads it that
# way rather than assuming start-before-end.
in_busy_time() {
	local window start end
	local now="${AFK_NOW:-$(date +%H:%M)}"
	local n=$((10#${now%%:*} * 60 + 10#${now#*:}))
	for window in "${busy[@]}"; do
		start="${window%%-*}"
		end="${window##*-}"
		local s=$((10#${start%%:*} * 60 + 10#${start#*:}))
		local e=$((10#${end%%:*} * 60 + 10#${end#*:}))
		if [ "$s" -lt "$e" ]; then
			if [ "$n" -ge "$s" ] && [ "$n" -lt "$e" ]; then
				return 0
			fi
		else
			if [ "$n" -ge "$s" ] || [ "$n" -lt "$e" ]; then
				return 0
			fi
		fi
	done
	return 1
}

if [ "${#busy[@]}" -gt 0 ] && in_busy_time; then
	log "quiet hours: inside a busy window; starting nothing this poll"
	exit 0
fi
