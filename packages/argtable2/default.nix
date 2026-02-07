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
    rev = "v${version}";
    hash = "sha256-K6++QVvpcPR+BYxbDRZ24sY0+PgIaQ3t1ktt3zZGh6Q=";
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
