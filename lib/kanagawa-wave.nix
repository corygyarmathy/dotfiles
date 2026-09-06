# Kanagawa Wave, named once.
#
# Item 5 of docs/plans/desktop-design.md. Principle 5's rule is that a colour
# is named in exactly one file; before this, Kanagawa Wave was written out by
# hand in five - the waybar CSS, the rofi rasi, the clock's calendar markup,
# the modifier indicator's Python, and (as a different design entirely) the
# lock screen - and contradicted by a sixth, the base16 scheme stylix reads.
# This is that one file.
#
# WHY THE REPOSITORY OWNS THE PALETTE RATHER THAN READING STYLIX'S.
#
# `base16-schemes/kanagawa.yaml` is a sixteen-slot *reduction* of Kanagawa
# Wave, and eight of the colours this desktop actually renders have no slot in
# it: sumiInk2, sumiInk3, waveBlue2, waveRed, springGreen, springBlue,
# roninYellow and carpYellow. The scheme's green is autumnGreen #76946A where
# the bar draws springGreen #98BB6C; its yellow is boatYellow2 where the bar
# draws roninYellow. So "generate the colour files from
# `config.lib.stylix.colors`" could not have been done without either shifting
# the palette or naming those eight colours somewhere else - which is the
# duplication this item exists to remove.
#
# So the direction is inverted: this file is the source, and stylix is handed
# `scheme` below. GTK, Qt, dunst, hyprland's borders, ghostty and nvim now come
# from the same file as waybar, rofi and (when items 12 and 17 land) swayosd and
# hyprlock. `scheme` is byte-identical to the upstream YAML, so adopting it
# changed nothing that was already themed; what it bought is that the extra
# eight colours have somewhere to live, and that the palette stops moving
# underneath the machine when `base16-schemes` updates.
#
# TWO LAYERS, AND WHICH ONE TO USE.
#
# `colours` names the pigment. `roles` names the job. A surface should read
# `roles`: it is the vocabulary the whole desktop shares, and a role that gains
# a user is how a colour earns its place. Reaching past it into `colours` is
# for the one case that has no widget to theme - see `calendar` below.
{ lib }:
let
  # ── The pigment ────────────────────────────────────────────────────────────
  #
  # Kanagawa Wave, by its own names, from https://github.com/rebelot/kanagawa.nvim.
  # Only the colours this desktop renders are listed; the palette upstream is
  # larger, and an unused entry here would be the same liability as an unused
  # theme file.
  colours = {
    # Ink - the dark surfaces, lightest last
    sumiInk0 = "#16161D";
    sumiInk1 = "#1F1F28";
    sumiInk2 = "#2A2A37";
    sumiInk3 = "#363646";
    sumiInk4 = "#54546D";

    # Wave - the selection blues
    waveBlue1 = "#223249";

    # Paper - the light foregrounds
    fujiWhite = "#DCD7BA";
    oldWhite = "#C8C093";
    fujiGray = "#727169";
    katanaGray = "#717C7C";

    # Ronin - the warm accents
    autumnRed = "#C34043";
    waveRed = "#E46876";
    surimiOrange = "#FFA066";
    roninYellow = "#FF9E3B";
    boatYellow2 = "#C0A36E";
    carpYellow = "#E6C384";

    # Spring - the cool accents
    autumnGreen = "#76946A";
    springGreen = "#98BB6C";
    waveAqua1 = "#6A9589";
    springBlue = "#7FB4CA";
    crystalBlue = "#7E9CD8";
    oniViolet = "#957FB8";
    sakuraPink = "#D27E99";
  };

  # ── The vocabulary ─────────────────────────────────────────────────────────
  #
  # Grouped rather than a flat attrset so the generated files come out with the
  # same sections and the same explanations a hand-written theme would have
  # had. Order here is order there.
  #
  # Every role below has at least one user. Two that did not survive the audit:
  # `accent-primary` (waveAqua1) was declared by the waybar theme and referenced
  # by nothing, and rofi's `accent2` (oniViolet) likewise - a role nothing reads
  # is drift waiting to happen, the same as a theme nothing renders. What was
  # `accent-secondary` is now simply `accent`, because there is no longer a
  # first one for it to be second to.
  groups = [
    {
      title = "Backgrounds";
      note = "Layered darkest to lightest.";
      roles = [
        {
          name = "bg-base";
          colour = "sumiInk0";
          note = "darkest surface - module backgrounds, tooltips";
        }
        {
          name = "bg-backdrop";
          colour = "sumiInk0";
          alpha = "CC";
          note = "the same, translucent - rofi's window behind its own chrome";
        }
        {
          name = "bg-surface";
          colour = "sumiInk1";
          note = "default background - the layer most things sit on";
        }
        {
          name = "bg-overlay";
          colour = "sumiInk2";
          note = "raised chrome - tooltip borders, rofi's input bar";
        }
        {
          name = "bg-raised";
          colour = "sumiInk3";
          note = "separators and elevated surfaces";
        }
        {
          name = "bg-hover";
          colour = "waveBlue1";
          note = "hover and selection";
        }
      ];
    }
    {
      title = "Foreground";
      note = "Text, brightest to dimmest.";
      roles = [
        {
          name = "fg-primary";
          colour = "fujiWhite";
          note = "primary text";
        }
        {
          name = "fg-secondary";
          colour = "oldWhite";
          note = "secondary text";
        }
        {
          name = "fg-muted";
          colour = "fujiGray";
          note = "placeholders and comments";
        }
        {
          name = "fg-disabled";
          colour = "sumiInk4";
          note = "disabled and inactive";
        }
      ];
    }
    {
      title = "Structure";
      note = "";
      roles = [
        {
          name = "border";
          colour = "sumiInk4";
          note = "borders and separators";
        }
        {
          name = "accent";
          colour = "springBlue";
          note = "the accent - prominent chrome that is not carrying a state";
        }
      ];
    }
    {
      title = "Semantic states";
      note = "What a colour *means*. Nothing here is decorative.";
      roles = [
        {
          name = "danger";
          colour = "autumnRed";
          note = "errors, critical states, destructive actions";
        }
        {
          name = "danger-bright";
          colour = "waveRed";
          note = "the same, where it must carry against a selection";
        }
        {
          name = "warning";
          colour = "roninYellow";
          note = "warnings, overrides, updates available";
        }
        {
          name = "success";
          colour = "springGreen";
          note = "healthy, complete, up to date";
        }
        {
          name = "info";
          colour = "crystalBlue";
          note = "informational and neutral-active";
        }
        {
          name = "secondary";
          colour = "oniViolet";
          note = "second informational voice - disk, audio, applying";
        }
        {
          name = "highlight";
          colour = "sakuraPink";
          note = "decorative, attention-drawing - the media player";
        }
      ];
    }
  ];

  # ── The one role two formats spell differently ─────────────────────────────
  #
  # `bg-backdrop` is a colour with an opacity, and rasi and GTK 3 CSS disagree
  # about how to write one. rofi takes the eight-digit `#RRGGBBAA` that the
  # palette carries; GTK has no such notation, and `#16161DCC` there is not a
  # colour it renders opaque but a parse error - which aborts the rest of the
  # stylesheet and stops waybar from starting at all. So a role that only rofi
  # reads was enough to take the bar down with it.
  #
  # GTK's `alpha()` takes the opacity as a fraction, so the byte is divided
  # here and the pigment is still written out as the same hex as every other
  # line in the file. Nix prints a float to six places; the match trims the
  # zeros back off, and `removeSuffix` catches the "1." a fully opaque byte
  # would leave behind.
  fraction =
    hex:
    lib.removeSuffix "." (lib.head (lib.match "(.*[^0])0*" (toString (lib.fromHexString hex / 255.0))));

  cssValue =
    role:
    if role ? alpha then
      "alpha(${colours.${role.colour}}, ${fraction role.alpha})"
    else
      colours.${role.colour};

  flatRoles = lib.listToAttrs (
    lib.concatMap (
      group:
      map (role: {
        inherit (role) name;
        value = colours.${role.colour} + (role.alpha or "");
      }) group.roles
    ) groups
  );

  # `lib.fixedWidthString` recurses by the *byte* length of its filler, so it
  # cannot pad with a box-drawing character. These two do.
  repeat = n: s: lib.concatStrings (lib.genList (_: s) (lib.max n 0));
  pad = width: s: repeat (width - lib.stringLength s) " ";

  # A generated file says so, and says how to put it back if it is edited by
  # hand. The build gates in waybar.nix and rofi.nix are what notice that it
  # needs to be.
  #
  # Kept as a list of lines rather than a block so that `comment` can leave a
  # blank line blank instead of trailing the comment marker with a space.
  banner = what: [
    "Generated from lib/kanagawa-wave.nix. Do not edit."
    ""
    "A copy is checked in so that ${what} works on a machine without Nix, the"
    "way everything under configs/ does. The build asserts the two agree, so an"
    "edit here fails `nixos-rebuild switch` and fails CI rather than drifting"
    "quietly. To change a colour, change the palette and run:"
    ""
    "    nix run .#write-palette"
  ];

  comment =
    marker: lines:
    lib.concatStringsSep "\n" (map (line: lib.removeSuffix " " "${marker} ${line}") lines);
