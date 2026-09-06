# The geometry scale, named once.
#
# Item 6 of docs/plans/desktop-design.md. Every surface used to pick its own
# numbers: window rounding 16, waybar modules 8, rofi 16 outside and 10 inside,
# dunst 10; borders 1px on windows and 2px on everything beside them; gaps 5,
# and waybar margins of 3, 10, 15 and 20 in four different places. Nothing was
# wrong on its own and nothing agreed.
#
# Item 21 rotates the bar, which is the moment a scale either exists or gets
# reinvented. This is so that it exists.
#
# WHAT READS THIS. dunst is configured in Nix and reads these values directly.
# waybar's style.css, rofi's theme and hyprland's settings.lua are hand-written
# files deployed verbatim so that configs/ works on a machine without Nix -
# they cannot interpolate, and GTK 3 CSS has no custom properties for lengths
# the way it has @define-color for colour. So the scale reaches them the other
# way round: ./modules/home/desktop/geometry-scale.py asserts at build time
# that every length they name comes from here. Same bargain as the palette in
# lib/kanagawa-wave.nix - hand-written, portable, and gated.
{
  # Two radii, and the relationship between them is the point: 12 is
  # window-sized or overlay-sized (windows, rofi, dunst, and hyprlock and
  # swayosd when items 17 and 12 land), 8 is a chip inside a surface (waybar
  # modules, rofi rows).
  radius = {
    surface = 12;
    chip = 8;
  };

  # One border width everywhere, including window borders, which were 1px next
  # to the 2px bar sitting beside them - the kind of inconsistency that is felt
  # without being seen.
  border = 2;

  # Spacing is a multiple of the unit rather than a fixed list, so that a gap
  # nobody anticipated is still on the scale. 0 is always allowed.
  space = {
    unit = 8;

    # The two that get used by name often enough to deserve one.
    tight = 8;
    loose = 16;
  };
}
