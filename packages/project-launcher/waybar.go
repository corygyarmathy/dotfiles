package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

// waybarOutput is the JSON shape waybar expects from a custom module
// with return-type set to "json".
type waybarOutput struct {
	Text    string `json:"text"`
	Tooltip string `json:"tooltip,omitempty"`
	Class   string `json:"class,omitempty"`
}

// renderWaybar produces the waybar payload for a given active workspace.
// When the workspace is not a project workspace, the result is an empty,
// "inactive"-classed module that CSS can collapse.
func renderWaybar(ws workspaceState) waybarOutput {
	p := projectFromWorkspace(ws.Name)
	if p == nil {
		return waybarOutput{Class: "inactive"}
	}
	return waybarOutput{
		Text:    "  " + p.Name,
		Tooltip: p.Path,
		Class:   "active",
	}
}

// runWaybar streams waybar JSON updates driven by Hyprland events.
//
// We emit an initial state immediately so the bar populates before the user
// has interacted with any workspace, then re-emit on any event that could
// change the active workspace or its name. Querying state on every relevant
// event is cheap (sub-millisecond hyprctl call) and avoids the complexity
// of parsing each event payload to mutate cached state ourselves.
//
// If the event socket disconnects (e.g. Hyprland restart), we wait briefly
// and reconnect rather than dying — waybar would respawn us, but keeping
// the process alive avoids a flash of empty state during a config reload.
func runWaybar() error {
	enc := json.NewEncoder(os.Stdout)

	emit := func() {
		ws, err := activeWorkspace()
		if err != nil {
			// Don't emit garbage on transient hyprctl failures; the next
			// event will trigger a retry.
			return
		}
		_ = enc.Encode(renderWaybar(ws))
	}

	for {
		emit()

		// Fresh context per subscription so the close-watcher goroutine
		// inside subscribeEvents exits cleanly when the socket dies on
		// Hyprland restart, rather than accumulating across reconnects.
		ctx, cancel := context.WithCancel(context.Background())
		events, err := subscribeEvents(ctx)
		if err != nil {
			// Hyprland may not be ready yet during early session startup.
			// Back off and retry rather than exiting.
			cancel()
			time.Sleep(500 * time.Millisecond)
			continue
		}

		for ev := range events {
			if isWorkspaceEvent(ev) {
				emit()
			}
		}
		cancel()

		// Socket closed (likely Hyprland restart). Reconnect after a beat.
		time.Sleep(250 * time.Millisecond)
	}
}

// isWorkspaceEvent reports whether a Hyprland event could change either
// the active workspace or its name. We deliberately include rename events
// so a user-renamed workspace updates the bar.
func isWorkspaceEvent(ev string) bool {
	// Events are formatted as "name>>data". We only need the name part.
	name := ev
	if i := strings.Index(ev, ">>"); i >= 0 {
		name = ev[:i]
	}
	switch name {
	case "workspace", "workspacev2",
		"focusedmon", "focusedmonv2",
		"createworkspace", "createworkspacev2",
		"destroyworkspace", "destroyworkspacev2",
		"renameworkspace",
		"activespecial", "activespecialv2":
		return true
	}
	return false
}

// runCurrent prints the name of the active project (without the workspace
// prefix), or nothing if no project workspace is focused. Useful for
// scripting and quick sanity checks.
func runCurrent() error {
	ws, err := activeWorkspace()
	if err != nil {
		return err
	}
	if p := projectFromWorkspace(ws.Name); p != nil {
		fmt.Println(p.Name)
	}
	return nil
}

// clientRef is the minimal shape we need from hyprctl clients.
type clientRef struct {
	Address   string         `json:"address"`
	Workspace workspaceState `json:"workspace"`
}

// runClose closes every window in the current project workspace. If the
// active workspace isn't a project workspace, runClose is a no-op rather
// than an error — making the keybind safe to press from anywhere.
//
// Targeting by address uses the {address = ...} form, matching the
// {action = ...} / {direction = ...} table convention seen elsewhere in
// the hl.dsp.window namespace.
func runClose() error {
	ws, err := activeWorkspace()
	if err != nil {
		return err
	}
	if projectFromWorkspace(ws.Name) == nil {
		return nil
	}

	var clients []clientRef
	if err := hyprctlJSON(&clients, "clients"); err != nil {
		return err
	}

	for _, c := range clients {
		if c.Workspace.Name != ws.Name {
			continue
		}
		expr := fmt.Sprintf(`hl.dsp.window.close({address = %q})`, c.Address)
		if err := hyprDispatch(expr); err != nil {
			return fmt.Errorf("closing %s: %w", c.Address, err)
		}
	}
	return nil
}
