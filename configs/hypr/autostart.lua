-- Autostart
-- hl.on("hyprland.start", ...) runs once at launch, not on config reload

hl.on("hyprland.start", function()
	hl.exec_cmd("systemctl --user start hyprland-session.target")
	hl.exec_cmd("hyprpaper")
	hl.exec_cmd("dunst")
	hl.exec_cmd("kdeconnect-indicator")
	-- add other daemons here, e.g.:
	-- hl.exec_cmd("nm-applet --indicator")
end)
