// project-launcher is a Hyprland-aware project workspace manager.
//
// It scans configured directories for projects, lets you fuzzy-pick one via
// rofi, and either creates a new named Hyprland workspace (with nvim and a
// terminal pre-seeded) or switches focus to an existing one. It can also
// stream the current project name as a JSON feed for waybar.
package main

import (
	"fmt"
	"os"
)

const usage = `project-launcher — project workspace manager for Hyprland

Usage:
  project-launcher pick     Open the rofi picker and switch to a project
  project-launcher waybar   Stream JSON updates for the waybar module
  project-launcher current  Print the active project name (empty if none)
  project-launcher close    Close all windows in the current project workspace

Environment:
  PROJECT_LAUNCHER_DIRS  Colon-separated list of directories to scan.
                         Defaults to ~/Projects:~/git when unset.
  PROJECT_LAUNCHER_MONITOR
                         Monitor descriptor to pin new project workspaces to.
                         When unset, projects open on the currently focused
                         monitor.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "pick":
		err = runPick()
	case "waybar":
		err = runWaybar()
	case "current":
		err = runCurrent()
	case "close":
		err = runClose()
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "project-launcher: %v\n", err)
		os.Exit(1)
	}
}
