-- General settings, decoration, input, layout, and misc
-- https://wiki.hypr.land/Configuring/Basics/Variables/

hl.config({
	general = {
		gaps_in = 5,
		gaps_out = 5,
		border_size = 1,
		allow_tearing = false,
		resize_on_border = true,
		layout = "dwindle",
	},

	decoration = {
		rounding = 16,
		rounding_power = 2,

		blur = {
			enabled = true,
			brightness = 1.0,
			contrast = 1.0,
			noise = 0.01,
			vibrancy = 0.2,
			vibrancy_darkness = 0.5,
			passes = 4,
			size = 7,
			popups = true,
			popups_ignorealpha = 0.2,
		},
	},

	input = {
		kb_layout = "us",
		follow_mouse = 1,
		accel_profile = "flat",

		touchpad = {
			scroll_factor = 0.1,
			natural_scroll = true,
		},
	},

	dwindle = {
		preserve_split = true,
	},

	cursor = {
		no_hardware_cursors = true,
		inactive_timeout = 20,
	},

	render = {
		direct_scanout = true,
		cm_enabled = false, -- disable color management pipeline
	},

	misc = {
		force_default_wallpaper = 0,
	},

	xwayland = {
		force_zero_scaling = true,
	},

	debug = {
		disable_logs = false,
	},
})

-- Touchpad gesture: 3-finger horizontal swipe to switch workspace
hl.gesture({
	fingers = 3,
	direction = "horizontal",
	action = "workspace",
})
