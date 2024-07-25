return { -- Autoformat
  'stevearc/conform.nvim',
  lazy = false,
  keys = {
    {
      '<leader>f',
      function()
        require('conform').format { async = true, lsp_fallback = true }
      end,
      mode = '',
      desc = '[F]ormat buffer',
    },
  },
  -- This will provide type hinting with LuaLS
  ---@module "conform"
  ---@type conform.setupOpts
  opts = {
    notify_on_error = true,
    format_on_save = function(bufnr)
      -- Disable "format_on_save lsp_fallback" for languages that don't
      -- have a well standardized coding style. You can add additional
      -- languages here or re-enable it for the disabled ones.
      local disable_filetypes = { c = true, cpp = true }
      return {
        timeout_ms = 500,
        lsp_fallback = not disable_filetypes[vim.bo[bufnr].filetype],
      }
    end,
    -- Set formatters for each file type
    formatters_by_ft = {
      lua = { 'stylua' },
      markdown = { 'markdownlint' },
      nix = { 'nixfmt' },
      -- Conform can also run multiple formatters sequentially
      -- python = { "isort", "black" },
      --
      -- You can use a sub-list to tell conform to run *until* a formatter
      -- is found.
      -- javascript = { { "prettierd", "prettier" } },
    },
    -- Customise formatters
    formatters = {
      markdownlint = {
        -- prepend_args = function()
        --   -- Different file paths depending on whether it's on Windows or not
        --   if vim.fn.has 'win32' == 1 and vim.fn.has 'wsl' == 0 then
        --     return '--config=' .. vim.fn.stdpath 'config' .. '\\lua\\plugins\\linterConfigs\\' .. 'markdownlint.yaml'
        --   else
        --     return '--config=' .. vim.fn.stdpath 'config' .. '/lua/plugins/linterConfigs/' .. 'markdownlint.yaml'
        --   end
        -- end,
        prepend_args = {
          '--config=' .. vim.fn.stdpath 'config' .. '/lua/plugins/linterConfigs/' .. 'markdownlint.yaml',
        },
      },
    },
  },
}

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
