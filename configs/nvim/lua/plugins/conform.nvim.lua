return {
	"stevearc/conform.nvim",
	opts = {
		formatters = {
			["markdownlint-cli2"] = {
				-- The canonical config lives at the repo root (see #219):
				-- the same file CI's treefmt and the harness resolve, so the
				-- three cannot disagree about the rules. The repo is checked
				-- out at ~/git/dotfiles on every host (modules/home/
				-- development/nvim.nix), which is what makes this path stable.
				command = "markdownlint-cli2",
				args = {
					"--config",
					vim.fn.expand("$HOME/git/dotfiles/.markdownlint-cli2.yaml"),
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
					return ctx.filename:find("digital-garden/lib/hugo/layouts/", 1, true) == nil
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
