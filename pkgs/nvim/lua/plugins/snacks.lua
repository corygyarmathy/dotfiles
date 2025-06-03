return {
  "folke/snacks.nvim",
  ---@type snacks.Config
  opts = {
    picker = {
      hidden = true,
      ignored = true,
      sources = {
        files = {
          hidden = true,
          -- ignored = true,
        },
      },
    },
    scroll = {
      enabled = false,
    },
  },
}
