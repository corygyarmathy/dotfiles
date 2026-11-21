# hzeller/rpi-rgb-led-matrix: drives HUB75 RGB LED panels from a Raspberry
# Pi's GPIO header by writing the SoC's GPIO registers directly. rpi01 uses it
# behind an Adafruit RGB Matrix Bonnet (`--led-gpio-mapping=adafruit-hat-pwm`).
#
# Built with upstream's Makefiles rather than its CMakeLists.txt: the CMake
# build exists for the Python bindings, requires a Python interpreter even for
# the bare library, and builds none of the demos or utilities, which are what
# make a panel testable without writing code.
#
# Upstream has no tags or releases, so this tracks master.
{
  lib,
  stdenv,
  fetchFromGitHub,
  pkg-config,
  graphicsmagick,
  libwebp,
  nix-update,
}:

stdenv.mkDerivation {
  pname = "rpi-rgb-led-matrix";
  version = "0-unstable-2026-11-17";

  src = fetchFromGitHub {
    owner = "hzeller";
    repo = "rpi-rgb-led-matrix";
    rev = "a8dd6854580b7e2b18d0f697cec94415dd8824cd";
    hash = "sha256-nkmvOTcYRRlVjeLr4+hPNxqckrFYBE33pcbLuLehDN8=";
  };

  nativeBuildInputs = [ pkg-config ];

  buildInputs = [
    graphicsmagick
    libwebp
  ];

  makeFlags = [
    # config.mk adds -march=native unless the compiler is literally named
    # aarch64-linux-gnu-*. In a native build that tunes for the builder - CI's
    # arm64 runner, not the Pi's Cortex-A72 - and may emit instructions the
    # Pi does not have.
    "CPU_ARCH_FLAGS="
    # config.mk builds with -flto, so the static library has to be archived
    # with the LTO-aware wrapper. It names the bare `gcc-ar`, which is not on
    # PATH under a prefixed (cross) compiler.
    "AR=${stdenv.cc.targetPrefix}gcc-ar"
    "PREFIX=${placeholder "out"}"
  ];

  # The Makefiles shell out to GraphicsMagick++-config unless these are set,
  # and that script describes the build platform's GraphicsMagick: under cross
  # compilation it hands the target linker the build machine's libraries.
  # pkg-config resolves against the target.
  preBuild = ''
    export MAGICK_CXXFLAGS="$($PKG_CONFIG --cflags GraphicsMagick++)"
    export MAGICK_LDFLAGS="$($PKG_CONFIG --libs GraphicsMagick++)"
  '';

  # Off by default for a plain Makefile build, and this one runs under QEMU on
  # the laptop (hosts/xps15), where serial make takes over ten minutes. Each
  # sub-make reaches lib/ through a single FORCE target, so no two jobs build
  # the library at once.
  enableParallelBuilding = true;

  # The top-level Makefile builds lib/ and examples-api-use/; utils/ (image
  # viewer, text scroller) is separate. `simple` is utils/ without the ffmpeg
  # video viewer. Hand-run, so it takes the job count buildPhase would.
  postBuild = ''
    make -C utils -j$NIX_BUILD_CORES $makeFlags simple
  '';

  installPhase = ''
    runHook preInstall

    make -C lib $makeFlags install
    install -m 644 lib/librgbmatrix.a $out/lib/

    install -d $out/bin
    for b in demo minimal-example c-example text-example scrolling-text-example \
             clock ledcat input-example pixel-mover; do
      install -m 755 examples-api-use/$b $out/bin/
    done
    install -m 755 utils/led-image-viewer utils/text-scroller \
                   utils/frame-sequence-player $out/bin/

    # BDF fonts, which text-scroller and the text examples take a path to.
    install -d $out/share/rpi-rgb-led-matrix/fonts
    install -m 644 fonts/*.bdf $out/share/rpi-rgb-led-matrix/fonts/

    runHook postInstall
  '';

  passthru = {
    # Opt in to .github/workflows/package-update.yml; see packages/comskip for
    # why this is explicit and why nix-update is wrapped.
    autoUpdate = true;
    updateScript = [
      "packages/update-via-nix-update.sh"
      (lib.getExe nix-update)
      "rpi-rgb-led-matrix"
      "--version=branch"
    ];
  };

  meta = {
    description = "Library and tools for driving HUB75 RGB LED matrix panels from a Raspberry Pi";
    homepage = "https://github.com/hzeller/rpi-rgb-led-matrix";
    license = lib.licenses.gpl2Only;
    # Only useful on a Pi, but it compiles anywhere, and CI evaluates every
    # package on x86_64-linux - narrowing this would make that evaluation throw.
    platforms = lib.platforms.linux;
    mainProgram = "demo";
  };
}
