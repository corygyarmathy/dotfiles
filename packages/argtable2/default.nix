{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
}:

stdenv.mkDerivation rec {
  pname = "argtable2";
  version = "2.13";

  src = fetchFromGitHub {
    owner = "jonathanmarvens";
    repo = "argtable2";
    rev = "argtable-${version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # We'll get this from the error
  };

  nativeBuildInputs = [
    autoreconfHook
  ];

  meta = with lib; {
    description = "ANSI C library for parsing GNU-style command-line options";
    homepage = "https://github.com/jonathanmarvens/argtable2";
    license = licenses.lgpl2Plus;
    platforms = platforms.unix;
    maintainers = [ ];
  };
}
