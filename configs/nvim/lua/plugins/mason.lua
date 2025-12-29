return {
	-- Disable mason on NixOS since we manage packages with Nix
	{
		"mason-org/mason.nvim",
		enabled = not vim.g.is_nixos,
	},
	{
		"mason-org/mason-lspconfig.nvim",
		enabled = not vim.g.is_nixos,
	},
	{
		"jay-babu/mason-nvim-dap.nvim",
		enabled = not vim.g.is_nixos,
	},
}
