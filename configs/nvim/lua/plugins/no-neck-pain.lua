return {
	"shortcuts/no-neck-pain.nvim",
	version = "*",
	-- Load per-note on markdown; keep the commands for manual use too.
	ft = "markdown",
	cmd = { "NoNeckPain", "NoNeckPainResize" },
	opts = {
		width = 95, -- your max content width; tune 80–100
		autocmds = {
			enableOnVimEnter = false, -- we drive enable/disable ourselves (below)
			enableOnTabEnter = false,
			skipEnteringNoNeckPainBuffer = true,
		},
		buffers = {
			wo = { fillchars = "eob: " }, -- hide the ~ in the padding columns
		},
	},
	config = function(_, opts)
		local nnp = require("no-neck-pain")
		nnp.setup(opts)

		-- True when NNP is centering the *current tab* (its side buffers live here).
		-- Scanning windows is per-tab correct and stays in sync even if you toggle
		-- the plugin manually with :NoNeckPain.
		local function active_in_tab()
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "no-neck-pain" then
					return true
				end
			end
			return false
		end

		-- nil   -> ignore this buffer (special/floating), leave NNP as-is
		-- true  -> markdown file, want NNP on
		-- false -> normal non-markdown file, want NNP off
		local function want_enabled()
			local win = vim.api.nvim_get_current_win()
			if vim.api.nvim_win_get_config(win).relative ~= "" then
				return nil -- floating window (telescope, which-key, notifications, ...)
			end
			local buf = vim.api.nvim_get_current_buf()
			if vim.bo[buf].buftype ~= "" then
				return nil -- help/terminal/quickfix/nofile + NNP's own side buffers
			end
			return vim.bo[buf].filetype == "markdown"
		end

		local pending = false
		local function sync()
			if pending then
				return
			end
			pending = true
			vim.schedule(function()
				pending = false
				local want = want_enabled()
				if want == nil then
					return
				end
				local on = active_in_tab()
				if want and not on then
					pcall(nnp.enable)
				elseif not want and on then
					pcall(nnp.disable)
				end
			end)
		end

		vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "FileType", "TabEnter" }, {
			group = vim.api.nvim_create_augroup("NoNeckPainMarkdownOnly", { clear = true }),
			callback = sync,
		})

		-- Handle the buffer that just triggered loading (your first markdown file).
		sync()
	end,
}
