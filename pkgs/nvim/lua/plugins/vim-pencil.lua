return {
  'preservim/vim-pencil',
  ft = 'markdown, text',
  lazy = true,
  init = function()
    vim.g['pencil#wrapModeDefault'] = 'soft'
  end,
}
