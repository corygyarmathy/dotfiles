# session-path.nix: the PATH a graphical-session command will see.
#
# Hyprland's binds and waybar's clicks both run inside the user's graphical
# session, so their PATH is the user's own profile plus the system one - the
# same two closures, not a hand-written list that could disagree with them.
# The command checks in hyprland.nix and waybar.nix gate against exactly this
# path, so the two used to restate the formula in parallel; a formula that
# must not disagree now lives here.
#
# `/run/wrappers/bin` is not modelled: nothing on the bar or in the binds is
# setuid today, and a wrapper cannot be resolved from inside the build
# sandbox. A command that needs one will fail the check, which is the right
# moment to decide whether it belongs in the session at all.
{
  lib,
  config,
  osConfig,
}:
lib.concatStringsSep ":" [
  "${config.home.path}/bin"
  "${osConfig.system.path}/bin"
  "${osConfig.system.path}/sbin"
]
