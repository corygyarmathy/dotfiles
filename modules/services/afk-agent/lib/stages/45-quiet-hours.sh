# shellcheck shell=bash
# --- quiet hours (#211) ----------------------------------------------
#
# A poll that would start a session inside a quiet-hours window starts
# nothing instead - ahead of the dead-run guard and the revision frontier
# as well as the ticket queue. The full why is the `quietHours` option's
# description in afk-agent.nix, which is the one place it is argued; what
# is local to this stage is the shape of the decision:
#
# The end of a window is exclusive and the start inclusive: 04:00 is
# inside `04:00-05:00`, 05:00 is not. A window whose start is after its
# end spans midnight (`23:30-06:30`), and the comparison below reads it
# that way rather than assuming start-before-end.
#
# `AFK_NOW` is the one seam this gate needs, in the shape AFK_CI_POLL_INTERVAL
# has for the CI watch: the check drives a decision that is about the wall
# clock, and a harness reading the real clock would be testing the time of
# day it happened to run at. Everything else about the gate - the windows,
# their format, the midnight span - is baked and under test as written.
in_quiet_hours() {
	local window start end
	local now="${AFK_NOW:-$(date +%H:%M)}"
	local n=$((10#${now%%:*} * 60 + 10#${now#*:}))
	for window in "${quiet_hours[@]}"; do
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

if [ "${#quiet_hours[@]}" -gt 0 ] && in_quiet_hours; then
	log "quiet hours: inside a quiet-hours window; starting nothing this poll"
	exit 0
fi
