package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

// runPick is the entry point for the `pick` subcommand. It discovers
// projects, presents them via rofi, and switches to the chosen workspace
// (creating and seeding it on first open).
func runPick() error {
	projects, err := discoverProjects()
	if err != nil {
		return err
	}
	if len(projects) == 0 {
		return fmt.Errorf("no projects found in %v", projectDirs())
	}

	choice, err := rofiPick(projects)
	if err != nil {
		return err
	}
	if choice == nil {
		// User dismissed the picker; not an error.
		return nil
	}

	exists, err := workspaceExists(choice.Workspace())
	if err != nil {
		return err
	}

	if err := switchToWorkspace(choice.Workspace()); err != nil {
		return err
	}

	// Only seed a fresh workspace; switching back to an existing project
	// must not spawn duplicate windows.
	if !exists {
		if err := initWorkspace(*choice); err != nil {
			return fmt.Errorf("seeding workspace: %w", err)
		}
	}
	return nil
}

// rofiPick shows the rofi picker with the given projects and returns the
// chosen project. A nil project (with nil error) signals the user dismissed
// the picker without selecting anything.
//
// We use rofi's dmenu mode and match the returned string against the input
// list. This is more robust than -format i (which interacts poorly with
// some rofi config combinations like history and sidebar-mode) and gives
// us actionable error messages when something genuinely goes wrong.
func rofiPick(projects []Project) (*Project, error) {
	// Build both the input list (one project name per line) and a reverse
	// lookup from name back to project. Project names come from directory
	// basenames, which we've already verified are unique by slug, so the
	// map cannot collide.
	var input bytes.Buffer
	byName := make(map[string]*Project, len(projects))
	for i := range projects {
		input.WriteString(projects[i].Name)
		input.WriteByte('\n')
		byName[projects[i].Name] = &projects[i]
	}

	cmd := exec.Command("rofi",
		"-dmenu",
		"-i",            // case-insensitive matching
		"-p", "Project", // prompt
	)
	cmd.Stdin = &input

	// Capture stderr separately so we can surface any rofi diagnostics
	// rather than swallowing them.
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	out, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			// rofi exits 1 when the user dismisses without selecting.
			return nil, nil
		}
		stderrMsg := strings.TrimSpace(stderr.String())
		if stderrMsg != "" {
			return nil, fmt.Errorf("running rofi: %w (stderr: %s)", err, stderrMsg)
		}
		return nil, fmt.Errorf("running rofi: %w", err)
	}

	selection := strings.TrimSpace(string(out))
	if selection == "" {
		return nil, nil
	}

	project, ok := byName[selection]
	if !ok {
		// This usually means rofi returned a filter string that didn't
		// match any item (e.g. user typed a non-matching query and pressed
		// Enter). Surface it rather than silently exit so the user knows
		// why nothing happened.
		return nil, fmt.Errorf("rofi returned %q which is not a known project", selection)
	}
	return project, nil
}
