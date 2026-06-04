-- Prose-friendly soft wrapping
vim.opt_local.wrap = true
vim.opt_local.linebreak = true -- wrap at word boundaries, not mid-word

-- Centre + cap width, but only inside the notes vault
local notes = vim.fn.expand("~/git/personal-notes")
local path = vim.api.nvim_buf_get_name(0)
if path ~= "" and path:sub(1, #notes) == notes then
	pcall(function()
		require("no-neck-pain").enable()
	end)
end

-- Optional: spell-check (can be noisy with technical jargon)
-- vim.opt_local.spell = true

-- Optional: move by screen line through wrapped paragraphs.
-- Assumes default hjkl navigation — skip if your Colemak setup remaps these.
vim.keymap.set("n", "j", "gj", { buffer = true })
vim.keymap.set("n", "k", "gk", { buffer = true })
