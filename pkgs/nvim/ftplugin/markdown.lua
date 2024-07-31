-- Changing vim config for markdown files

-- Move up and down by displayed lines
-- This handles wrapped text much better

-- vim.keymap.set('n', 'j', 'gj')
-- vim.keymap.set('n', 'k', 'gk')

-- Turn on auto-correct (English-Great Britain)
vim.opt.spelllang = 'en_gb'
vim.opt.spell = true

-- Handling tabs
-- vim.opt.expandtab = false
-- vim.opt.tabstop = 4
-- vim.opt.shiftwidth = 4

-- Handling wrapping / width
vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt_local.columns = 80
-- vim.opt.textwidth = 80

--                    + 't'    -- auto-wrap text using textwidth
--                    + 'c'    -- auto-wrap comments using textwidth
--                    + 'r'    -- auto insert comment leader on pressing enter
--                    - 'o'    -- don't insert comment leader on pressing o
--                    + 'q'    -- format comments with gq
--                    - 'a'    -- don't autoformat the paragraphs (use some formatter instead)
--                    + 'n'    -- autoformat numbered list
--                    - '2'    -- I am a programmer and not a writer
--                    + 'j'    -- Join comments smartly
-- vim.o.formatoptions = 't'
-- Show the 'nbsp' character as a normal space
vim.opt.listchars = { nbsp = ' ' }
