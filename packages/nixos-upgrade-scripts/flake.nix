{
  description = "Python development environment with Ruff and Pyright";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        # Import packages from the main nixpkgs input (nixos-unstable)
        unstablePkgs = import nixpkgs {
          inherit system;
        };

        # --- Pinning Logic ---
        # Define the revision (commit hash or branch) for the older nixpkgs source
        # Using a stable branch like nixos-23.11 is often reliable for older versions.
        # You could also find a specific commit hash from nixos-unstable before the breakage.
        stableNixpkgsRev = "nixos-26.05";

        # Fetch the older nixpkgs source
        stableNixpkgs =
          import
            (fetchTarball {
              url = "https://github.com/NixOS/nixpkgs/archive/${stableNixpkgsRev}.tar.gz";
              sha256 = "0lc1d2hh5bmzqv7z1bbx8xdxl8p2lvvc7f70hsb2h8xxk9c6lzrx"; # Optional but recommended for reproducibility
              # You can get the sha256 by running `nix-prefetch-url https://github.com/NixOS/nixpkgs/archive/nixos-26.05.tar.gz`
            })
            {
              inherit system;
            };

        # Select the specific version of the package you want to pin
        # Ensure you use the correct pythonPackages set (e.g., python3Packages) from the stable source
        # pinnedRequestsRatelimiter = stableNixpkgs.python3Packages.requests-ratelimiter;
        # --- End Pinning Logic ---

        # Use the python interpreter from the unstable source (generally desired)
        python = unstablePkgs.python3;

        # Define the list of Python packages, getting most from unstable
        pythonPackagesList = with unstablePkgs.python3Packages; [
          pytest
          pytest-mock
        ];

        # Combine the unstable packages list with the single pinned package
        pythonPackages = python.withPackages (ps: pythonPackagesList ++ [ ]); # add package in square brackets

      in
      {
        devShells.default = unstablePkgs.mkShell {
          # Use mkShell from unstable
          name = "python-dev-shell";

          buildInputs = [
            python # The specific python derivation (from unstable)
            pythonPackages # The python derivation *with* all packages (mixing unstable and stable)
            unstablePkgs.ruff # Tools like ruff from unstable
            unstablePkgs.pyright # Tools like pyright from unstable
          ];

          shellHook = ''
            export PYTHONPATH="$PWD:$PYTHONPATH"
            echo "🐍 Python flake dev shell ready"
          '';
        };
      }
    );
}
