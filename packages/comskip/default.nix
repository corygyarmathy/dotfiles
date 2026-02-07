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

  # Fix compatibility issues with modern compilers and FFmpeg
  postPatch = ''
    # Fix OutputFrame declaration to match definition (line 981)
    sed -i '981s/OutputFrame();/OutputFrame(int frame_number);/' comskip.c

    # Remove ticks_per_frame usage (deprecated in FFmpeg 5.0+)
    # Replace with constant 1, which is correct for most codecs
    # Only replace when it's being read (right side), not when assigned (left side)
    sed -i 's/\* is->dec_ctx->ticks_per_frame/* 1/g' mpeg2dec.c
    sed -i 's/\/ is->dec_ctx->ticks_per_frame/\/ 1/g' mpeg2dec.c

    # Comment out the assignment line since we're using constant 1
    sed -i 's/^\( *\)is->dec_ctx->ticks_per_frame = 1;/\1\/\/ is->dec_ctx->ticks_per_frame = 1; \/\/ Not needed - using constant/' mpeg2dec.c
  '';

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
