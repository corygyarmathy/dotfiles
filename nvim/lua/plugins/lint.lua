return {
  { -- Linting
    'mfussenegger/nvim-lint',
    event = { 'BufReadPre', 'BufNewFile' },
    config = function()
      local lint = require 'lint'
      local lintConfig = vim.fn.stdpath 'config' .. '\\lua\\plugins\\linterConfigs\\'
      lint.linters_by_ft = {
        markdown = { 'markdownlint' },
        lua = { 'luacheck' },
      }
      -- Linter configs
      lint.linters.markdownlint.args = {
        '--config=' .. lintConfig .. 'markdownlint.yaml',
      }

      -- Create autocommand which carries out the actual linting
      -- on the specified events.
      local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
      vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
        group = lint_augroup,
        callback = function()
          require('lint').try_lint()
        end,
      })
    end,
  },
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
