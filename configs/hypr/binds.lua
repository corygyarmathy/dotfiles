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
-- Menus and system actions
---------------------------------------------------------------------------
-- Every menu is keybound *and* reachable from the bar (principle 2 in one
-- sentence). These are the keyboard half of items 8, 9, 10, 11 and 13 of
-- docs/plans/desktop-design.md; the pointer half lives on the bar modules.
-- Item 9's three menus take SHIFT + the first letter of the domain, which
-- keeps the plain letters for their applications (B = vivaldi, W = window
-- picker, A = togglesplit).
hl.bind(mod .. " + escape", hl.dsp.exec_cmd("power-menu"))
hl.bind(mod .. " + SHIFT + V", hl.dsp.exec_cmd("clipboard-menu"))
hl.bind(mod .. " + slash", hl.dsp.exec_cmd("keybind-sheet"))
hl.bind(mod .. " + N", hl.dsp.exec_cmd("dunstctl set-paused toggle"))
hl.bind(mod .. " + SHIFT + W", hl.dsp.exec_cmd("network-menu"))
hl.bind(mod .. " + SHIFT + B", hl.dsp.exec_cmd("bluetooth-menu"))
hl.bind(mod .. " + SHIFT + A", hl.dsp.exec_cmd("audio-menu"))

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
-- Move windows (across next or previous workspaces)
---------------------------------------------------------------------------
hl.bind(mod .. " + SHIFT + bracketleft", hl.dsp.window.move({ workspace = "m-1" }))
hl.bind(mod .. " + SHIFT + bracketright", hl.dsp.window.move({ workspace = "m+1" }))

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

hl.bind(mod .. " + CTRL + bracketleft", hl.dsp.focus({ monitor = "l" }))
hl.bind(mod .. " + CTRL + bracketright", hl.dsp.focus({ monitor = "r" }))
hl.bind(mod .. " + CTRL + ALT + bracketleft", hl.dsp.workspace.move({ monitor = "l" }))
hl.bind(mod .. " + CTRL + ALT + bracketright", hl.dsp.workspace.move({ monitor = "r" }))

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
-- Item 15 of docs/plans/desktop-design.md. Print stays the common case -
-- region to clipboard, unchanged. The other three capture to a file and
-- offer satty as an optional annotation step; SUPER+SHIFT+C picks a colour.
hl.bind("Print", hl.dsp.exec_cmd("screenshot area-copy"))
hl.bind(mod .. " + Print", hl.dsp.exec_cmd("screenshot area-save"))
hl.bind(mod .. " + SHIFT + Print", hl.dsp.exec_cmd("screenshot window"))
hl.bind(mod .. " + CTRL + Print", hl.dsp.exec_cmd("screenshot monitor"))
hl.bind(mod .. " + SHIFT + C", hl.dsp.exec_cmd("hyprpicker -a"))

---------------------------------------------------------------------------
-- Media keys
--------------------------------------------------------------------------
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true })

-- Volume and brightness now go through swayosd-client (item 12): it performs
-- the change *and* shows the OSD, so the key has immediate confirmation.
-- That replaces wpctl here and brillo on the brightness keys - brightnessctl
-- was already the tool everywhere else, and now it is the tool here too.
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"), { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle"), { locked = true })

-- Volume (repeating)
hl.bind(
	"XF86AudioRaiseVolume",
	hl.dsp.exec_cmd("swayosd-client --output-volume +5"),
	{ locked = true, repeating = true }
)
hl.bind(
	"XF86AudioLowerVolume",
	hl.dsp.exec_cmd("swayosd-client --output-volume -5"),
	{ locked = true, repeating = true }
)

-- Brightness (repeating)
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("swayosd-client --brightness +5"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness -5"), { locked = true, repeating = true })
