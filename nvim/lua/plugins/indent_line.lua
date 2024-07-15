return {
  -- Add indentation guides even on blank lines
  'lukas-reineke/indent-blankline.nvim',
  version = '*',
  -- Enable `lukas-reineke/indent-blankline.nvim`
  -- See `:help ibl`
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  config = function()
    -- local ibl = require 'ibl'

    local scope = 'focus'
    local indent = 'passive'

    local hooks = require 'ibl.hooks'

    hooks.register(hooks.type.HIGHLIGHT_SETUP, function()
      vim.api.nvim_set_hl(0, 'focus', { fg = '#7486bd' })
      vim.api.nvim_set_hl(0, 'passive', { fg = '#41425e' })
    end)

    require('ibl').setup {
      scope = { highlight = scope },
      indent = { highlight = indent, char = '│' },
    }
  end,
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
