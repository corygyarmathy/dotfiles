return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      ruff = { -- Python formatter & LSP
        init_options = {
          settings = {
            lint = {
              enable = false,
            },
          },
        },
      },
      basedpyright = { -- Python LSP
        settings = {
          basedpyright = {
            analysis = {
              diagnosticSeverityOverrides = {
                -- Categories: "error", "warning", "information", "hint" OR Boolean: true, false
                -- reportUnusedImport = false, -- reported by ruff
                -- reportUnusedVariable = "information",
                -- reportUnusedCallResult = "information",
                -- reportUnusedCallResult = false,
                -- reportMissingTypeArgument = false,
                -- reportMissingImports = false,
                -- reportMissingParameterType = false,
                -- reportUnknownArgumentType = false,
                -- reportUnknownLambdaType = false,
                -- reportUnknownMemberType = false,
                -- reportUnknownParameterType = false,
                -- reportUnknownVariableType = false,
              },
            },
          },
        },
      },
      nixd = {},
    },
  },
}
