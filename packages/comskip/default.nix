{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  argtable2,
  ffmpeg,
  SDL2,
  nix-update,
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

  # Upstream tags are inconsistent - V0.83, 0.82.009, v0.82.003, v0.81.089 - and
  # `rev` here is built as "V${version}". The regex keeps nix-update to the
  # V-prefixed releases so it cannot propose a version whose tag does not exist
  # under that template.
  passthru = {
    # Opt in to .github/workflows/package-update.yml. Explicit rather than
    # inferred from updateScript's presence: nixpkgs' buildPythonApplication
    # sets a default updateScript of its own, so every Python package here
    # would otherwise be picked up and "updated" against no upstream at all.
    autoUpdate = true;

    # Wrapped rather than nix-update-script directly: nix-update narrates to
    # stdout even when it changes nothing, and the contract is silence when
    # current. See packages/update-via-nix-update.sh.
    #
    # Upstream tags are inconsistent - V0.83, 0.82.009, v0.82.003 - and `rev`
    # here is built as "V${version}", so the regex keeps nix-update to the
    # V-prefixed releases and it cannot propose a version whose tag would not
    # exist under that template.
    updateScript = [
      "packages/update-via-nix-update.sh"
      (lib.getExe nix-update)
      "comskip"
      "--version-regex"
      "^V(.*)"
    ];
  };

  meta = with lib; {
    description = "Free commercial detector";
    homepage = "https://github.com/erikkaashoek/Comskip";
    license = licenses.lgpl21Plus;
    maintainers = [ ]; # Add your info if you want
    platforms = platforms.linux;
    mainProgram = "comskip";
  };
}
