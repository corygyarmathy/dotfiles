# packages/nixos-remote-install/default.nix
#
# Python package for automated NixOS remote installation.
# Wraps nixos-anywhere with sops-nix key bootstrapping support.
{
  lib,
  python3Packages,
  makeWrapper,
  # Runtime dependencies
  openssh,
  nix,
  sops,
  ssh-to-age,
  age,
  coreutils,
  gnugrep,
  util-linux,
}:
python3Packages.buildPythonApplication rec {
  pname = "nixos-remote-install";
  version = "1.0.0";

  src = ./src;

  format = "other";

  nativeBuildInputs = [ makeWrapper ];

  # No Python dependencies - pure stdlib
  propagatedBuildInputs = [ ];

  installPhase = ''
    runHook preInstall

    # Install Python modules
    mkdir -p $out/lib/python
    cp -r *.py $out/lib/python/

    # Create bin directory
    mkdir -p $out/bin

    # Main CLI entry point
    makeWrapper ${python3Packages.python.interpreter} $out/bin/nixos-remote-install \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/cli.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          openssh
          nix
          sops
          ssh-to-age
          age
          coreutils
          gnugrep
          util-linux
        ]
      }

    runHook postInstall
  '';

  meta = with lib; {
    description = "Automated NixOS remote installation with nixos-anywhere and sops-nix support";
    longDescription = ''
      A tool that automates NixOS installation on remote machines using nixos-anywhere.
      
      Features:
      - Handles sops-nix key bootstrapping (the chicken-and-egg problem)
      - Pre-generates SSH host keys and derives age keys
      - Updates .sops.yaml and re-encrypts secrets
      - Runs nixos-anywhere with correct configuration
      
      Usage:
        nixos-remote-install homelab02 192.168.1.100 --disk /dev/nvme0n1
    '';
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "nixos-remote-install";
  };
}
