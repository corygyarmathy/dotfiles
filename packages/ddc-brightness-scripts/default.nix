# packages/ddc-brightness-scripts/default.nix
#
# Python package containing DDC/CI monitor brightness control scripts.
# These scripts handle automatic and manual brightness adjustment via DDC.
{
  lib,
  python3Packages,
  makeWrapper,
  ddcutil,
}:
python3Packages.buildPythonApplication rec {
  pname = "ddc-brightness-scripts";
  version = "1.0.0";

  src = ./src;

  format = "other";

  nativeBuildInputs = [ makeWrapper ];

  # astral is needed for sunrise/sunset calculations
  propagatedBuildInputs = with python3Packages; [
    astral
  ];

  installPhase = ''
    runHook preInstall

    # Install Python modules
    mkdir -p $out/lib/python
    cp -r *.py $out/lib/python/

    # Create bin directory
    mkdir -p $out/bin

    # Daemon script - runs in background, adjusts brightness automatically
    makeWrapper ${python3Packages.python.interpreter} $out/bin/ddc-brightness-daemon \
      --set PYTHONPATH "$out/lib/python:${python3Packages.astral}/${python3Packages.python.sitePackages}" \
      --add-flags "$out/lib/python/daemon.py" \
      --prefix PATH : ${lib.makeBinPath [ ddcutil ]}

    # CLI control script - manual brightness adjustment
    makeWrapper ${python3Packages.python.interpreter} $out/bin/ddc-brightness-ctl \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/ctl.py" \
      --prefix PATH : ${lib.makeBinPath [ ddcutil ]}

    # Waybar status script - outputs JSON for waybar custom module
    makeWrapper ${python3Packages.python.interpreter} $out/bin/ddc-brightness-waybar \
      --set PYTHONPATH "$out/lib/python" \
      --add-flags "$out/lib/python/waybar_ddc_status.py"

    runHook postInstall
  '';

  meta = with lib; {
    description = "DDC/CI monitor brightness control scripts";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
