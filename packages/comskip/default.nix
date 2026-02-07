{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  argtable,
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
    argtable
    ffmpeg
    SDL2
  ];

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
