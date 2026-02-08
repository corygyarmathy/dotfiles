{
  lib,
  stdenv,
  makeWrapper,
  python3,
  ffmpeg,
  comskip,
}:

stdenv.mkDerivation {
  pname = "comskip-cut";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [
    python3
    ffmpeg
  ];

  installPhase = ''
    mkdir -p $out/bin

    # Install the EDL parser (reuse from comskip-chapters approach)
    cp ${./edl-to-segments.py} $out/bin/edl-to-segments
    chmod +x $out/bin/edl-to-segments

    # Install the main post-processing script
    cp ${./post-process.sh} $out/bin/post-process
    chmod +x $out/bin/post-process

    # Wrap scripts with dependencies
    wrapProgram $out/bin/edl-to-segments \
      --prefix PATH : ${
        lib.makeBinPath [
          python3
          ffmpeg
        ]
      }

    wrapProgram $out/bin/post-process \
      --prefix PATH : ${
        lib.makeBinPath [
          comskip
          ffmpeg
        ]
      } \
      --prefix PATH : $out/bin
  '';

  meta = with lib; {
    description = "Commercial cutting for Jellyfin recordings using comskip";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
