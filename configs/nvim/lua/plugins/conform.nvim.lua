return {
	"stevearc/conform.nvim",
	opts = {
		formatters = {
			["markdownlint-cli2"] = {
				-- The canonical config is the repo-root .markdownlint-cli2.yaml
				-- (see #219): the same file CI's treefmt and the harness
				-- resolve, so the three cannot disagree about the rules. It
				-- reaches this path through the nvim config symlink
				-- (modules/home/development/nvim.nix points ~/.config/nvim
				-- at configs/nvim, which carries a symlink to the root
				-- file) - nothing here names where the repo is checked out.
				command = "markdownlint-cli2",
				args = {
					"--config",
					vim.fn.expand("$HOME/.config/nvim/.markdownlint-cli2.yaml"),
					"--fix",
					"$FILENAME",
				},
				stdin = false,
				-- CI (treefmt) does not run markdownlint on SKILL.md: the
				-- skill frontmatter-plus-prose format carries no h1 by spec.
				-- Skip it here too, so a save cannot "fix" what the gate
				-- will not check.
				condition = function(_, ctx)
					return ctx.filename:sub(-8) ~= "SKILL.md"
				end,
			},
			-- CI (treefmt) does not run prettier on the garden's Hugo
			-- layouts: Go actions inside tags are SyntaxErrors to its HTML
			-- parser, and the layouts it can parse it reflows across action
			-- boundaries. Skip them here too, so a save cannot mangle what
			-- the gate never checks. (This replaces LazyVim's own prettier
			-- condition, which only asks whether a parser exists - true for
			-- every file type prettier handles in this repo.)
			prettier = {
				condition = function(_, ctx)
					local path = ctx.filename
					-- CI (treefmt) also skips the palette's generated files
					-- (see the excludes in treefmt.toml): write-palette owns
					-- them and the host builds assert them against the
					-- generator, so a save must not reformat what the gate
					-- does not check.
					for _, generated in ipairs({
						"configs/waybar/kanagawa-wave.css",
						"configs/waybar/calendar.jsonc",
						"configs/swayosd/style.css",
					}) do
						if path:find(generated, 1, true) ~= nil then
							return false
						end
					end
					return path:find("digital-garden/lib/hugo/layouts/", 1, true) == nil
				end,
			},
		},
		formatters_by_ft = {
			-- Python formats with black everywhere: CI, the harness and now
			-- the editor. The ruff LSP's formatter and black disagree, and
			-- without a conform entry the editor follows the LSP.
			python = { "black" },
		},
	},
}
