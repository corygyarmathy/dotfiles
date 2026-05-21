package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Hyprland exposes two UNIX sockets per instance:
//
//	.socket.sock   — request/response, where dispatch commands are sent
//	.socket2.sock  — broadcast event stream (workspace changes, etc.)
//
// On Hyprland 0.55+ the dispatcher path is fully Lua-mediated:
// `hyprctl dispatch X` is shorthand for `eval 'hl.dispatch(X)'`, where X
// must be a dispatcher value from the hl.dsp.* namespace, not a string
// command. We construct those Lua expressions and send them over the
// command socket. Read-only queries still go through hyprctl -j, which
// returns JSON cleanly and is not affected by the Lua wrapping.
//
// References:
//
//	https://wiki.hypr.land/Configuring/Basics/Dispatchers/
//	https://github.com/hyprwm/Hyprland/blob/main/example/hyprland.lua

// hyprSocketPath returns the path to a Hyprland socket file.
// kind is either "" (command socket) or "2" (event socket).
func hyprSocketPath(kind string) (string, error) {
	sig := os.Getenv("HYPRLAND_INSTANCE_SIGNATURE")
	if sig == "" {
		return "", fmt.Errorf("HYPRLAND_INSTANCE_SIGNATURE is not set (is Hyprland running?)")
	}

	runtime := os.Getenv("XDG_RUNTIME_DIR")
	candidates := []string{}
	if runtime != "" {
		candidates = append(candidates, filepath.Join(runtime, "hypr", sig, ".socket"+kind+".sock"))
	}
	candidates = append(candidates, filepath.Join("/tmp", "hypr", sig, ".socket"+kind+".sock"))

	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", fmt.Errorf("hyprland socket not found (tried %v)", candidates)
}

// hyprctl shells out to hyprctl for read-only queries.
// Do NOT use this for dispatch commands; see hyprDispatch.
func hyprctl(args ...string) (string, error) {
	cmd := exec.Command("hyprctl", args...)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("hyprctl %s: %w", strings.Join(args, " "), err)
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// hyprctlJSON runs hyprctl with -j and decodes the JSON output into v.
func hyprctlJSON(v any, args ...string) error {
	full := append([]string{"-j"}, args...)
	out, err := hyprctl(full...)
	if err != nil {
		return err
	}
	if err := json.Unmarshal([]byte(out), v); err != nil {
		return fmt.Errorf("decoding hyprctl %s: %w", strings.Join(args, " "), err)
	}
	return nil
}

// hyprDispatch sends a Lua dispatcher expression to Hyprland.
// luaExpr must be a complete dispatcher call from the hl.dsp.* namespace.
func hyprDispatch(luaExpr string) error {
	path, err := hyprSocketPath("")
	if err != nil {
		return err
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		return fmt.Errorf("connecting to command socket: %w", err)
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))

	payload := "dispatch " + luaExpr
	if _, err := io.WriteString(conn, payload); err != nil {
		return fmt.Errorf("sending %q: %w", payload, err)
	}

	resp, err := io.ReadAll(conn)
	if err != nil {
		return fmt.Errorf("reading response to %q: %w", payload, err)
	}

	text := strings.TrimSpace(string(resp))
	if text != "ok" {
		return fmt.Errorf("hyprland rejected %s: %s", luaExpr, text)
	}
	return nil
}

// workspaceState is the subset of hyprctl's activeworkspace output we care about.
type workspaceState struct {
	Name    string `json:"name"`
	Monitor string `json:"monitor"`
}

// activeWorkspace returns the currently focused workspace.
func activeWorkspace() (workspaceState, error) {
	var ws workspaceState
	if err := hyprctlJSON(&ws, "activeworkspace"); err != nil {
		return ws, err
	}
	return ws, nil
}

// workspaceExists reports whether a workspace with the given name is open.
func workspaceExists(name string) (bool, error) {
	var workspaces []workspaceState
	if err := hyprctlJSON(&workspaces, "workspaces"); err != nil {
		return false, err
	}
	for _, w := range workspaces {
		if w.Name == name {
			return true, nil
		}
	}
	return false, nil
}

