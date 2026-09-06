# Plan: the desktop, as a designed system

Status: proposed 2026-09-05; the four open questions were answered on 2026-09-06 and two requirements were added that change the shape of the bar and remove motion from the desktop entirely — see _Decisions, 2026-09-06_ below. Items 22, 1–4 and 5–7 were built on 2026-09-06; everything from 8 on is still proposed. This is the spine document for a series of sessions — it decides what the desktop is _for_, names the rules a change can be checked against, records what is actually there today, and sequences the work. The per-tool sessions (waybar, rofi, the lock screen) come after, and their brief is this document rather than a fresh opinion.

Scope is the `xps15` host: `modules/home/desktop/`, `modules/nixos/hyprland.nix`, `modules/nixos/stylix.nix` and the eleven files under `configs/` that they deploy. The servers are out of scope and have no desktop.

## The short version

The compositor layer is in good shape and does not need replacing. Hyprland is configured with more care than most rices ever get — eight Lua files split for error isolation, vim-motion focus, a resize submap, per-monitor workspace assignment, a lid-state check at launch. Three of the five custom waybar modules are the user's own software with real logic behind them. That is a strong foundation.

What is missing is not compositor work. It is three things:

1. **A layer of the system is not exposed at all.** Networks, bluetooth, audio devices, power, running background services and privilege prompts have no visual path. Principle 4 is the one principle the current desktop does not serve, and it is the one the user named the most concrete examples for.
2. **Colour, geometry and motion are decided in six places and agree in none of them.** Stylix owns the base16 palette, and then waybar restates it in CSS, rofi restates it in rasi, waybar's clock hardcodes four hexes, and the lock screen — the second-most-seen surface on the machine — is not Kanagawa at all. Consistency is not a taste problem here; it is a source-of-truth problem.
3. **About eight of the bar's documented click actions run a command that is not installed.** The bar teaches an interaction grammar and then does not honour it, which is worse than not having the grammar.

The plan below fixes those in that order, then spends the remaining effort on measurement and taste. The single largest design decision proposed is item 7: **rofi becomes the menu system for everything that is a list of things to pick**, instead of adding four or five separate applets. One theme, one interaction model, keyboard and mouse both work, and the maintenance surface is a handful of shell scripts over `nmcli`, `bluetoothctl`, `wpctl` and `cliphist` rather than four GTK trays.

Two further decisions were added on 2026-09-06 and are as structural as item 7: **the bar becomes vertical** (item 21), and **motion is removed rather than tuned** (item 22).

## Decisions, 2026-09-06

The four questions at the foot of the 2026-09-05 draft were answered, and two requirements arrived that were not in it. The answers are recorded here; the items they touch are amended in place below.

- **Portability is kept, and only colour is generated.** The configs have never been copied to a non-Nix machine, but the property is wanted, so the compromise stands as item 5 proposed it: `config.jsonc` and `style.css` stay hand-written and hex-free, and only the colour file is produced from the stylix palette, with a checked-in copy for the non-Nix case. The cheaper alternative — hand stylix the waybar and rofi targets — stays rejected. **Amended when item 5 was built:** the colour file is not produced from _the stylix palette_, because that palette does not contain eight of the colours in use. `lib/kanagawa-wave.nix` is the source and stylix reads it. See item 5's build note.
- **The power menu is two layers, so it takes no confirmation.** Opening the menu is the first decision and picking `Power off` is the second, which is the interruption budget principle 3 allows. The conditional in the answer is worth writing down as a rule, because it generalises: _a destructive action reachable in one step gets a confirmation; one reachable in two does not._ That is what makes it wrong to also bind `SUPER+SHIFT+Q` straight to shutdown later as a convenience — see item 8.
- **`swayosd`, not the dunst progress bar.** Taken directly rather than after trying the free version. It has a home-manager service and the daemon is cheap. It has one consequence worth naming now: **stylix has no swayosd target**, so it arrives as a fourth surface holding a hand-written copy of the palette, and it must be built into item 5's generated-colour scheme from the start rather than added to it afterwards. Item 12 is rewritten and now depends on item 5.
- **The laptop panel is sometimes the only display, and gets no workspace assignments.** Confirmed as deliberate: with the externals disconnected every workspace lands on `eDP-1` because it is the only output, which is the behaviour wanted, and no rule is needed to produce it. The lid-disabled state is a workaround for a Hyprland issue that may have been fixed since — worth re-testing during item 16, but not a design question. This closes the question; item 21 inherits the constraint that the bar must be sensible on one 16:10 panel as well as on two 1440p externals.
- **The bar becomes vertical.** New requirement, and the largest single change in this document. See item 21, which supersedes item 19.
- **Animations go off, not down.** New requirement, and it withdraws the motion half of item 6 and one of item 16's three variables. See item 22.

## Principles, turned into rules

The six principles are the brief. To be useful in a review they have to be things a specific change can fail. This is that translation, and everything below is checked against it.

| # | Principle | The rule it becomes |
| - | --------- | ------------------- |
| 1 | Performant | Anything the user initiates is complete within **150 ms**, including its animation. Anything the system initiates on its own may take longer but must never block input. No background poller runs faster than the thing it is watching changes. |
| 2 | Keyboard, with mouse backups | Every action has a keybind. Every action that can be a pointer target is one. Neither path is the "real" one. A keyboard-first system is only usable if the keys are **discoverable**, so the binding list is itself a surface. |
| 3 | I am the driver | Nothing takes focus that the user did not ask for. Notifications are for things the user did not know; information the user _asked_ for goes somewhere else. There is an off switch, and it is one keystroke. |
| 4 | System processes visually exposed | Anything the user would otherwise open a terminal for daily — network, audio, bluetooth, power, mounts, what is running, what has failed — has a visual path that is at most two interactions deep. |
| 5 | Consistent | **One palette, one geometry scale, one motion budget, one input grammar.** A colour is named in exactly one file. A surface that cannot be themed from that file is a surface to be replaced or accepted as an exception on the record. |
| 6 | Maintainable | Prefer a declarative option over a script, a script over a daemon, and a daemon over a framework. Every new surface must be themeable from the same source as the others, or it does not go in. Anything that breaks should break loudly and be caught by a check. |

Two rules follow from the pairs rather than from any single principle, and they carry most of the weight below.

**The escalation ladder** (principles 1, 3 and 4 together). Information about the system lives at four depths: _glance_ (the bar, always visible, no interaction), _hover_ (a tooltip, no commitment), _pick_ (a menu, one click or one keystroke, dismissible with Escape), _full_ (the actual application). A given fact should live at exactly one depth and be reachable from the one above it. The current desktop has glance and hover, then jumps to `notify-send`, which is the wrong channel — see item 14.

**Who owns what** (principle 6, and the same shape as the profiles-versus-modules rule in `profiles/common.nix`). Stylix owns colour, font and cursor; nothing else names a hex. Hyprland owns window geometry and motion. Waybar owns state readout and one click of action, never two. Rofi owns every list of things to pick. A change that puts a responsibility in the wrong place is wrong even if it works.

## What is here today

| Layer | Tool | State |
| ----- | ---- | ----- |
| Compositor | Hyprland 0.55+, Lua config, UWSM session | **good** — 8 files, split for error isolation |
| Session start | greetd + tuigreet | works; the one surface the palette does not reach |
| Idle / lock | hypridle + hyprlock | works; hyprlock is off-palette, and a suspend-wake `FIXME` is open |
| Bar | waybar, 16 modules, 5 of them custom | **good** — but 8 click actions are dead |
| Launcher | rofi 2.0 (native Wayland), custom Kanagawa theme | **good** — and under-used; see item 7 |
| Notifications | dunst | works; no history surface, no do-not-disturb |
| Theming | stylix, Kanagawa Wave, base16 | **good** — but three surfaces bypass it |
| Night shift | hyprsunset | works |
| Mounts | udiskie, tray icon | works |
| Files | yazi (keyboard), thunar (pointer) | works |
| Terminal | ghostty | **good** |
| Screenshot | `grimblast copy area` on `Print` | one mode, no file, no annotation |
| Media | playerctl + a custom waybar module | **good** |
| Projects | a custom Go daemon + waybar module | **good** |
| Network | — | **absent** |
| Bluetooth | — | **absent** (`blueman` installed, service off, no applet, no bar module) |
| Audio devices | pavucontrol, two clicks away | thin |
| Power / session | — | **absent** |
| Privilege prompts | — | **absent**, and silently so |
| Clipboard history | — | **absent** |
| Volume / brightness feedback | — | **absent** |
| Keybind reference | — | **absent** |

