-- Keybinds
-- https://wiki.hypr.land/Configuring/Basics/Binds/

local mod = "SUPER"

---------------------------------------------------------------------------
-- Applications
---------------------------------------------------------------------------
hl.bind(mod .. " + T", hl.dsp.exec_cmd("ghostty"))
hl.bind(mod .. " + B", hl.dsp.exec_cmd("vivaldi"))
hl.bind(mod .. " + E", hl.dsp.exec_cmd("ghostty --working-directory=~ -e yazi"))
hl.bind(mod .. " + R", hl.dsp.exec_cmd("rofi -show drun -show-icons"))
hl.bind(mod .. " + W", hl.dsp.exec_cmd("rofi -show window -show-icons"))
hl.bind(mod .. " + S", hl.dsp.exec_cmd("pgrep hyprlock || hyprlock"))

hl.bind(mod .. " + P", hl.dsp.exec_cmd("project-launcher pick"))
hl.bind(mod .. " + Q", hl.dsp.exec_cmd("project-launcher close"))

---------------------------------------------------------------------------
-- Window management
---------------------------------------------------------------------------
hl.bind(mod .. " + C", hl.dsp.window.close())
hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + A", hl.dsp.layout("togglesplit"))
hl.bind(mod .. " + SHIFT + F", hl.dsp.window.pin()) -- F for Fix

-- Groups
hl.bind(mod .. " + G", hl.dsp.group.toggle())
hl.bind(mod .. " + SHIFT + N", hl.dsp.group.next())
hl.bind(mod .. " + SHIFT + P", hl.dsp.group.prev())

---------------------------------------------------------------------------
-- Focus navigation (vim-motions)
---------------------------------------------------------------------------
hl.bind(mod .. " + H", hl.dsp.focus({ direction = "left" }))
hl.bind(mod .. " + L", hl.dsp.focus({ direction = "right" }))
hl.bind(mod .. " + K", hl.dsp.focus({ direction = "up" }))
hl.bind(mod .. " + J", hl.dsp.focus({ direction = "down" }))

---------------------------------------------------------------------------
-- Move windows (swap position)
---------------------------------------------------------------------------
hl.bind(mod .. " + SHIFT + H", hl.dsp.window.move({ direction = "l" }))
hl.bind(mod .. " + SHIFT + L", hl.dsp.window.move({ direction = "r" }))
hl.bind(mod .. " + SHIFT + K", hl.dsp.window.move({ direction = "u" }))
hl.bind(mod .. " + SHIFT + J", hl.dsp.window.move({ direction = "d" }))

---------------------------------------------------------------------------
-- Resize submap
---------------------------------------------------------------------------
hl.bind(mod .. " + SHIFT + R", hl.dsp.submap("resize"))

hl.define_submap("resize", function()
	hl.bind("H", hl.dsp.window.resize({ x = -30, y = 0, relative = true }), { repeating = true })
	hl.bind("L", hl.dsp.window.resize({ x = 30, y = 0, relative = true }), { repeating = true })
	hl.bind("K", hl.dsp.window.resize({ x = 0, y = -30, relative = true }), { repeating = true })
	hl.bind("J", hl.dsp.window.resize({ x = 0, y = 30, relative = true }), { repeating = true })
	hl.bind("escape", hl.dsp.submap("reset"))
end)

---------------------------------------------------------------------------
-- Workspace navigation
---------------------------------------------------------------------------
-- Switch and move-to workspaces 1-10
for i = 1, 10 do
	local key = i % 10 -- 10 maps to key 0
	hl.bind(mod .. " + " .. key, hl.dsp.focus({ workspace = i }))
	hl.bind(mod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- Cycle workspaces on current monitor
hl.bind(mod .. " + bracketleft", hl.dsp.focus({ workspace = "m-1" }))
hl.bind(mod .. " + bracketright", hl.dsp.focus({ workspace = "m+1" }))

-- Cross-monitor focus and workspace moves
hl.bind(mod .. " + SHIFT + bracketleft", hl.dsp.focus({ monitor = "l" }))
hl.bind(mod .. " + SHIFT + bracketright", hl.dsp.focus({ monitor = "r" }))
hl.bind(mod .. " + SHIFT + ALT + bracketleft", hl.dsp.workspace.move({ monitor = "l" }))
hl.bind(mod .. " + SHIFT + ALT + bracketright", hl.dsp.workspace.move({ monitor = "r" }))

---------------------------------------------------------------------------
-- Scratchpad (special workspace)
---------------------------------------------------------------------------
hl.bind(mod .. " + grave", hl.dsp.workspace.toggle_special("scratchpad"))
hl.bind(mod .. " + SHIFT + grave", hl.dsp.window.move({ workspace = "special:scratchpad" }))

---------------------------------------------------------------------------
-- Mouse binds
---------------------------------------------------------------------------
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
hl.bind(mod .. " + ALT + mouse:272", hl.dsp.window.resize(), { mouse = true })

---------------------------------------------------------------------------
-- Screenshot
---------------------------------------------------------------------------
hl.bind("Print", hl.dsp.exec_cmd("grimblast copy area"))

---------------------------------------------------------------------------
-- Media keys
---------------------------------------------------------------------------
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"), { locked = true })

-- Volume (repeating)
hl.bind(
	"XF86AudioRaiseVolume",
	hl.dsp.exec_cmd("wpctl set-volume -l '1.0' @DEFAULT_AUDIO_SINK@ 6%+"),
	{ locked = true, repeating = true }
)
hl.bind(
	"XF86AudioLowerVolume",
	hl.dsp.exec_cmd("wpctl set-volume -l '1.0' @DEFAULT_AUDIO_SINK@ 6%-"),
	{ locked = true, repeating = true }
)

-- Brightness (repeating)
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brillo -q -u 300000 -A 5"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brillo -q -u 300000 -U 5"), { locked = true, repeating = true })
