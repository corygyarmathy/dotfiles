# packages/nixos-upgrade-scripts/default.nix
#
# Python package containing all NixOS upgrade scripts.
# These scripts handle checking, building, and applying updates.
{
  lib,
  python3Packages,
  makeWrapper,
  nix,
  git,
  nvd,
  fwupd,
  coreutils,
  gnugrep,
  sudo,
  systemd,
  util-linux,
  procps,
  libnotify,
}:
python3Packages.buildPythonApplication rec {
  pname = "nixos-upgrade-scripts";
  version = "1.0.0";

  src = ./src;

  format = "other";

  nativeBuildInputs = [ makeWrapper ];

  propagatedBuildInputs = [ ];

  installPhase = ''
    runHook preInstall

    # Install Python modules
    mkdir -p $out/lib/python
    cp -r *.py $out/lib/python/

    # Create bin directory
    mkdir -p $out/bin

    # Create wrapper scripts for each entry point
    # These set PYTHONPATH and wrap with required tools in PATH

    makeWrapper ${python3Packages.python.interpreter} $out/bin/nixos-upgrade-check \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/check_updates.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          nix
          git
          nvd
          fwupd
          coreutils
          gnugrep
          systemd
          sudo
        ]
      }

    makeWrapper ${python3Packages.python.interpreter} $out/bin/nixos-upgrade-build \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/background_build.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          nix
          git
          coreutils
          systemd
          util-linux
          sudo
        ]
      }

    makeWrapper ${python3Packages.python.interpreter} $out/bin/nixos-upgrade-apply \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/apply_updates.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          nix
          git
          nvd
          fwupd
          coreutils
          gnugrep
          systemd
          procps
          libnotify
          sudo
        ]
      }:/run/current-system/sw/bin

    makeWrapper ${python3Packages.python.interpreter} $out/bin/nixos-upgrade-waybar \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/waybar_status.py"

    makeWrapper ${python3Packages.python.interpreter} $out/bin/nixos-upgrade-waybar-click \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/waybar_click.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          systemd
          libnotify
          procps
        ]
      }

    runHook postInstall
  '';

  meta = with lib; {
    description = "NixOS upgrade management scripts";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
