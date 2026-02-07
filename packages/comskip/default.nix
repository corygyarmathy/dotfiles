{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  argtable2,
  ffmpeg,
  SDL2,
}:

stdenv.mkDerivation rec {
  pname = "comskip";
  version = "0.83";

  src = fetchFromGitHub {
    owner = "erikkaashoek";
    repo = "Comskip";
    rev = "V${version}";
    hash = "sha256-3bgwS+9agi0BkhOF+Hr593k0BRRCFiCGltgxoRqjT18=";
  };

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
  ];

  buildInputs = [
    argtable2
    ffmpeg
    SDL2
  ];

  # Allow warnings - using old dependencies
  env.NIX_CFLAGS_COMPILE = "-Wno-error";

  # Comskip uses autotools
  configureFlags = [
    "--bindir=${placeholder "out"}/bin"
  ];

  meta = with lib; {
    description = "Free commercial detector";
    homepage = "https://github.com/erikkaashoek/Comskip";
    license = licenses.lgpl21Plus;
    maintainers = [ ]; # Add your info if you want
    platforms = platforms.linux;
    mainProgram = "comskip";
  };
}
