return {
  "folke/flash.nvim",
  opts = {
    -- Center the page after a jump, like <C-u>/<C-d> in keymaps.lua.
    -- `action` replaces flash's default jump, so replicate it, then `zz`.
    action = function(match, state)
      local jump = require("flash.jump")
      jump.jump(match, state)
      jump.on_jump(state)
      -- Skip centering in operator-pending mode so it can't interfere
      -- with operations like `ds<label>`.
      if vim.fn.mode(true):sub(1, 2) ~= "no" then
        vim.cmd("normal! zz")
      end
    end,
  },
}
