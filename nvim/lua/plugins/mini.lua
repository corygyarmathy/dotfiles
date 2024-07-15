return { -- Collection of various small independent plugins/modules
  'echasnovski/mini.nvim',
  version = '*',
  dependencies = {
    'nvim-tree/nvim-web-devicons', -- used by mini-statusline
  },
  config = function()
    -- Better Around/Inside textobjects
    --
    -- Examples:
    --  - va)  - [V]isually select [A]round [)]paren
    --  - yinq - [Y]ank [I]nside [N]ext [']quote
    --  - ci'  - [C]hange [I]nside [']quote
    require('mini.ai').setup { n_lines = 500 }

    -- Add/delete/replace surroundings (brackets, quotes, etc.)
    --
    -- - saiw) - [S]urround [A]dd [I]nner [W]ord [)]Paren
    -- - sd'   - [S]urround [D]elete [']quotes
    -- - sr)'  - [S]urround [R]eplace [)] [']
    require('mini.surround').setup()

    -- require('mini.notify').setup {
    --   lsp_progress = { enable = false },
    -- }

    -- Simple and easy statusline.
    --  You could remove this setup call if you don't like it,
    --  and try some other statusline plugin
    local statusline = require 'mini.statusline'
    -- set use_icons to true if you have a Nerd Font
    statusline.setup { use_icons = vim.g.have_nerd_font }

    -- You can configure sections in the statusline by overriding their
    -- default behavior. For example, here we set the section for
    -- cursor location to LINE:COLUMN
    ---@diagnostic disable-next-line: duplicate-set-field
    statusline.section_location = function()
      return '%2l:%-2v'
    end
    -- Use mini notifications
    require('mini.notify').setup {
      lsp_progress = {
        enable = true,
      },
      window = {
        config = function()
          -- Set the mini notifications to be in the bottom right
          local has_statusline = vim.o.laststatus > 0
          local bottom_space = vim.o.cmdheight + (has_statusline and 1 or 0)
          return { anchor = 'SE', col = vim.o.columns, row = vim.o.lines - bottom_space }
        end,
      },
    }
    -- Force default Vim notifications to use mini.notify
    vim.notify = MiniNotify.make_notify()

    require('mini.starter').setup()
    -- ... and there is more!
    --  Check out: https://github.com/echasnovski/mini.nvim
  end,
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
