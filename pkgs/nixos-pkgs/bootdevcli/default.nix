{
  lib,
  fetchFromGitHub,
  buildGoModule,
}:
let
  version = "1.7.1";
in
buildGoModule rec {
  pname = "bootdevcli";
  inherit version;
  src = fetchFromGitHub {
    owner = "bootdotdev";
    repo = "bootdev";
    rev = "v${version}";
    sha256 = "sha256-0vC+T5uCJVb6yKNWA+V4eitwNzuHZQIj3CnIR+5TBSs=";
  };

  vendorHash = "sha256-jhRoPXgfntDauInD+F7koCaJlX4XDj+jQSe/uEEYIMM=";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
    "-X main.currentSha=${src.rev}"
  ];

  meta = with lib; {
    homepage = "https://github.com/bootdotdev/bootdev";
    description = "The official command line tool for Boot.dev.";
    license = licenses.mit;
    maintainers = with maintainers; [ corygyarmathy ];
  };
}
