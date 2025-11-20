return {
	"folke/snacks.nvim",
	---@type snacks.Config
	opts = {
		image = {
			img_dirs = { "img", "images", "assets", "static", "public", "media", "attachments", "files", "Files" },
		},
		picker = {
			hidden = true,
			ignored = true,
			sources = {
				files = {
					hidden = true,
					-- ignored = true,
				},
			},
		},
		scroll = {
			enabled = false,
		},
	},
}