in
rec {
  inherit colours groups;

  roles = flatRoles;

  # ── For stylix ─────────────────────────────────────────────────────────────
  #
  # Byte-identical to `base16-schemes/share/themes/kanagawa.yaml`, which is
  # what `modules/nixos/stylix.nix` read before this file existed. Adopting it
  # is deliberately a no-op for everything stylix already themed; the point is
  # that the sixteen slots and the eight colours outside them now come from one
  # place.
  scheme = {
    system = "base16";
    name = "Kanagawa";
    author = "Tommaso Laurenzi (https://github.com/rebelot)";
    variant = "dark";
    palette = {
      base00 = colours.sumiInk1;
      base01 = colours.sumiInk0;
      base02 = colours.waveBlue1;
      base03 = colours.sumiInk4;
      base04 = colours.fujiGray;
      base05 = colours.fujiWhite;
      base06 = colours.oldWhite;
      base07 = colours.katanaGray;
      base08 = colours.autumnRed;
      base09 = colours.surimiOrange;
      base0A = colours.boatYellow2;
      base0B = colours.autumnGreen;
      base0C = colours.waveAqua1;
      base0D = colours.crystalBlue;
      base0E = colours.oniViolet;
      base0F = colours.sakuraPink;
    };
  };

  # ── Renderers ──────────────────────────────────────────────────────────────
  #
  # One per surface that cannot read another's format. Each emits the whole
  # file, including its header, so that what is checked in is exactly what the
  # build produces and `diff` is the entire check.

  # waybar. GTK 3 CSS has no custom properties, so `@define-color` is the only
  # indirection available - which is why the layout in style.css can stay
  # hand-written and hex-free while this half is generated.
  toCss = ''
    /*
     * Waybar colours: Kanagawa Wave
     *
    ${comment " *" (banner "waybar")}
     *
     * style.css names these roles and never a hex. To retheme the bar, point
     * the palette at different pigment; the role names are the interface and
     * do not change.
     */
    ${lib.concatStringsSep "\n" (
      map (group: ''

        /* ── ${group.title} ${repeat (62 - lib.stringLength group.title) "─"} */
        ${lib.optionalString (group.note != "") "/* ${group.note} */\n"}${
          lib.concatStringsSep "\n" (
            map (
              role:
              "/* ${role.colour}: ${role.note} */\n"
              + "@define-color ${role.name}${pad 15 role.name}${cssValue role};"
            ) group.roles
          )
        }'') groups
    )}
  '';

  # rofi. Imported by themes/kanagawa-wave.rasi, which keeps the layout.
  # Relative imports resolve against the including file's directory, so the two
  # travel together.
  toRasi = ''
    /*
     * Rofi colours: Kanagawa Wave
     *
    ${comment " *" (banner "rofi")}
     *
     * The role names are waybar's. Two files calling the same colour by two
     * names is what item 5 was about; this is the half that stops it.
     */

    * {
    ${
      lib.concatStringsSep "\n" (
        map (group: ''
              /* ── ${group.title} ${repeat (58 - lib.stringLength group.title) "─"} */
          ${lib.concatStringsSep "\n" (
            map (
              role:
              "    ${role.name}:${pad 17 role.name}${flatRoles.${role.name}};"
              + pad 11 flatRoles.${role.name}
              + "/* ${role.colour}: ${role.note} */"
            ) group.roles
          )}
        '') groups
      )
    }}

    /* ── The one declaration a variable cannot reach ──────────────── */
    /*
     * rofi's `highlight` property wants a literal colour: its grammar rejects
     * both `@info` and `var(info)` there, and a theme that tries either fails
     * to parse and is silently replaced by rofi's default. So the fuzzy-match
     * underline is generated here rather than left as the last hex in the
     * hand-written layout file.
     */
    element-text {
        highlight:      bold underline ${flatRoles.info};
    }
  '';

  # waybar's clock calendar. The one surface that reads `colours` rather than
  # `roles`, and the only intended exception to that rule.
  #
  # It is Pango markup inside JSON, where CSS cannot reach and there is no
  # widget to give a role to: the four spans are typography, not state. Rather
  # than invent four roles with one user each, it names the pigment directly -
  # which still satisfies principle 5, because the pigment is named here and
  # nowhere else.
  #
  # waybar merges `include` into the top-level config recursively and lets the
  # including file win any key it already sets, so config.jsonc keeps every
  # decision about the calendar except its colours, and stays hex-free.
  toCalendarJson = ''
    // Waybar clock calendar colours: Kanagawa Wave
    //
    ${comment "//" (banner "the bar")}
    //
    // Merged into config.jsonc's "clock" module by its "include" key. Pango
    // markup in JSON is out of CSS's reach, which is the whole reason this
    // file exists rather than four more @define-colors.
    {
      "clock": {
        "calendar": {
          "format": {
            "month": "<span color='${colours.carpYellow}'><b>{}</b></span>",
            "weekdays": "<span color='${colours.surimiOrange}'><b>{}</b></span>",
            "days": "<span color='${colours.fujiWhite}'><b>{}</b></span>",
            "today": "<span color='${colours.waveRed}'><b>{}</b></span>"
          }
        }
      }
    }
  '';

  # Every file this palette generates, keyed by its path in the working tree.
  # `nix run .#write-palette` writes exactly this set; the build gates assert
  # the tree still matches it.
  files = {
    "configs/waybar/kanagawa-wave.css" = toCss;
    "configs/waybar/calendar.jsonc" = toCalendarJson;
    "configs/rofi/themes/palette.rasi" = toRasi;
  };
}
