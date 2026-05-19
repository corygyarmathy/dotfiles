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
    playerctl -F metadata --format '{{status}}\t{{artist}} - {{title}}' 2>/dev/null | while IFS=$'\t' read -r status text; do
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
