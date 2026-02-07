{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "argtable2";
  version = "2.13";

  src = fetchurl {
    url = "mirror://sourceforge/argtable/argtable2-${version}.tar.gz";
    hash = "sha256-f3YW5nCGmHcnNFEkNNiXZQUT1B0+5ey8R56XBFbLYIo=";
  };

  meta = with lib; {
    description = "ANSI C library for parsing GNU-style command-line options";
    homepage = "http://argtable.sourceforge.net/";
    license = licenses.lgpl2Plus;
    platforms = platforms.unix;
    maintainers = [ ];
  };
}
