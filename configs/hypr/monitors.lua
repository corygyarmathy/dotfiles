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
