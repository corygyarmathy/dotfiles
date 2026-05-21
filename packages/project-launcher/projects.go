package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Project represents a discovered project directory.
type Project struct {
	// Name is the directory basename, used as the display label.
	Name string
	// Path is the absolute path to the project directory.
	Path string
	// Slug is the sanitized identifier embedded in the workspace name.
	Slug string
}

// Workspace returns the Hyprland workspace name for this project.
// We use the slug directly; project-ness is determined by a disk
// lookup in projectFromWorkspace rather than a name prefix.
func (p Project) Workspace() string {
	return p.Slug
}

// slugRe matches anything that is NOT a safe slug character.
var slugRe = regexp.MustCompile(`[^a-z0-9-]+`)

// slugify turns a directory basename into a workspace-safe identifier.
// Lowercase, ASCII letters/digits/hyphens only, no leading or trailing hyphens.
func slugify(name string) string {
	s := strings.ToLower(name)
	s = slugRe.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	return s
}

// expandHome resolves a leading ~ to the user's home directory.
// Returns the input unchanged if it does not start with ~.
func expandHome(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	return path
}

// projectDirs returns the configured list of directories to scan.
// PROJECT_LAUNCHER_DIRS is a colon-separated path list. When unset, we fall
// back to ~/Projects and ~/git.
func projectDirs() []string {
	raw := os.Getenv("PROJECT_LAUNCHER_DIRS")
	if raw == "" {
		return []string{expandHome("~/Projects"), expandHome("~/git")}
	}
	var dirs []string
	for _, d := range strings.Split(raw, ":") {
		d = strings.TrimSpace(d)
		if d != "" {
			dirs = append(dirs, expandHome(d))
		}
	}
	return dirs
}

// discoverProjects returns every project found across the configured
// directories. A project is any immediate subdirectory of a scan root.
//
// Behaviour notes:
//   - Missing scan directories are silently skipped (a fresh machine might
//     not have ~/Projects yet, and that should not be an error).
//   - When the same project name appears in multiple scan directories,
//     the first occurrence wins. Order matches PROJECT_LAUNCHER_DIRS so
//     callers control precedence.
//   - Hidden directories (leading dot) are skipped to avoid noise from
//     things like ~/Projects/.cache.
func discoverProjects() ([]Project, error) {
	seenSlug := make(map[string]bool)
	var projects []Project

	for _, dir := range projectDirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("scanning %s: %w", dir, err)
		}

		for _, e := range entries {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			slug := slugify(e.Name())
			if slug == "" || seenSlug[slug] {
				continue
			}
			seenSlug[slug] = true
			projects = append(projects, Project{
				Name: e.Name(),
				Path: filepath.Join(dir, e.Name()),
				Slug: slug,
			})
		}
	}

	sort.Slice(projects, func(i, j int) bool {
		return strings.ToLower(projects[i].Name) < strings.ToLower(projects[j].Name)
	})

	return projects, nil
}

// projectFromWorkspace reconstructs a Project from a workspace name by
// matching the workspace slug against discovered projects. Returns nil
// if no project on disk has that slug.
func projectFromWorkspace(workspace string) *Project {
	if workspace == "" {
		return nil
	}
	projects, err := discoverProjects()
	if err != nil {
		return nil
	}
	for _, p := range projects {
		if p.Slug == workspace {
			return &p
		}
	}
	return nil
}