### Where it stands against each principle

**Principle 1 — performance.** Two settings are worth measuring before anything else is tuned. `settings.lua` runs blur at `passes = 4` against a default of 1, with `popups = true`, across a 3440×1440 ultrawide, a 2560×1440 secondary and the laptop panel on a hybrid-graphics machine; that is the most expensive thing the compositor does, and it is set nearly four times higher than stock. `cursor.no_hardware_cursors = true` forces a software cursor, which composites the whole screen on pointer motion — this was the correct NVIDIA workaround historically and may no longer be, so it is a re-test rather than an assumption. Separately, `animations.lua` gives `layersIn` a speed of 4, which is 400 ms: **rofi takes 400 ms to fade in**, and the launcher is the surface where responsiveness is felt most. That single number is probably the largest gap between how fast this desktop is and how fast it feels — item 22 removes it, and every other duration with it. And `custom/ddc-brightness` polls DDC/CI over I²C every 10 seconds, which is a slow serialised bus being asked a question whose answer changes when the user changes it.

**Principle 2 — keyboard with mouse backups.** The keyboard half is genuinely good. The gaps are the actions that have no bind because they have no implementation (power, network, clipboard, audio device), and one structural gap: with sixty-odd bindings there is no way to see them. `binds.lua` is the only documentation of `binds.lua`.

**Principle 3 — I am the driver.** Already respected, deliberately: the `suppress-maximize` rule for every window class is exactly this principle written as a window rule, and the idle inhibitor is on the bar. What is missing is the off switch — dunst has `dunstctl set-paused` and nothing surfaces it — and one small contradiction: `dunst.nix` sets both `monitor = 0` and `follow = "mouse"`, and `follow` wins, so the `monitor` setting is inert.

**Principle 4 — system processes visually exposed.** This is the weak one. Of the four examples given — wifi, shutdown, audio devices, what is running in the background — the first two have no visual path at all, the third is two clicks into pavucontrol, and the fourth is partly covered by the tray. Underneath that sits a defect: **there is no polkit authentication agent running.** `modules/nixos/hyprland.nix` enables `security.polkit`, which starts the daemon, but nothing starts an agent, so any graphical action needing authentication has no way to ask and fails quietly. That is the most important single line in this document.

**Principle 5 — consistency.** _(As surveyed 2026-09-05. Items 5 and 6 fixed everything here except the lock screen, which is item 17.)_ The Kanagawa palette is currently written out by hand in `configs/waybar/kanagawa-wave.css` (17 `@define-color` declarations), in `configs/rofi/themes/kanagawa-wave.rasi` (16 more), in four hardcoded hexes inside `config.jsonc`'s clock calendar, and in six `rgb()` literals in `hyprlock.nix` that are not Kanagawa at all — the lock screen's input field is grey `#151515` on white with an amber check and a red fail, which is a different design entirely. There are also four waybar theme files and five rofi theme files of which one each is used; the other seven are drift waiting to happen. Geometry has no scale: window rounding is 16, waybar radius is 8, rofi is 16 outside and 10 inside, dunst is 10; border width is 1 on windows and 2 everywhere else. And two different brightness tools are in play — `brillo` on the function keys, `brightnessctl` in the bar's scroll handler and in hypridle — which can hold different ideas about the same backlight.

**Principle 6 — maintainable.** The Nix structure is the strongest thing here and should not be disturbed: `cg.home.*` toggles, one module per concern, configs deployed as standalone files so they work off NixOS. That last choice is also the reason stylix cannot theme waybar or rofi — `stylix.targets.waybar.enable = false` is not an oversight, it is the price of portability — and item 5 is about paying that price differently rather than abandoning it. The gap is that **no check covers the desktop at all**. `checks/` holds VM tests for services; a desktop that boots into a bar whose buttons do nothing passes every check in the repository today.

## Design decisions proposed

These are the load-bearing ones. Each is argued in its item below; they are collected here because they are what a reviewer should push back on.

