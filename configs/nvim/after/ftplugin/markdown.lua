-- Prose-friendly soft wrapping
vim.opt_local.wrap = true
vim.opt_local.linebreak = true -- wrap at word boundaries, not mid-word

-- Wrap lists preserving indents
vim.opt_local.breakindent = true
vim.opt_local.breakindentopt = "list:-1"
vim.opt_local.formatlistpat = [[^\s*[0-9]\+[.)]\s\+\|^\s*[-*+]\s\+\|^\s*>\s*]] -- Pattern for: - and >

-- Centre + cap width
require("no-neck-pain").enable()

-- Optional: spell-check (can be noisy with technical jargon)
-- vim.opt_local.spell = true

-- Optional: move by screen line through wrapped paragraphs.
-- Assumes default hjkl navigation — skip if your Colemak setup remaps these.
vim.keymap.set("n", "j", "gj", { buffer = true })
vim.keymap.set("n", "k", "gk", { buffer = true })
