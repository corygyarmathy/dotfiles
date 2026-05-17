-- Monitor configuration
-- https://wiki.hypr.land/Configuring/Basics/Monitors/

-- Named monitor descriptors (keeps workspace rules readable)
local ultrawide = "desc:Dell Inc. DELL U3419W 1Y9Q5T2"
local secondary = "desc:Dell Inc. DELL U2515H X48H66CQ0D1L"

-- Fallback for any unrecognised monitor
hl.monitor({
	output = "",
	mode = "preferred",
	position = "auto",
	scale = 1,
})

-- Laptop built-in display
hl.monitor({
	output = "eDP-1",
	mode = "preferred",
	position = "auto",
	scale = 1,
})

-- Lid switch
hl.bind("switch:on:Lid Switch", function()
	hl.monitor({ output = "eDP-1", disabled = true })
end, { locked = true })

hl.bind("switch:off:Lid Switch", function()
	hl.monitor({ output = "eDP-1", mode = "preferred", position = "auto", scale = 1 })
end, { locked = true })

-- Disable laptop display if lid is already closed at launch
hl.on("hyprland.start", function()
	local handle = io.open("/proc/acpi/button/lid/LID0/state", "r")
	if handle then
		local state = handle:read("*a")
		handle:close()
		if state:find("closed") then
			hl.monitor({ output = "eDP-1", disabled = true })
		end
	end
end)

-- External displays
hl.monitor({
	output = ultrawide,
	mode = "preferred",
	position = "auto-left",
	scale = 1,
})

hl.monitor({
	output = secondary,
	mode = "preferred",
	position = "auto-right",
	scale = 1,
})

-- Workspace → monitor assignments
-- 1-5 on the ultrawide, 6-10 on the secondary
for i = 1, 5 do
	hl.workspace_rule({ workspace = tostring(i), monitor = ultrawide })
end

for i = 6, 10 do
	hl.workspace_rule({ workspace = tostring(i), monitor = secondary })
end
