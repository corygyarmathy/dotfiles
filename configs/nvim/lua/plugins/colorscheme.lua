return {
	-- You can easily change to a different colorscheme.
	-- Change the name of the colorscheme plugin below, and then
	-- change the command in the config to whatever the name of that colorscheme is.
	--
	-- If you want to see what colorschemes are already installed, you can use `:Telescope colorscheme`.
	{
		"rebelot/kanagawa.nvim",
		enabled = true,
		lazy = false,
		priority = 1000, -- Make sure to load this before all the other start plugins.
		opts = {
			transparent = true,
			colors = {
				theme = {
					all = {
						ui = {
							-- Remove background colour of gutter, making it transparent
							bg_gutter = "none",
						},
					},
				},
			},
			overrides = function(colors)
				local theme = colors.theme
				return {
					-- Remove background colour of floating windows, making them transparent
					NormalFloat = { bg = "none" },
					FloatBorder = { bg = "none" },
					FloatTitle = { bg = "none" },

					-- Save an hlgroup with dark background and dimmed foreground
					-- so that you can use it where your still want darker windows.
					-- E.g.: autocmd TermOpen * setlocal winhighlight=Normal:NormalDark
					NormalDark = { fg = theme.ui.fg_dim, bg = theme.ui.bg_m3 },

					-- Popular plugins that open floats will link to NormalFloat by default;
					-- set their background accordingly if you wish to keep them dark and borderless
					LazyNormal = { bg = theme.ui.bg_m3, fg = theme.ui.fg_dim },
					MasonNormal = { bg = theme.ui.bg_m3, fg = theme.ui.fg_dim },
				}
			end,
		},
	},
	-- Configure LazyVim to load theme
	{
		"LazyVim/LazyVim",
		opts = {
			colorscheme = "kanagawa",
		},
	},
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