- **Hyprland stays.** It is working, it is configured well, and the alternatives (niri's scrolling model, river) are a different desktop rather than a better version of this one. Not revisited.
- **Rofi becomes the menu system, and dedicated applets are rejected.** Power, wifi, bluetooth, audio sink, clipboard history, emoji and the keybind sheet are all the same shape — a list you filter and pick from — and rofi already does that with a theme this repository owns. The alternative is `wlogout` plus `nm-applet` plus `blueman-applet` plus a picker, which is four more surfaces, four more themes, four more tray icons and four more things to break. See item 7.
- **Dunst stays; a notification centre daemon is rejected.** `swaync` would bring a history panel and a do-not-disturb toggle, and would also be a second GTK surface to theme. Dunst already has `dunstctl set-paused` and a queryable history; a bar module and a rofi menu get the same result with no new daemon, which is the order principle 6 asks for. Revisit only if the rofi history view turns out to be unusable.
- **Waybar's colour file becomes generated; its layout file stays hand-written and portable.** The split is the point: `config.jsonc` and `style.css` remain standalone files that work on any machine, and only `kanagawa-wave.css` — which is nothing but colour — is produced from the stylix palette. The same split applies to rofi, and to swayosd when item 12 adds it. This keeps the portability the current design bought while removing the duplication it cost. **Settled 2026-09-06**; see item 5.
- **The greeter stays tuigreet, and its palette is set by hand.** `regreet` is the consistent answer and stylix themes it, but it needs a compositor to run inside, which puts a Wayland session in front of the Wayland session on every boot. tuigreet on a TTY is instant. The exception goes on the record instead. See item 18.
- **A shell framework is rejected.** AGS, Quickshell and eww would replace waybar, rofi, the notification daemon and the lock screen with one programmable surface, and that is how the best-looking rices are built. It is also a bespoke desktop shell to maintain, which is what principle 6 exists to refuse. Not revisited unless waybar becomes the limiting factor, and it is not close to being that.

## The items

| # | Item | Size | Depends on | Status |
| - | ---- | ---- | ---------- | ------ |
| 1 | A check that the bar's commands exist | small | – | **done 2026-09-06** |
| 2 | A polkit authentication agent | small | – | **done 2026-09-06** |
| 3 | The eight dead click actions | small | 1 | **done 2026-09-06** — ten, in the end |
| 4 | Autostart stops owning what systemd owns | small | – | **done 2026-09-06** |
| 5 | One palette, one source | medium | – | **done 2026-09-06** — the repository owns the palette |
| 6 | A geometry scale | small | – | **done 2026-09-06**; motion half withdrawn 2026-09-06 |
| 7 | Rofi is the menu system | medium | 5 | **done 2026-09-06** — scaffolding, and the picker moved onto it |
| 8 | Power and session | small | 7 | proposed |
| 9 | Network, bluetooth, audio | medium | 7 | proposed |
| 10 | Clipboard history that survives its window | small | 7 | proposed |
| 11 | The keybind sheet | small | 7 | proposed |
| 12 | Hardware feedback has nowhere to land | small | 5 | proposed; rewritten for swayosd 2026-09-06 |
| 13 | Do not disturb, and a history | small | 7 | proposed |
| 14 | What is running, and what has failed | medium | 3, 7 | proposed |
| 15 | The screenshot suite | small | – | proposed |
| 16 | Measure, then tune: blur and the cursor | medium | 22 | proposed; motion variable withdrawn 2026-09-06 |
| 17 | The lock screen is off-palette | small | 5 | proposed |
| 18 | The greeter, on the record | small | 5 | proposed |
| 19 | Waybar, re-laid-out | medium | 3, 5, 6 | **superseded by 21** |
| 20 | Rofi, refined | small | 5, 6, 7 | proposed |
| 21 | The bar is vertical | large | 3, 5, 6 | proposed 2026-09-06 |
| 22 | Motion comes out | small | – | **done 2026-09-06** |

Sequencing: **22 first**, out of order, because it is one line, it is free, and it changes how everything after it feels to work on — there is no sense tuning a desktop while a 400 ms fade sits in front of the launcher. Then **1–4**, because they are defects and cheap, and because item 1 is the harness that stops item 3 from recurring — the same reason the digital garden plan put its rendering fixture before its palette. **5–7 next**, because they are the spine every later item hangs from. **8–15** are the gaps, and each is a session-sized piece of work that can be taken independently once 7 exists. **16, 17, 18, 20 and 21** are tuning and taste, and want the rest in place first so that what is being looked at is the finished shape — item 21 especially, since it is the item that decides which of the modules from 9, 12, 13 and 14 earn a permanent place on a bar that no longer has room for all of them.

---

## 1. A check that the bar's commands exist

### The problem

`configs/waybar/config.jsonc` names twenty-six distinct binaries across its `exec`, click and scroll handlers. Seven of them — `foot`, `btop`, `dust`, `pulsemixer`, `upower`, `sensors` and `nm-connection-editor` — are not installed on this host. Nothing catches this: the file is deployed verbatim by `xdg.configFile`, waybar parses it happily, and the failure only appears as a click that does nothing. The same class of bug will recur every time a module is added or a package is dropped.

### Approach

A check that reads `config.jsonc`, extracts every `exec`, `on-click*` and `on-scroll*` value, takes the first word of each, and asserts that it resolves in the closure of `home-manager.users.coryg.home.path` plus `environment.systemPackages`. It runs at evaluation or as a `checks/` derivation — the former is better here, because it should fail the build rather than a test run.

This is not a general "does this shell command work" check and should not try to become one. Checking only the head of each command line catches six of the eight failures in item 3. It misses the other two, and it misses them for an instructive reason: both are `notify-send` calls whose missing binary (`sensors`, `upower`) sits inside a `$(...)` substitution, so the head resolves fine and the notification fires empty. Those two are exactly the ones item 3 argues should not be `notify-send` calls at all. The check does not need to grow a shell parser to cover them; item 3 removes them.

Reference resolution is the same question for `binds.lua` and for the hypridle and hyprlock settings, all of which also name binaries. Doing waybar first is enough to prove the shape; extending it is cheap afterwards.

### Cost and risk

Half a session. The risk is over-reach: shell one-liners with pipes and `$(...)` are in the file already, and the check should look at the first token and stop, not try to parse shell.

### Built, 2026-09-06

`modules/home/desktop/waybar-commands.py`, run from `modules/home/desktop/waybar.nix`. It parses `config.jsonc` with `json5` (JSONC is a subset — comments and trailing commas both parse), walks every `exec`, `exec-if`, `on-update`, `on-click*` and `on-scroll*` string, takes the first whitespace-separated word, and asserts it resolves under `home.path/bin`, `system.path/bin` or `system.path/sbin` — the two closures that actually make up the bar's PATH, read from the evaluated configuration rather than restated.

It is _not_ in `checks/`, and that is the point of item 1 rather than an omission: `xdg.configFile."waybar".source` is the check's own output, so there is no way to deploy a `config.jsonc` the check has not passed on. A dead button fails `nixos-rebuild switch` on the laptop and fails the host build in CI, instead of failing a test run somebody has to remember to look at. `/run/wrappers/bin` is deliberately not modelled — nothing on the bar is setuid, and a wrapper cannot be resolved from a build sandbox, so a command that needs one fails the check and forces the question.

One deliberate exclusion: a module's `actions` object maps an event to a waybar-_internal_ action name, not to a command, so it is skipped. That distinction turned out to matter — see item 3.

## 2. A polkit authentication agent

### The problem

`modules/nixos/hyprland.nix` sets `security.polkit.enable = true` with the comment "Polkit is required for privilege escalation". That starts `polkitd`, which is the half that _decides_. The half that _asks_ — an authentication agent — is not running. Any graphical action that needs authorisation has nowhere to prompt, so it fails, and it fails quietly: no dialog, no error the user sees, just an action that does not happen. `gnome-firmware`, bluetooth pairing, `nm-connection-editor` on system connections and some `udisks` operations all sit behind this.

This is the clearest possible principle 4 failure — a system process not merely unexposed but invisible — and it is a one-line fix.

### Approach

`services.hyprpolkitagent.enable = true` in home-manager. The option exists, the package is in nixpkgs (0.1.3), it is the Hyprland project's own agent, and it starts as a user service under `graphical-session.target` alongside everything else here.

Its dialog is Qt and will not be themed by stylix's GTK target. That is acceptable — it should be seen rarely, and the alternative (`polkit-gnome`, unmaintained) is worse. Note it as a known exception and move on.

### Cost and risk

Minutes. Verify by asking for something that needs it rather than by reading the option back.

### Built, 2026-09-06

`services.hyprpolkitagent.enable = true` in `modules/home/desktop/hyprland.nix`, next to the comment naming it as the other half of `security.polkit.enable`. Not behind its own toggle: a session with no way to authenticate is not a configuration anyone would choose. The Qt dialog stays an accepted exception. Still to be verified the way the item asks — by triggering something that needs it, not by reading the option back.

## 3. The eight dead click actions

### The problem

The bar declares an interaction grammar in a comment at the top of `config.jsonc` — left is the primary action, right is the alternate view, middle is contextual — and then does not honour it. Eight of roughly twenty declared actions do nothing:

| Module | Button | Runs | Why it fails |
| ------ | ------ | ---- | ------------ |
| cpu | left | `foot -e btop` | neither `foot` nor `btop` is installed |
| memory | left | `foot -e btop` | same |
| temperature | left | `foot -e btop` | same |
| temperature | right | `notify-send … sensors` | `lm_sensors` is on the servers only |
| disk | middle | `foot -e … dust` | `foot` and `dust` both absent |
| pulseaudio | middle | `foot -e pulsemixer` | `foot` and `pulsemixer` both absent |
| battery | right | `notify-send … upower` | `services.upower.enable` is false |
| network | middle | `nm-connection-editor` | `networkmanagerapplet` is not installed |

The two `notify-send` cases are worse than the others, because they succeed: a notification appears with an empty body, which reads as "there is nothing to report" rather than "this is broken".

`foot` appears five times and is presumably left over from before ghostty. The terminal in `config.rasi` is already `ghostty`.

### Approach

Two decisions, then a mechanical fix.

First, **the terminal is ghostty**, named once. Every `foot -e X` becomes the same launcher, and the terminal name should not be repeated five times in a config file — the shell-out belongs in one place.

Second, **`notify-send` is the wrong channel for information the user asked for** (the escalation-ladder rule). A right-click that answers "what is my battery doing" is a _pick_-depth question and should open a menu or a tooltip, not fire a notification into the same stream as a Discord message. So the two `notify-send` right-clicks are not fixed by installing `upower` and `lm_sensors`; they are moved. The natural home is the module's tooltip, which waybar already renders on hover and which costs nothing.

That leaves the actual installs: `btop` for the system view, and — if the right-click content stays anywhere — `lm_sensors`. `dust`, `pulsemixer`, `foot`, `upower` and `networkmanagerapplet` are all dropped rather than installed, because items 9 and 14 replace what they were reaching for.

### Cost and risk

One session, mostly deciding rather than typing. Item 1 should land first so the result is verified by the check rather than by clicking eight things.

### Built, 2026-09-06

Item 1 landed first, as the item asks, and immediately found two more of the same defect that reading the file had missed — so the count was ten, not eight:

- `hyprland/workspaces` had `"on-click": "activate"`. `activate` is a `sway/workspaces` action name; `hyprland/workspaces` has no `on-click` option at all, so waybar was handing `activate` to a shell. Clicking a workspace already switches to it natively (`Workspace::handleClicked` dispatches over the Hyprland socket), so the line is simply gone.
- The clock's `"on-click-right": "mode"` sat _inside_ `"calendar"`, where waybar never reads it — module actions come from an `"actions"` object on the module. It was inert rather than broken, which is the same failure wearing a better disguise. Moved to `"actions"`, where it now works.

The eight from the table: the three `foot -e btop` left-clicks became `term-run btop`; `dust`, `pulsemixer` and `nm-connection-editor` were dropped rather than installed, each with a comment naming the later item that replaces what it was reaching for (14, 9, 9); and the two `notify-send` right-clicks were moved rather than fixed, per the escalation-ladder rule.

The battery's move is the clean case: `upower -i` reported state, percentage, time and energy rate, and waybar's own `tooltip-format` renders `{timeTo}`, `{power}` and `{health}` at hover depth with no process to fork. The temperature's is the honest one: the module's `tooltip-format` only accepts `{temperatureC/F/K}`, so "all thermal zones" cannot go there. The right-click is gone, the native tooltip answers the module's own question, and per-zone detail is left to item 14 — where a `pick`-depth surface exists to put it in.

**The terminal is named once.** `term-run <command>` is a `writeShellApplication` in `modules/home/terminals/ghostty.nix` — the module that already decides which terminal this desktop uses, and therefore the right place to make that decision executable. `config.jsonc` names `term-run`, never `ghostty`. `btop` is installed by `modules/home/desktop/waybar.nix` rather than by the host's package list, so the bar carries its own click targets and the two cannot drift apart.

## 4. Autostart stops owning what systemd owns

### The problem

`configs/hypr/autostart.lua` launches `hyprpaper` and `dunst` directly. Both are already systemd user services: `services.dunst.enable` creates one, and stylix's hyprpaper target sets `services.hyprpaper.enable = true` (confirmed by evaluation). So each is started twice on every login — once by systemd under `graphical-session.target`, once by the compositor. dunst will refuse the second instance and log an error; hyprpaper's second instance is a race over the same IPC socket.

`kdeconnect-indicator` is the only line there that genuinely has no unit.

### Approach

Delete the `hyprpaper` and `dunst` lines. The `systemctl --user start hyprland-session.target` line at the top is what makes the rest work and stays.

`kdeconnect-indicator` becomes a systemd user service like the others, at which point `autostart.lua` has nothing left in it but the target start, and the file is either that one line or is folded away. Worth doing: it removes a whole category of "why is this running twice" from a system whose author values reliability.

### Cost and risk

Small, and it is a strict simplification. The risk is that something depends on the ordering the exec gave it; UWSM plus `graphical-session.target` is the correct ordering mechanism and both services already declare `After=graphical-session.target`.

### Built, 2026-09-06

The `hyprpaper` and `dunst` lines are gone. `kdeconnect-indicator` got the unit it never had, in `modules/home/desktop/kdeconnect.nix` behind `cg.home.kdeconnect.enable` — the daemon and its firewall holes stay with `programs.kdeconnect.enable` on the host, and only the tray icon is the home-manager side's business. It is ordered `After=` and `Requires=tray.target` exactly as `udiskie.service` is, because a StatusNotifierItem with no host has nowhere to draw; under the old `exec_cmd` it raced the bar with nothing to order it at all.

`autostart.lua` is kept rather than folded away, at one line. The file is now the written-down answer to "where does a daemon go", and the comment says the answer is _not here_ — which is worth more as a file than as a deleted file.

## 5. One palette, one source

### The problem

Kanagawa Wave is currently written out by hand in four places and contradicted in a fifth:

- `modules/nixos/stylix.nix` — `base16Scheme = kanagawa.yaml`, the nominal source of truth, which reaches GTK, Qt, dunst, hyprland's window borders, ghostty and nvim.
- `configs/waybar/kanagawa-wave.css` — 17 `@define-color` declarations, hand-transcribed, mapping the palette onto role names.
- `configs/rofi/themes/kanagawa-wave.rasi` — 16 more, hand-transcribed, with a _different_ set of role names (`accent`/`accent2` versus waybar's `accent-primary`/`secondary`).
- `configs/waybar/config.jsonc` — four raw hexes inside the clock's calendar format strings, where CSS cannot reach.
- `modules/home/desktop/hyprlock.nix` — six `rgb()` literals that are not Kanagawa: `#151515` outer, `#c8c8c8` inner, black text, amber check, red fail. The lock screen is a different design language from the rest of the machine.

There are also four waybar theme files and five rofi theme files. One of each is imported. The other seven exist to be switched to and will be wrong the first time a role is added.

This is a source-of-truth problem rather than a taste problem. The palette is fine; there are just five of it.

### Approach

The constraint that produced this is real and should be preserved: `configs/` deploys standalone files so that the same waybar and rofi configuration works on a machine without Nix. That is why `stylix.targets.waybar.enable = false`. The fix is not to hand waybar to stylix — it is to **split colour from layout** and generate only the colour half.

- `config.jsonc` and `style.css` stay hand-written, portable, and free of hexes.
- `kanagawa-wave.css` becomes generated from `config.lib.stylix.colors`, keeping its current role-name interface exactly so that `style.css` does not change at all. A checked-in copy stays for the non-Nix case; a check asserts the two agree.
- The rofi theme gets the same treatment, and its role names are renamed to match waybar's. Two files should not call the same colour by two names.
- The clock's four calendar hexes are the awkward case, because Pango markup inside JSON cannot read CSS variables. Either the calendar block is generated with the rest, or the calendar moves out of the tooltip entirely — item 21 is going to ask whether a tooltip calendar survives a 40px-wide bar at all.
- `hyprlock.nix` is item 17. **swayosd is a fourth hand-themed surface** and joins this scheme when item 12 adds it: it reads a plain `~/.config/swayosd/style.css`, and stylix has no target for it (confirmed by evaluation), so it must be generated from the same source from the first commit rather than hand-written and cleaned up later.
- The seven unused theme files go. A theme that has never been rendered is not an option, it is a liability.

Three alternatives were considered and two rejected. **Hand stylix the targets** (`stylix.targets.waybar.enable = true`) is the least code and gives up portability and the entire hand-tuned layout; rejected. **Keep hand-transcribing and add a check that the hexes match the base16 scheme** keeps portability perfectly and does not remove the duplication, only the drift; this is the cheap fallback if generation proves annoying. **Generate the colour file only** is what is proposed, and is what was taken on 2026-09-06.

**Decided 2026-09-06.** The configs have never in fact been copied to a non-Nix machine, which would have made the first alternative attractive and halved this item — but the portability is wanted as a property rather than as a current practice, so the split stands. The checked-in copy of each generated file is what makes that true: it is the thing a non-Nix machine gets, and the check that it agrees with the generated version is what stops it rotting.

### Built, 2026-09-06

The approach survived, but its source did not. Generating the colour files from `config.lib.stylix.colors` turned out to be impossible without shifting the palette, because **`base16-schemes/kanagawa.yaml` is a sixteen-slot reduction of Kanagawa Wave and eight of the colours this desktop renders have no slot in it**: `sumiInk2`, `sumiInk3`, `waveBlue2`, `waveRed`, `springGreen`, `springBlue`, `roninYellow` and `carpYellow`. The scheme's green is `autumnGreen` #76946A where the bar draws `springGreen` #98BB6C; its yellow is `boatYellow2` where the bar draws `roninYellow`. The hand-written themes had been drawing on the full palette all along, and the scheme stylix reads is not it. So generation from stylix would have had to either recolour the desktop or name those eight somewhere else — which is the duplication the item exists to remove.

**So the direction is inverted. `lib/kanagawa-wave.nix` is the source, and stylix is handed it** (`base16Scheme` takes an attrset). The sixteen slots it exports are byte-identical to the upstream YAML, so adopting it changed nothing that was already themed — verified by evaluating `lib.stylix.colors` before and after. What it bought is that the other eight colours have somewhere to live, that GTK, Qt, dunst, hyprland's borders, ghostty and nvim now come from the same file as the bar and the launcher, and that the palette stops moving underneath the machine when `base16-schemes` updates.

The file has two layers and the distinction is load-bearing. **`colours` names the pigment; `roles` names the job.** A surface reads `roles` — the shared vocabulary — and a role that gains a user is how a colour earns its place. There is exactly one documented exception, below.

Three files are generated and also checked in, so `configs/` still works on a machine without Nix: `configs/waybar/kanagawa-wave.css`, `configs/rofi/themes/palette.rasi`, and `configs/waybar/calendar.jsonc`. `nix run .#write-palette` writes them; the build asserts the tree matches (`modules/home/desktop/lib/generated.nix`, called from `waybar.nix` and `rofi.nix`) with the same shape as item 1 — the deployed file is the check's output, so a hand-edited colour fails `nixos-rebuild switch` and fails CI. Proven by editing one hex and watching the build reject it.

Four things the item did not anticipate:

- **The calendar is answered by an `include`, not by generating `config.jsonc`.** waybar's `mergeConfig` recurses into objects and lets the including file win any key it already sets (confirmed in `src/config.cpp`), so `config.jsonc` keeps every decision about the calendar and `calendar.jsonc` supplies only the four Pango colours. `config.jsonc` is now hex-free. `waybar-commands.py` follows `include` too, so a command arriving from one is checked like any other.
- **The calendar is the one surface that reads `colours` rather than `roles`,** and this is the exception the item's rule asks to be put on the record. It is markup inside JSON with no widget to theme; the four spans are typography, not state. Inventing four roles with one user each would have been worse than naming the pigment, which is still named in exactly one file.
- **rofi silently ignores a theme it cannot parse** — it warns to a log nobody reads and loads its own default, so a broken theme looks like a launcher that has reverted to Solarized. That is now a build gate as well (`rofi -no-config -theme … -dump-theme` needs no display). It earned itself immediately: rofi's grammar takes a *literal* colour in `element-text`'s `highlight` and rejects both `@info` and `var(info)`, so that one declaration is generated into `palette.rasi` rather than left as the last hex in the layout file.
- **A fifth hand-written palette turned up.** `modules/home/desktop/waybar-modifiers.nix` emits Pango markup, so its colours were out of CSS's reach — and it had been carrying a **Rose Pine** palette from before the machine was themed. Its four modifier colours now come from `roles`.

Role names were reconciled to waybar's, as the item asks, and the audit shaved two: `accent-primary` (waveAqua1) was declared and referenced by nothing, and rofi's `accent2` likewise. What was `accent-secondary` is now `accent`, which is the only change `style.css` needed. Six theme files that had never been rendered are gone — two waybar, four rofi — and `stylix.targets.rofi.enable` is now explicitly `false` rather than inert-by-accident, so the latent fight over `~/.config/rofi` is settled on the record.

`hyprlock` (item 17) and `swayosd` (item 12) are unchanged and now have a palette to join.

### Cost and risk

One to two sessions. The risk is generating something stylix already generates and ending up with two files fighting over `~/.config/rofi/`; note that `stylix.targets.rofi.enable` is currently `true` and does nothing only because `programs.rofi` is not enabled — the raw `xdg.configFile` route is used instead. That latent conflict should be resolved explicitly rather than left to whichever writes last.

## 6. A geometry scale

_Titled "a geometry and motion scale" on 2026-09-05. The motion half was withdrawn on 2026-09-06: item 22 removes motion rather than budgeting it, so there is no longer a duration scale to design. What is left is geometry._

### The problem

Every surface picked its own numbers. Window rounding is 16, waybar's modules are 8, rofi's window is 16 and its rows are 10, dunst is 10. Window borders are 1px, waybar's are 2px, rofi's are 2px. Gaps are 5 in and 5 out; waybar's margins are 3, 10, 15 and 20 in different places. Nothing is wrong individually and nothing agrees.

### Approach

Pick one scale and apply it everywhere. A first proposal, to be argued with rather than accepted:

- **Radius**: 12 for anything window-sized or overlay-sized (windows, rofi, hyprlock's field, dunst, swayosd), 8 for chips inside a surface (waybar modules, rofi rows). Two values, and the relationship between them is legible.
- **Border**: 2px everywhere, including window borders. 1px on a window next to 2px on the bar beside it is the kind of inconsistency that is felt without being seen.
- **Spacing**: 8 as the unit. Gaps 8, waybar module padding 8/16, rofi padding 16.

These are taste and should be looked at rather than reasoned about. The one non-taste part is that the numbers live in one place, so that item 21 does not reinvent them while rotating the bar.

### Cost and risk

Small, and immediately visible. It no longer depends on item 5 — with motion gone there is nothing here that a generated colour file would overwrite — but taking 5 first still avoids touching `style.css` twice.

### Built, 2026-09-06

The proposal was taken as written. `lib/geometry.nix` holds it: radius 12 for a surface and 8 for a chip, border 2 everywhere, and spacing as multiples of 8 rather than a fixed list so that a gap nobody anticipated is still on the scale.

The interesting half is how it reaches the files. dunst is configured in Nix and simply reads the values. waybar's stylesheets, rofi's theme and hyprland's `settings.lua` cannot: they are deployed verbatim so `configs/` works without Nix, and GTK 3 CSS has no custom properties for lengths the way it has `@define-color` for colour. So **the scale reaches them backwards** — `modules/home/desktop/geometry-scale.py` reads them at build time and asserts every length they name is on it, wired in from `waybar.nix`, `rofi.nix` and `hyprland.nix` through `lib/scale.nix`. Same bargain as the palette: hand-written, portable, gated. Proven by putting a 10px radius and a 60px margin back and watching the build name both.

Its scope is deliberately narrow — the properties that carry geometry, listed in the script. Font sizes, icon sizes, opacities, durations and content widths are somebody else's decision and are not looked at; a check that policed every number in a stylesheet would be turned off within a week.

What actually moved: window rounding 16 → 12 and gaps 5 → 8 in `settings.lua`, window borders 1 → 2, dunst's radius 10 → 12, rofi's window 16 → 12 and its rows 10 → 8. And in `style.css`, the bar's own asymmetry finally went: every module carried `margin: 3px 0` with a `margin-top: 15px` overriding it, which is why the modules sat low. They are now `padding: 8px 16px; margin: 8px 0`, which is the plan's number and which **makes the bar roughly fourteen pixels taller**. That is the one change here worth looking at before accepting — item 21 owns the bar's final shape, and dunst's `offset` is the number that has to move with it.

## 7. Rofi is the menu system

### The problem

Six of the missing surfaces below — power, wifi, bluetooth, audio sink, clipboard history, keybind reference — are the same shape: a list, filtered by typing, picked with the keyboard or the pointer, dismissed with Escape. The default answer is a different tool for each: `wlogout` for power, `nm-applet` for wifi, `blueman-applet` for bluetooth, something for the clipboard. That is four more processes, four more tray icons, four more theming problems and four more upstreams, to solve one problem four times.

Rofi is already installed, already themed with a file this repository owns, already native Wayland as of rofi 2.0, and its `-dmenu` mode is exactly "here is a list, give me back what was picked".

### Approach

A small library of scripts in `packages/`, each of which produces a list, pipes it through `rofi -dmenu` with the shared theme, and acts on the selection. `nmcli` for networks, `bluetoothctl` for devices, `wpctl` for sinks and sources, `cliphist` for the clipboard, `systemctl`/`loginctl` for power, and a parser over `binds.lua` for the keybind sheet.

The rules that keep this from sprawling:

- **Every menu uses the same theme file**, with at most a size override. A power menu and a wifi menu that look different are two menus; that is the whole point of this item.
- **Every menu is bound and also reachable from the bar.** Principle 2 in one sentence. `SUPER`-something opens it from the keyboard; a click on the relevant waybar module opens the same thing.
- **A menu does one thing.** The wifi menu connects to a network. It does not edit connection profiles — that is `full` depth on the ladder and `nm-connection-editor` can have it, if it is ever installed for that reason rather than as a dead middle-click.
- **A script that grows past about fifty lines is the wrong tool for that job**, and the applet should be reconsidered for that one case.

The alternatives are worth naming. **Fuzzel** and **tofi** are faster than rofi — tofi measurably so, in the low single-digit milliseconds — and are the right call if rofi's open time turns out to be the bottleneck after item 6 removes the 400 ms fade. **Walker** bundles clipboard, emoji, calculator and window switching natively and would replace the scripts entirely, but it is young and moving fast, which is what principle 6 refuses. Rofi stays because the theme already exists and its scriptability is the feature being used.

### Cost and risk

A session for the shared scaffolding and one menu; each further menu is then an hour. The real risk is the maintenance one the user named: a pile of shell scripts _is_ the flaky custom solution principle 6 warns about, if it is written carelessly. The mitigations are that each script is small, each is independently testable from a terminal, and none of them is in the path of anything critical — if the wifi menu breaks, `nmtui` still exists.

### Built, 2026-09-06

`packages/rofi-menu`, installed by `modules/home/desktop/rofi.nix` because "rofi owns every list of things to pick" is that module's responsibility. It reads a list on stdin, prints the choice on stdout, and passes rofi's exit 1 straight through so a caller can tell _the user picked nothing_ from _something went wrong_.

It pins three flags every menu wants and the launcher does not: `-no-custom` (a menu offers answers; typing a new one is not an answer), `-disable-history` (a menu whose order changes under you is a worse menu) and `-no-sidebar-mode` (the mode switcher belongs to the launcher). Everything else — colour, radius, spacing, font — comes from the shared theme, which is the entire point. **The one permitted override is the number of rows**, and it should stay the only one: a power menu with five answers should not leave three empty rows below them.

The one menu is the one that already existed. **`project-launcher pick` now goes through `rofi-menu`** instead of calling rofi with its own flags — it was a second menu system of one, and the flags it was missing are exactly the ones the wrapper now pins. Its old comment about `-format i` interacting badly with "history and sidebar-mode" was describing this problem from the inside. It also happens to satisfy the reachability rule already: `SUPER+P` from the keyboard, a click on the bar module from the pointer, neither one the real path.

`rofi` is a `runtimeInput` rather than a name looked up on `PATH`, so a menu cannot break because the launcher left the user's profile — the failure class item 1 built a check for, made impossible here instead.

The rules are written into the package's own header rather than left in this document, because that is where somebody adding the wifi menu will be. The fifty-line rule is not yet mechanical: there is one menu and no shell scripts to measure, and a check with nothing to check is a claim the repository does not honour. Whoever writes the second menu should extract a `mkMenu` builder and put the rule in it.

## 8. Power and session

### The problem

There is no visual way to shut down, reboot, log out or suspend. `SUPER+S` locks. Everything else is a terminal command, and the user named shutting down as a day-to-day thing that should not require one.

### Approach

A rofi menu: lock, log out, suspend, reboot, power off. Bound to `SUPER+Escape`, and reachable from a bar module. `loginctl` and `systemctl` do the work.

**Decided 2026-09-06: no confirmation, because the menu is already two layers.** Opening the menu is one decision and picking the entry is the second, which is enough deliberation for an action that costs an unsaved buffer. Destructive entries are still ordered last and the list still does not accept a bare Return on an empty filter, so the fast path never lands on `Power off` by accident.

The rule underneath that answer generalises, and is the reason to write it down rather than just do it: **a destructive action reachable in one step gets a confirmation; one reachable in two does not.** So the obvious later convenience — binding `SUPER+SHIFT+Q` straight to shutdown to skip the menu — is not a free optimisation. It collapses the two layers into one and would have to bring a confirmation with it, at which point it has saved nothing. Do not add it.

### Cost and risk

An hour once item 7 exists.

## 9. Network, bluetooth, audio

### The problem

Three of the user's four named examples. Changing wifi networks has no visual path at all. Bluetooth has none either — `blueman` is installed, `services.blueman.enable` is explicitly `false`, there is no applet, and `style.css` styles a `#bluetooth` module that `config.jsonc` never adds. Audio device switching means opening pavucontrol, which is a full mixer for a question that is "which headphones".

### Approach

Three rofi menus and three bar modules, in that order of dependency.

- **Network.** Lists saved and visible networks with signal strength, connects on pick, prompts for a passphrase when one is needed. `nmcli` throughout. The existing `network` module gets this on left click and keeps its format toggle on right.
- **Bluetooth.** Lists paired and discoverable devices, connects and disconnects on pick. `bluetoothctl`. Add the `bluetooth` module to `config.jsonc` — the CSS has been waiting for it — and either enable `services.blueman` for the pairing flows a menu should not attempt, or drop the `blueman` package. Half-installed is the worst of the three states.
- **Audio.** Lists sinks and sources, switches the default on pick. `wpctl`. This becomes the `pulseaudio` module's left click; pavucontrol moves to middle, where the current dead `pulsemixer` binding is.

### Cost and risk

A session, or one each if taken separately. The passphrase prompt is the only fiddly part — rofi can read a masked line, and the alternative is deferring to `nmtui` for new networks and handling only saved ones, which is a smaller and possibly better first version.

## 10. Clipboard history that survives its window

### The problem

There is no clipboard history. There is also a sharper daily problem underneath it: under Wayland the clipboard is owned by the source window, so copying from a terminal and then closing it loses the copy. That is a papercut that fires several times a day and has nothing to do with rice.

### Approach

`cliphist` as a home-manager service — the option exists — storing history, with a rofi menu bound to `SUPER+SHIFT+V` to pick from it. `wl-clip-persist` alongside it so the clipboard outlives its window.

Two things need deciding: how long the history is, and whether password-manager fields are excluded. Proton Pass is installed; `cliphist` can be told to ignore clipboard offers carrying the sensitive hint, and it should be.

### Cost and risk

An hour. Low risk and probably the highest ratio of daily relief to effort in this entire document.

## 11. The keybind sheet

### The problem

`binds.lua` defines around sixty bindings across nine labelled sections, and there is no way to see them except by opening the file. Principle 2 puts the keyboard first, and a keyboard-first system whose bindings can only be recalled from memory is keyboard-first only for the bindings already memorised. It is also the thing that makes the rest of this plan usable: eight new menus with eight new bindings is eight more things to forget.

### Approach

Parse `binds.lua` for `hl.bind(...)` calls and render the result into rofi, grouped by the section comments the file already has. Bound to `SUPER+slash` — the conventional key for "what can I do here".

Parsing Lua with a regex is the obvious objection. The counter is that `binds.lua` is written by one person in one style and the parse is over a form that is stable; and if it ever stops parsing, the failure is a keybind sheet that does not open, which is not a system failure. The alternative — a hand-maintained list that drifts — is worse, and the alternative to _that_ — restructuring `binds.lua` to emit a manifest — is more invasive than this item deserves on a first pass.

### Cost and risk

Half a session. Consider making the entries actionable — picking one runs it — which turns the cheat sheet into a command palette for free.

## 12. Hardware feedback has nowhere to land

### The problem

Pressing volume up changes the volume and shows nothing. The bar's `pulseaudio` module will catch up, but it may be on another monitor, it is small, and the point of a volume key is immediate confirmation. Brightness and mute are the same. This gets worse rather than better after item 21: a 40px-wide bar has less room for a number than a 30px-tall one, so the bar stops being even a partial answer.

### Approach

_The 2026-09-05 draft proposed reusing dunst's already-configured but unused `progress_bar`, with swayosd as the escalation if that disappointed. Taken directly to swayosd on 2026-09-06._

`services.swayosd.enable` in home-manager — the option exists — with the volume, mute and brightness binds in `binds.lua` calling `swayosd-client` instead of, or alongside, `wpctl` and `brillo`. The client route rather than swayosd's libinput backend: the backend is a system service that watches the raw input device to catch keys it was not bound to, there is no NixOS module for it in this nixpkgs, and the binds are already explicit in `binds.lua`, so there is nothing for it to catch. Caps lock is the one thing the backend would add and `custom/modifiers` already reports it.

Two consequences worth taking on knowingly, because both are principle-6 costs:

- **swayosd is a new daemon**, which principle 6's ordering asks to justify. The justification is that the dunst route puts hardware feedback into the notification channel and pins it to the notification corner, and this is a surface that should appear centred, over the focused output, and disappear without being dismissed. That is a different job from a notification and it is reasonable for it to be a different process.
- **swayosd has no stylix target** (confirmed by evaluation) and reads a plain `~/.config/swayosd/style.css`. It is therefore a fourth hand-written copy of the palette unless it is built into item 5's generated-colour scheme from the first commit. That is why this item now depends on 5 rather than standing alone.

While here: `brillo` on the function keys and `brightnessctl` in the bar and in hypridle are two tools with two ideas about the same backlight. Pick one. `brightnessctl` is the one the other two places already use.

### Cost and risk

Half a session, most of it theming. The volume and brightness binds grow a second command each, which argues for moving them out of `binds.lua` into a small script rather than lengthening the Lua — the same move item 15 wants for the screenshot binds.

## 13. Do not disturb, and a history

### The problem

Principle 3's off switch does not exist. Dunst can be paused with `dunstctl set-paused true` and nothing in the desktop offers it. Nor is there any way to see a notification that was missed — dunst keeps twenty in history and the only way in is a keybind that is not bound.

### Approach

A `custom/dnd` waybar module reading `dunstctl is-paused`, toggling on click, bound to `SUPER+N`. A rofi menu over `dunstctl history` for the missed ones, on right click.

The state must be visible while it is on. A do-not-disturb that can be left on silently is a worse failure than not having one, so the bar module changes shape rather than only colour when paused.

Consider also pausing automatically during fullscreen — Hyprland can signal it — but that is a system deciding something on the user's behalf and should be a deliberate, revisitable choice rather than a default.

### Cost and risk

Half a session.

## 14. What is running, and what has failed

### The problem

The fourth named example: seeing what is running in the background. The tray covers applications that ship a tray icon and nothing else. Underneath that sits a question the tray cannot answer at all — **which user services have failed**. This machine runs waybar, hyprpaper, hypridle, hyprsunset, dunst, udiskie, the project-launcher daemon, obsidian-sync, kdeconnect and, after this plan, several more, all under `graphical-session.target`. If one dies, nothing says so; the symptom is a bar that is missing a module, or a wallpaper that did not appear.

This is the escalation ladder with a rung missing. `glance` should say "something is wrong"; `pick` should say what; `full` is `journalctl`.

### Approach

Two pieces.

A **failed-units module**: `systemctl --user --failed` plus the system equivalent, rendered as nothing at all when the count is zero and as a visible marker when it is not. This is the same shape as the existing `custom/nixos-upgrade` module, which already knows how to be quiet until it has something to say, and it can be built the same way. Clicking it opens a rofi list of the failed units; picking one opens its journal in ghostty.

A **process view**: install `btop`, and give the cpu, memory and temperature modules a single consistent left click into it. That replaces the three dead `foot -e btop` bindings from item 3 with the thing they were reaching for.

The `custom/nixos-upgrade` module is worth pointing at as the pattern for the whole desktop: it is quiet when there is nothing to say, it says one thing when there is, and its three mouse buttons do three related things. Every module added from here should be measured against it.

### Cost and risk

A session. The failed-units module is the interesting half and is a good candidate for the same Go treatment the other custom modules got, since shelling out to `systemctl` twice on an interval is exactly the kind of poller principle 1's second sentence warns about — it should be event-driven off the systemd D-Bus signal instead.

## 15. The screenshot suite

### The problem

One binding: `Print` runs `grimblast copy area`. There is no way to screenshot to a file, no window or monitor capture, no annotation, and no colour picker. For a machine whose owner writes documentation with images in it, that is thin.

### Approach

Keep `grimblast` and give it the full set, under `Print` with modifiers: region to clipboard (unchanged, the common case), region to file, active window, current monitor. Add `satty` for annotation, invoked from the region capture as an option rather than always — annotation is a second decision and should not be forced on every screenshot. Add `hyprpicker` for colours, bound alongside.

`satty` over `swappy` on maintenance grounds; both are in nixpkgs.

### Cost and risk

An hour. Purely additive.

## 16. Measure, then tune: blur and the cursor

_Titled "blur, cursor, motion" on 2026-09-05. Motion is no longer a variable here — item 22 sets it to zero, which is the endpoint any measurement would have been arguing towards._

### The problem

Principle 1 is the first principle, and there is currently no way to tell whether the desktop meets it. Two settings are strong suspects and neither should be changed on suspicion:

- `decoration.blur.passes = 4` against a default of 1, with `popups = true`, across two 1440p externals and a laptop panel on hybrid graphics. Blur is the most expensive thing a Wayland compositor does and this is set nearly four times over stock.
- `cursor.no_hardware_cursors = true`, which forces the cursor to be composited into every frame instead of living on a hardware plane, so that pointer motion redraws the screen. This was the correct NVIDIA workaround for years. Whether it still is, on this driver and this Hyprland, is a question with an answer.

Item 22 raises the stakes on the first of these rather than lowering them. With motion gone, blur is the only decoration left that costs frame time, and it is now the whole of the performance question rather than a third of it.

### Approach

Establish the measurement first — this is the same move as the digital garden plan's rendering fixture, and for the same reason: a change you cannot see the effect of is a change you will argue about forever. Hyprland reports frame timings; `wev` measures input-to-event; a high-frame-rate capture of a keypress to first pixel is the honest end-to-end number if the cheap methods disagree.

Then change one variable at a time: blur passes 4 → 2 → 1 → off, and hardware cursors on. Record the numbers in this document, including the ones that turn out not to matter — a measurement showing blur is free on this hardware is worth as much as one showing it is not, because it closes the question.

Two things ride along, since the harness is up and the machine is being poked at anyway. **The lid-disabled workaround** in `monitors.lua` was added for a Hyprland issue that may since have been fixed; re-test it. **The hypridle `FIXME`** about waking from suspend is a reliability bug rather than a rice question, and it is the only open defect in this subsystem that this plan does not otherwise touch.

### Cost and risk

A session, most of it on the harness. The risk is doing the tuning without the harness and ending up with a desktop that is differently configured but not measurably faster.

## 17. The lock screen is off-palette

### The problem

`hyprlock.nix` specifies its input field as `#151515` outer, `#c8c8c8` inner, black text, `rgb(204,136,34)` for the check state and `rgb(204,34,34)` for failure. None of those are Kanagawa. The lock screen is the second-most-seen surface on the machine after the bar, and it is the only one that looks like a different desktop.

The background is `path = "screenshot"` with three blur passes — which means the lock screen shows whatever was on screen, blurred. Worth a separate look: it is a small privacy consideration and a large aesthetic one.

### Approach

Take the six colours from stylix, the same way item 5 does for waybar and rofi — home-manager can read `config.lib.stylix.colors` directly here, so this is simpler than the waybar case and needs no generation step. Apply item 6's radius and border. Then look at it, because the layout — a greeting at 64pt, a clock at 32pt, a field below — is a taste question that has never been reviewed.

### Cost and risk

An hour for the colours; the layout is a per-tool session of its own.

## 18. The greeter, on the record

### The problem

`tuigreet` is the first surface seen on every boot, it is a TUI, and it is the only surface stylix cannot reach. Every other window on the machine is Kanagawa; the login screen is terminal defaults.

### Approach

tuigreet accepts a colour theme via `--theme`, which covers the text, the prompt, the border and the action line. Set it from the same palette by hand — five values — and accept that this one surface is hand-maintained, on the record here as an exception rather than as an oversight.

`regreet` is the consistent alternative: it is GTK, stylix has a target for it, and it would inherit everything. It also has to run inside a compositor, which means starting a Wayland session in order to log into a Wayland session, on a machine whose first principle is that things feel instant. That trade is not worth making for a screen that is on for four seconds.

### Cost and risk

An hour. Revisit only if boot-time measurement in item 16 shows the greeter is not on the critical path after all.

## 19. Waybar, re-laid-out — superseded by 21

_**Superseded 2026-09-06.** The bar is becoming vertical, and laying out a horizontal bar and then rotating it is doing the work twice. The analysis below is not wrong and is not discarded — item 21 inherits all of it, and the vertical constraint turns out to force most of what this item was going to have to argue for. Kept here because the reasoning is the input to 21, not because the item is still live._

### The problem

Sixteen modules, and the layout has grown rather than been designed. `modules-right` runs upgrade, network, cpu, disk, memory, temperature, battery, audio, backlight, ddc-brightness — ten modules, four of which are numeric system telemetry that is only interesting when it is abnormal. Meanwhile the left side carries workspaces, project, tray, idle inhibitor, privacy, media and modifiers, which is a mix of navigation, state and controls with no grouping. `hyprland/window` is configured and not placed. The clock is centred and its calendar lives in a tooltip.

Against the escalation ladder, four of the right-hand modules are permanently at `glance` depth for information that only matters at `pick` depth — cpu, memory, disk and temperature are numbers that mean nothing at 6% and mean something at 96%.

### Approach

This is the per-tool session the user has in mind, and it should be taken with the rest of the plan already landed, because half of it is deciding which of the new modules from items 9, 13 and 14 earn a permanent place. The brief for it:

- Group by kind, not by history: navigation left, identity and state centre, system right.
- Telemetry that is only interesting when abnormal should be quiet when normal — the `custom/nixos-upgrade` and `custom/project` modules already do this and are the pattern.
- Every module answers "what happens on each of the three buttons" and the answer is never "nothing".
- The bar's own geometry comes from item 6, not from the eight different margin values currently in `style.css`.

### Cost and risk

A session, after 3, 5, 6, 9, 13 and 14.

## 20. Rofi, refined

### The problem

The theme is good and was written for one job — a centred launcher with icons. Once item 7 lands it is also a power menu, a wifi picker, a clipboard history and a keybind sheet, and those want different sizes, some want no icons, and one of them wants two columns. A single 680px eight-row window is not right for all of them.

### Approach

Split the theme into a shared base holding colour, font, radius and border, and a small set of variants that set only geometry: `launcher`, `menu` (short, no icons), `list` (tall, for clipboard and keybinds). Every menu from item 7 names a variant. Colour stays in exactly one file, per item 5.

Also revisit the launcher itself: `sidebar-mode` is on with three modes, `drun-display-format` is bare name with no comment or generic name shown, and the mode switcher takes a row at the bottom of every window whether or not the mode is relevant.

### Cost and risk

Half a session, after item 7 has shown what shapes are actually needed. Doing it before is designing for menus that do not exist yet.

## 21. The bar is vertical

_Added 2026-09-06. Supersedes item 19._

### The problem

The bar is horizontal and 30px tall, and it costs the wrong axis. On the ultrawide it takes 30 of 1440 rows — 2.1% of the scarce dimension on a 21:9 panel — to display information across 3440 columns it does not need. Turned on its side at 40px it would take 1.2% of the plentiful dimension instead. On the 2560×1440 secondary the same trade is 2.1% against 1.6%. On the laptop panel, which is 16:10 rather than 21:9, it is closer to even and the vertical bar wins only slightly. Across the machine as it is normally used — docked, two wide externals — the argument is clearly right, and it is right for the reason given: windows want to be taller more than they want to be wider.

The second half of the problem is that the current layout will not survive the rotation. Ten modules sit in `modules-right`, four of them numeric telemetry. `network` is formatted as `{ifname}: {ipaddr}/{cidr}   up: {bandwidthUpBits} down: {bandwidthDownBits}`. `custom/media` is capped at 35 characters. The clock is `{:%H:%M %A, %d/%m}`. None of those fit in 40px, and the honest reading is that **the vertical bar is not a rotation, it is a redesign with a hard width budget**.

### Approach

That budget is the good news, and it is the argument for taking this item rather than treating it as a constraint to work around: **a 40px bar cannot hold information that is only interesting when abnormal, so it enforces the escalation ladder that item 19 was going to have to argue for.** There is no room for a permanently-displayed `6%` next to a permanently-displayed `31%`. Everything becomes an icon that changes when something is wrong, with the number in the tooltip and the detail one pick away — which is what principles 3 and 4 wanted anyway, and which the existing `custom/nixos-upgrade` and `custom/project` modules already do.

The rules for the redesign:

- **Icon-first, one glyph wide.** A module shows a glyph. A number appears only when it earns the space — a battery percentage does, a CPU percentage at idle does not.
- **No rotated text.** Waybar supports `"rotate": 90`, and rotated labels on a bar you read a hundred times a day are a novelty that costs legibility every time. The exception, if any, is a single long-lived string like the project name; decide it by looking rather than in advance.
- **Two lines beat rotation.** The clock becomes `%H` over `%M` — five characters that do not fit become two lines of two that do, and it reads instantly. The date goes to the tooltip.
- **Drawers for the telemetry group.** Waybar's `group` in `drawer` mode collapses several modules behind one and expands on hover. cpu, memory, disk and temperature become one group that is a single glyph until pointed at. This is the `glance → hover → pick` ladder implemented literally, and it is what makes ten modules fit in a column.
- **Groups by kind, along the column**: workspaces and project at the top, state and tray in the middle, system and clock at the bottom. The horizontal bar's left/centre/right becomes top/centre/bottom, and the grouping question item 19 raised is answered by the layout rather than deferred.
- **Tooltips carry what the label used to.** `network`'s ifname and address, `battery`'s time remaining, `temperature`'s zones. This is also where the two `notify-send` right-clicks from item 3 land, which is the convergence noted there.

Mechanically: `"position": "left"`, `"width": 40`, `height` unset; `style.css`'s eight margin values and its left/right `border-radius` pairs all swap axis, which is most of the CSS work and is why this is _large_ rather than _medium_. Item 6's scale should land first so the swap is done once against final numbers.

Two things it drags with it. `dunst.nix` has `offset = "10x50"` on a `top-right` origin, where the 50 exists to clear the horizontal bar; with the bar on the left that offset is wrong. And swayosd from item 12 should be positioned against the new geometry rather than the old.

**One question is genuinely open and should be settled by looking**: with two monitors side by side, a left-edge bar on each puts the secondary's bar against the seam, in the middle of the combined desktop. The alternative is outer edges — left on the ultrawide, right on the secondary — which waybar supports as two bar definitions with different `output` and `position`, at the cost of duplicating the module list or splitting it into an included file. The recommendation is **left on every output first**, because it is one config and the seam objection may evaporate on sight; switch only if it does not.

### Cost and risk

A full session, possibly two, and it is the largest item here. It wants 3, 5 and 6 landed first, and it wants 9, 12, 13 and 14 landed first as well — not as a dependency, but because this is the item that decides which of the modules those add earn a permanent place on a bar that can no longer hold everything.

The risk is that a 40px bar turns out to be too narrow to be useful and the answer is 48 or 56, which is fine and is discovered by building it. The real risk is doing this before the modules exist and then doing it again.

## 22. Motion comes out

_Added 2026-09-06._

### The problem

`animations.lua` is 22 lines of carefully-chosen bezier curves, and the desktop would be faster without any of it. `layersIn` at speed 4 is 400 ms — every time rofi opens, the launcher spends four tenths of a second fading in before it is usable. Windows open in 300 ms. `global` is 1000 ms. Against principle 1's 150 ms rule the launcher is nearly three times over, and against the stated preference — no animations at all — the whole file is over.

### Approach

`hl.config({ animations = { enabled = false } })`, and the curves and per-leaf lines come out with it. One line changed, twenty deleted.

**The recommendation is off, not minimal.** The middle position exists — keep animations and set every user-initiated one to 60–80 ms, which is below the threshold where motion feels like waiting but above the threshold where a change is a hard cut — and it is the right answer for someone who is undecided in the abstract. It is not the right answer here, for two reasons. The first is that the stated preference is off, and a designed compromise that nobody asked for is worse than an answer that can be reversed in one line. The second is that the one real argument _for_ animation does not apply to this desktop: motion is worth its cost when it tells you something the end state does not, and the case that usually makes is orientation after a change of focus — which this desktop already solves with a border colour, as the requirement notes. An instantly-recoloured border is in fact a _better_ focus cue than an animated one, because there is no 200 ms window in which the answer is ambiguous.

There is one animation that carries information the end state genuinely does not, and it is worth naming so that missing it later is a recognised outcome rather than a puzzle: **the workspace slide tells you which direction you moved.** Switching from workspace 3 to 4 with no motion replaces the entire screen at once with no cue about whether you went left or right. Most people who turn animations off stop noticing within a day; some never stop. So: off wholesale, and if that one is missed after a week of real use, `workspaces` alone comes back at speed 1 (100 ms) and nothing else does. That is an answer decided by living with it rather than by reasoning about it, which is the right way round for a question this subjective.

Turning motion off also settles two things elsewhere. It withdraws the motion half of item 6, which no longer has a duration scale to design, and it removes one of item 16's three variables — leaving blur as the whole performance question rather than a third of it.

### Cost and risk

Minutes, and it is the first thing to do. Fully reversible: the deleted curves are in the git history and the file is 22 lines. The only risk is the workspace-direction cue above, which is named so that it can be recognised rather than rediscovered.

---

## Rejected

**A shell framework (AGS / Quickshell / eww).** These replace waybar, rofi, dunst and hyprlock with one programmable surface, and they are how the best-looking rices are built — a unified design language falls out for free instead of being enforced by hand. They are also a bespoke desktop shell to maintain, in a language and framework whose upstream moves fast, and the user's sixth principle is precisely a refusal of that. Waybar is not close to being the limiting factor. Not revisited until it is.

**Replacing Hyprland.** niri's scrolling layout and river's tag model are genuinely different and genuinely good, and adopting either means rewriting `binds.lua`, `rules.lua`, `monitors.lua` and the project-launcher daemon's assumptions. There is no problem in this document that a different compositor solves.

**Dedicated applets (`wlogout`, `nm-applet`, `blueman-applet`).** Four processes, four tray icons and four theming problems to solve one problem four times. Superseded by item 7. `blueman` remains under consideration for pairing specifically, which is the one flow a rofi menu should not attempt.

**A notification centre daemon (`swaync`).** Would give item 13 for free and would add a second GTK surface to theme and a daemon to replace a working one. Dunst plus `dunstctl` plus a rofi view gets the same result at the cost of two small scripts, which is the order principle 6 asks for. Revisit if the rofi history view is unusable in practice.

Item 12 adopting `swayosd` on 2026-09-06 sits next to this and does not contradict it, though it is close enough to be worth stating: swayosd is accepted because it does a job dunst does _badly_ — a transient, centred, undismissable overlay is not a notification and pinning it to the notification corner was always the weak part of that proposal. swaync is rejected because it would replace a job dunst does _well_. The test is not "how many daemons" but "does the daemon exist because the incumbent cannot do the job".

**`regreet`.** See item 18. A Wayland session in front of the Wayland session, for a screen that is visible for four seconds.

**Replacing thunar.** It is dated next to everything else here, and it is used for drag-and-drop and little else; yazi covers the keyboard case and the GTK file _picker_ comes from the portal, which stylix already themes. Low value, and not free — nautilus drags in a GNOME dependency chain. Left alone.

## Open questions

The four questions raised on 2026-09-05 were answered on 2026-09-06 and are recorded in _Decisions_ above. Three remain, and all three are of a kind that should be settled by building the thing and looking at it rather than by deciding now.

1. **Item 21: left edge on every output, or outer edges?** A left-edge bar on both side-by-side monitors puts one of them against the seam. Recommendation is left everywhere first, because it is one config instead of two; switch only if the seam is actually annoying.
2. **Item 22: does the workspace slide get missed?** Off wholesale first. If after a week of real use the loss of direction cue is felt, `workspaces` alone comes back at 100 ms.
3. **Item 21: is 40px the right width?** Discovered by building it. If the clock at two lines or the battery percentage does not read cleanly, the answer is 48.

One item is left open for a different reason. The hypridle `FIXME` about waking from suspend is a real defect, it predates this plan, and nothing here fixes it. It is noted in item 16 so that it is not lost, but it is not rice work and should probably be its own session.
