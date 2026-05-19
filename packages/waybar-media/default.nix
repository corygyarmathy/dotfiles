# waybar-media/default.nix
{
  lib,
  writeShellApplication,
  playerctl,
}:

writeShellApplication {
  name = "waybar-media";

  runtimeInputs = [ playerctl ];

  text = ''
    playerctl -F metadata --format '{{status}}%%{{artist}} - {{title}}' 2>/dev/null | while read -r line; do
      status="''${line%%%%*}"
      text="''${line#*%%}"
      if [[ "$status" == "Playing" ]]; then
        echo "$text"
      else
        echo ""
      fi
    done
  '';

  meta = {
    description = "Waybar media player module using playerctl";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "waybar-media";
  };
}