// switchToWorkspace focuses the named workspace, creating it on the target
// monitor if it does not already exist.
func switchToWorkspace(name string) error {
	exists, err := workspaceExists(name)
	if err != nil {
		return err
	}

	if !exists {
		if monitor := os.Getenv("PROJECT_LAUNCHER_MONITOR"); monitor != "" {
			expr := fmt.Sprintf(`hl.dsp.focus({monitor = %q})`, monitor)
			if err := hyprDispatch(expr); err != nil {
				return fmt.Errorf("focusing monitor: %w", err)
			}
		}
	}

	expr := fmt.Sprintf(`hl.dsp.focus({workspace = "name:%s"})`, name)
	if err := hyprDispatch(expr); err != nil {
		return fmt.Errorf("switching workspace: %w", err)
	}
	return nil
}

// initWorkspace populates a fresh project workspace with editor + shell.
//
// Each spawn is pinned to the target workspace via the exec_cmd rules
// table, so the result is independent of whichever workspace is focused
// when the dispatch arrives. We subscribe to events BEFORE the first
// spawn so we cannot miss an openwindow event, then block until each
// window has actually mapped before issuing the next spawn — that gives
// dwindle a deterministic split target rather than a race between two
// concurrently-starting Ghostty processes.
func initWorkspace(p Project) error {
	ws := p.Workspace()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	events, err := subscribeEvents(ctx)
	if err != nil {
		return fmt.Errorf("subscribing to events: %w", err)
	}

	spawn := func(cmd string) error {
		expr := fmt.Sprintf(`hl.dsp.exec_cmd(%q, { workspace = %q })`,
			cmd, "name:"+ws)
		return hyprDispatch(expr)
	}

	editor := fmt.Sprintf("ghostty --working-directory=%q -e nvim", p.Path)
	if err := spawn(editor); err != nil {
		return fmt.Errorf("spawning editor: %w", err)
	}
	if err := waitForOpenWindowOn(ctx, events, ws); err != nil {
		return fmt.Errorf("waiting for editor to map: %w", err)
	}

	shell := fmt.Sprintf("ghostty --working-directory=%q", p.Path)
	if err := spawn(shell); err != nil {
		return fmt.Errorf("spawning shell: %w", err)
	}
	if err := waitForOpenWindowOn(ctx, events, ws); err != nil {
		return fmt.Errorf("waiting for shell to map: %w", err)
	}

	return nil
}

// subscribeEvents returns a channel of Hyprland event lines. The channel
// closes when the socket disconnects or ctx is cancelled, whichever comes
// first; callers can re-subscribe to reconnect.
//
// Event format from .socket2.sock: "EVENT>>DATA\n"
func subscribeEvents(ctx context.Context) (<-chan string, error) {
	path, err := hyprSocketPath("2")
	if err != nil {
		return nil, err
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, fmt.Errorf("connecting to event socket: %w", err)
	}

	// Closing the socket on ctx.Done unblocks the Scan loop below, which
	// is the only portable way to interrupt a blocking Read in Go.
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()

	ch := make(chan string, 16)
	go func() {
		defer close(ch)
		scanner := bufio.NewScanner(conn)
		scanner.Buffer(make([]byte, 0, 4096), 1024*1024)
		for scanner.Scan() {
			ch <- scanner.Text()
		}
	}()
	return ch, nil
}

// waitForOpenWindowOn blocks until an openwindow event arrives for the
// named workspace, or ctx is cancelled. The data payload format is
// "ADDRESS,WORKSPACENAME,WINDOWCLASS,WINDOWTITLE" per Hyprland's IPC spec.
func waitForOpenWindowOn(ctx context.Context, events <-chan string, workspace string) error {
	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for openwindow on %q: %w", workspace, ctx.Err())
		case ev, ok := <-events:
			if !ok {
				return fmt.Errorf("event socket closed while waiting for openwindow on %q", workspace)
			}
			name, data, found := strings.Cut(ev, ">>")
			if !found || name != "openwindow" {
				continue
			}
			parts := strings.SplitN(data, ",", 4)
			if len(parts) >= 2 && parts[1] == workspace {
				return nil
			}
		}
	}
}
