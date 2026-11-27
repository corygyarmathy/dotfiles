# Plan: one shell, in Quickshell

Replace waybar, rofi, dunst, swayosd and hyprlock with a single Quickshell shell, redesigned around a vertical bar rather than recreating the current tools. The design borrows from the shells in [the Quickshell shell survey](../research/quickshell-shell-survey.md), which owns every external fact cited here. Progress lives in the issues and PRs this plan produces, not here.

## Why

The desktop works, but it is six tools themed and checked separately, plus a dozen rofi scripts over `nmcli`, `bluetoothctl` and `wpctl`. Consistency is held together by generated colour files and build gates on each tool. The bar is functional but not good.

Quickshell now has native services for most of what the scripts do (PipeWire, Bluetooth, MPRIS, notifications, tray, UPower, Hyprland, session lock, PAM, polkit, and since v0.3.0 networking), so the scripts are replaced rather than ported. One surface also makes consistency structural: one theme file that everything reads, instead of copies checked against each other.

The cost is a bespoke shell on a pre-1.0 framework. See _Risks_.

## Rules

- **Scope test.** A feature goes in only if it passes Noctalia's four questions: does it need the shell core, does it extend something that exists, does it fit the existing stack, who maintains it in a year. "Another shell has it" is not a reason.
- **Ownership.** Quickshell owns every surface outside an application: bar, panels, launcher, notifications, OSD and lock screen. Hyprland owns window geometry. hypridle owns idle timing and logind events. `lib/kanagawa-wave.nix` owns colour, and stylix applies it to applications.
- **Keyboard and pointer both.** Every panel has a keybind (`qs ipc call <target> <function>`) and a click target.
- **No motion.** No `Behavior` or animation blocks. The only gradual change allowed is one the system makes on its own schedule, such as a night-light fade. Toggles snap.
- **Nothing takes focus uninvited.** Notification popups never take focus.

## Design

**One process.** Every surface lives in one Quickshell config under `configs/quickshell/`, deployed through home-manager's `programs.quickshell` as a systemd user service. The lock screen is the exception; see below.

**The bar.** Vertical, 40px, on the left edge of every output. Each module is a single glyph. A number appears only when it earns the space: battery yes, idle CPU no. There is no rotated text. The clock is `HH` over `MM`, with the date in its tooltip, and tooltips carry what labels used to. From top to bottom:

- _Navigation:_ the workspaces on that output, then the active project.
- _Attention, empty when all is well:_ failed units, a pending upgrade, and CPU, memory, disk or temperature only past a threshold. Normal telemetry is not shown at all.
- _State:_ media while something plays, privacy (mic or screen in use), tray.
- _System:_ network, bluetooth, audio, battery, clock, power.

**Panels open beside the icon that opened them**, attached to the bar at that icon's height. Only one is open at a time, and Escape or a click outside closes it. Without motion, the attachment is what shows where a panel came from. There are four:

1. **Quick settings.** Tiles for Wi-Fi, Bluetooth, audio output, microphone, do-not-disturb, idle inhibit and night light, plus sliders for volume and brightness (backlight and DDC). Clicking a tile toggles it; its arrow opens the networks, devices or sinks in place. The bar's network, bluetooth and audio icons open this panel at their section, so they are three entry points into one surface.
2. **Calendar and notifications.** Opened from the clock: a month view, the notification history and a DND toggle. Popups appear top-right, away from the bar.
3. **System.** Opened from any attention icon: failed units with their journal, upgrade status, telemetry with numbers.
4. **Session.** Opened from the power icon: lock, log out, suspend, reboot, power off. Opening the panel is the first deliberate step and picking the action is the second, so there is no confirmation dialog.

**The launcher** is centred. By default it searches apps and evaluates arithmetic; a prefix switches the mode:

| Prefix | Mode                      |
| ------ | ------------------------- |
| `;`    | clipboard history         |
| `>`    | session and shell actions |
| `@`    | projects                  |
| `?`    | the keybind sheet         |
| `/`    | lists the prefixes        |

Nested choices drill in by rewriting the query and keeping the launcher open. A dmenu-style entry point accepts a list on stdin, so the project picker and any script not yet rewritten can use the launcher straight away. Delete it once nothing calls it.

**The OSD** appears against the bar at the height of the audio and brightness icons, takes no input, and disappears after a timeout.

**Lock and idle.** The lock screen is Quickshell's `WlSessionLock` with its PAM service, running as its own `qs` instance with its own unit, so a crash in the bar and a crash in the lock cannot take each other down. Three more layers cover the lock itself dying:

- Hyprland's `misc:allow_session_lock_restore = true`, so a restarted locker is accepted.
- On start, the lock locks again if logind reports the session as locked.
- hypridle's lock command is `qs ipc … lock || hyprlock`, so the screen still locks when the shell is dead. hyprlock stays installed for that case only.

hypridle stays as the idle engine. Quickshell's `IdleMonitor` can time idle periods, but it cannot see logind's sleep and lock signals without a compiled helper. hypridle's open `FIXME` about waking from suspend comes with it and is fixed as part of this work.

**Night light** stays on hyprsunset, controlled from its tile.

**Theme.** A single `Theme.qml` singleton holds the palette, the geometry scale and the type sizes. Nothing else names a colour or a length. It is generated at build time from `lib/kanagawa-wave.nix` and `lib/geometry.nix`. The config is Nix-only, so there is no checked-in copy and no drift gate.

**The toggle.** `cg.home.desktop.shell` is an enum, `"classic"` or `"quickshell"`, and defaults to `"classic"` until the switch. It sets each tool's existing enable with `mkDefault`, so a host can still override one. It also asserts that exactly one notification daemon is enabled. `binds.lua` loads a small `shell-binds.lua` chosen by the toggle, holding only the launcher, menu and lock binds, and the binds-commands gate is extended to read that file too.

**One gate.** A VM test in `checks/` starts a headless sway and runs `qs` against the deployed config. It passes only if `Configuration Loaded` appears with no `WARN scene`, `ReferenceError` or `TypeError` line before the timeout. A shell that does not load leaves no bar, no notifications and no lock, and nothing else would say so. No other gate is added until a real silent failure earns one. `qmllint` is not used, because it reports false errors on the current release.

## Sequence

1. **Spikes.** Each is short and settles one detail above:
    - `Quickshell.Networking` against `nmcli` on this machine's NetworkManager.
    - Whether hyprsunset's IPC is reliable on the current Hyprland.
    - Kill the lock instance while locked, and confirm the restore and the re-lock work.
    - Whether a second `qs -p` entry file in the same config directory can import its `qs.*` modules. This decides how the lock instance shares `Theme.qml`.
2. **Skeleton:** the toggle, `Theme.qml`, the bar with workspaces, clock and tray, and the load gate.
3. **Quick settings, OSD and notifications.** These retire dunst, swayosd and the network, bluetooth, audio and DND menus.
4. **Launcher,** with the dmenu entry point. This retires rofi.
5. **Lock,** which makes hyprlock the fallback only.
6. **Switch `xps15`.** After two weeks of daily use, delete the classic stack and its gates, then this file.

## Risks

**Quickshell is pre-1.0** and says it will break things before 1.0. v0.3.0 changed shell ids for symlinked configs, and the large shells all run on git builds or forks. Use only core services, stay on the nixpkgs release, and treat Quickshell upgrades as deliberate changes. The toggle keeps the classic stack one option away until step 6.

**The lock screen** is the one surface where a bug locks the user out. That is why it has three independent layers, and why spike 3 tests them before the lock ships.
