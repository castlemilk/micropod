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

// The host config share: machine policy the host renders (cache-policy.json)
// for the engine, mounted read-only. Hosts that predate it pass no mp.config.
const (
	hostConfigArg   = "mp.config"
	hostConfigTag   = "mp-config"
	hostConfigMount = "/run/micropod/host-config"
)

// hostConfigEnv tells the engine what became of the host config share
// (hostConfigState). The engine's policy fails closed whenever the host asked
// for the share, so a share that did not mount, or a policy it cannot read,
// never turns an untrusted default into the trusted built-in one.
const hostConfigEnv = "MICROPOD_HOST_CONFIG"

// hostConfigState is hostConfigEnv's value: "" when the host asked for no
// share (the engine runs on its built-in policy), "mounted", or "unavailable"
// when it asked and the mount failed.
func hostConfigState(requested, mounted bool) string {
	switch {
	case !requested:
		return ""
	case mounted:
		return "mounted"
	default:
		return "unavailable"
	}
}

// The machine's own directory on the host (mp.private_b64, base64 with a
// trailing '.' like mp.workspace_b64): its disks, machine.json and the host
// config share. The standard machine keeps it in ~/.micropod/hvf, inside the
// default workspace (the home directory), so a bind of a workspace path could
// reach it. Guest init passes it to the engine (privateRootEnv) only when it
// lies in the workspace; the engine then refuses a bind source inside it and
// hides it in a bind that covers it.
const (
	privateRootArg = "mp.private_b64"
	privateRootEnv = "MICROPOD_ENGINE_PRIVATE"
)

// parsePrivateRoot returns the machine directory to protect, or "" when the
// host names none or it is outside the workspace (nothing in the guest
// reaches it then).
func parsePrivateRoot(params map[string]string, workspace string) (string, error) {
	value, ok := params[privateRootArg]
	if !ok {
		return "", nil
	}
	payload, complete := strings.CutSuffix(value, ".")
	decoded, err := base64.StdEncoding.Strict().DecodeString(payload)
	if !complete || err != nil {
		return "", fmt.Errorf("invalid %s value", privateRootArg)
	}
	p := string(decoded)
	if !utf8.ValidString(p) || !path.IsAbs(p) || p == "/" || path.Clean(p) != p || strings.ContainsAny(p, "\x00") {
		return "", fmt.Errorf("%s must name a canonical absolute path", privateRootArg)
	}
	if workspace == "" || !within(p, workspace) {
		return "", nil
	}
	return p, nil
}

func cmdlineParams(fields []string) map[string]string {
	out := map[string]string{}
	for _, f := range fields {
		if k, v, ok := strings.Cut(f, "="); ok {
			out[k] = v
		}
	}
	return out
}

// hostConfigRequested reports whether the host shares its config directory
// (mp.config=1). Any other value mounts nothing, and is returned as an error
// to log: the engine then runs on its built-in policy defaults.
func hostConfigRequested(params map[string]string) (bool, error) {
	value, ok := params[hostConfigArg]
	switch {
	case !ok || value == "0":
		return false, nil
	case value == "1":
		return true, nil
	default:
		return false, fmt.Errorf("ignoring %s=%q (want 1)", hostConfigArg, value)
	}
}

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
		if reserved := reservedOverlap(value); reserved != "" {
			return "", fmt.Errorf("workspace %q would hide the guest's %s", value, reserved)
		}
		workspace = value
	}
	return workspace, nil
}

// reservedTrees are guest directories a workspace may neither cover nor sit
// inside: system directories and the mounts stage 2 and the engine rely on
// (oci-tools, the vsock bridge sockets, engine state). micropod-vmm's
// --workspace check refuses the same paths before boot.
var reservedTrees = []string{
	"/bin", "/dev", "/etc", "/lib", "/opt/micropod-oci", "/proc", "/root",
	"/run", "/sbin", "/sys", "/usr", "/var/lib",
}

// reservedMounts may contain a workspace but not be covered by one.
var reservedMounts = []string{"/tmp"}

func within(p, dir string) bool {
	return p == dir || strings.HasPrefix(p, dir+"/")
}

// reservedOverlap names the guest directory a workspace mounted at p would
// hide, or returns "".
func reservedOverlap(p string) string {
	for _, r := range append(append([]string{}, reservedTrees...), reservedMounts...) {
		if within(r, p) {
			return r
		}
	}
	for _, r := range reservedTrees {
		if within(p, r) {
			return r
		}
	}
	return ""
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
