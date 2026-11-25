package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path"
	"strings"
	"unicode/utf8"
)

const (
	workspaceArg        = "mp.workspace"
	encodedWorkspaceArg = "mp.workspace_b64"
)

func parseWorkspace(fields []string) (string, error) {
	var workspace string
	var seen bool
	for _, field := range fields {
		name, value, assigned := strings.Cut(field, "=")
		key := strings.Trim(name, `"`)
		if key != workspaceArg && key != encodedWorkspaceArg {
			continue
		}
		if seen {
			return "", errors.New("duplicate workspace boot arguments")
		}
		seen = true
		if name != key || !assigned || value == "" {
			return "", fmt.Errorf("%s requires an unquoted value", key)
		}
		if key == encodedWorkspaceArg {
			// A cut-off base64 value might still decode as a shorter path.
			payload, complete := strings.CutSuffix(value, ".")
			decoded, err := base64.StdEncoding.Strict().DecodeString(payload)
			if !complete || err != nil {
				return "", fmt.Errorf("invalid %s value", key)
			}
			value = string(decoded)
		} else if strings.ContainsAny(value, `"'`) {
			return "", fmt.Errorf("quoted workspace paths require %s", encodedWorkspaceArg)
		}
		if !utf8.ValidString(value) || !path.IsAbs(value) || value == "/" ||
			path.Clean(value) != value || strings.ContainsAny(value, "\x00:") {
			return "", errors.New("workspace boot argument must name a canonical absolute share path")
		}
		workspace = value
	}
	return workspace, nil
}

// Stage 2 prepares the mount before starting any guest services. Refuse a
// pre-existing symlink, including one in an intermediate component of the path.
func prepareWorkspaceMount(workspace string) error {
	current := "/"
	for _, component := range strings.Split(strings.TrimPrefix(workspace, "/"), "/") {
		current = path.Join(current, component)
		if err := os.Mkdir(current, 0755); err == nil {
			continue
		} else if !errors.Is(err, os.ErrExist) {
			return err
		}
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if !info.IsDir() {
			return fmt.Errorf("workspace mount component is not a directory: %s", current)
		}
	}
	return nil
}
