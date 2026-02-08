{
  lib,
  stdenv,
  python3,
  ffmpeg,
  comskip,
  makeWrapper,
  bash,
  coreutils,
}:

stdenv.mkDerivation {
  pname = "comskip-chapters";
  version = "1.0.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [ python3 ];

  installPhase = ''
    mkdir -p $out/bin

    # Install Python script for EDL to chapters conversion
    cp edl-to-chapters.py $out/bin/edl-to-chapters
    chmod +x $out/bin/edl-to-chapters

    # Install post-processing wrapper script
    cp post-process.sh $out/bin/comskip-post-process
    chmod +x $out/bin/comskip-post-process

    # Wrap both scripts with necessary dependencies in PATH
    wrapProgram $out/bin/edl-to-chapters \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg ]}

    wrapProgram $out/bin/comskip-post-process \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          ffmpeg
          comskip
          coreutils
        ]
      } \
      --prefix PATH : $out/bin
  '';

  meta = with lib; {
    description = "Tools for embedding comskip chapters into video files";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
