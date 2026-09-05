-- Autostart
-- hl.on("hyprland.start", ...) runs once at launch, not on config reload
--
-- Anything with a systemd user unit belongs in that unit, not here. Starting
-- hyprland-session.target is what pulls those units in; a daemon launched here
-- as well is launched twice. hyprpaper (services.hyprpaper, enabled by stylix)
-- and dunst (services.dunst) were both in that state - dunst refused its second
-- instance, hyprpaper raced its first over the same IPC socket. kdeconnect-
-- indicator had no unit at all, so it was given one
-- (modules/home/desktop/kdeconnect.nix) rather than kept here.
--
-- That leaves one line, and it should stay the only one: add a daemon here
-- only if it has no unit, and prefer giving it one.

hl.on("hyprland.start", function()
	hl.exec_cmd("systemctl --user start hyprland-session.target")
end)
