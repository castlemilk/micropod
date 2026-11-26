package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseWorkspace(t *testing.T) {
	const complex = `/private/tmp/build "two words" µ`
	const token = "mp.workspace_b64=L3ByaXZhdGUvdG1wL2J1aWxkICJ0d28gd29yZHMiIMK1."
	encoded := func(path string) string {
		return encodedWorkspaceArg + "=" + base64.StdEncoding.EncodeToString([]byte(path)) + "."
	}
	for _, tc := range []struct {
		name    string
		args    string
		want    string
		invalid bool
	}{
		{name: "absent", args: "mp.worker=sample panic=-1"},
		{name: "legacy", args: "mp.workspace=/private/tmp/checkout panic=-1", want: "/private/tmp/checkout"},
		{name: "canonical UTF-8 from Swift", args: token + " panic=-1", want: complex},
		{name: "space at end", args: encoded("/private/tmp/directory "), want: "/private/tmp/directory "},
		{name: "kernel-like tokens in path", args: encoded("/Users/work mp.instance=literal -- path"), want: "/Users/work mp.instance=literal -- path"},
		{name: "duplicate legacy", args: "mp.workspace=/test mp.workspace=/test", invalid: true},
		{name: "duplicate encoded", args: token + " " + token, invalid: true},
		{name: "mixed encodings", args: "mp.workspace=/test " + token, invalid: true},
		{name: "empty legacy", args: "mp.workspace=", invalid: true},
		{name: "missing assignment", args: "mp.workspace_b64", invalid: true},
		{name: "quoted legacy", args: `mp.workspace="/Users/test path"`, invalid: true},
		{name: "quoted key", args: `"mp.workspace=/Users/test"`, invalid: true},
		{name: "truncated encoded", args: strings.TrimSuffix(token, "."), invalid: true},
		{name: "invalid alphabet", args: "mp.workspace_b64=%bad.", invalid: true},
		{name: "noncanonical padding bits", args: "mp.workspace_b64=L2F=.", invalid: true},
		{name: "relative", args: encoded("relative path"), invalid: true},
		{name: "root", args: "mp.workspace=/", invalid: true},
		{name: "traversal", args: encoded("/private/tmp/target/../other"), invalid: true},
		{name: "ambiguous share delimiter", args: encoded("/private/tmp/parent:suffix"), invalid: true},
		{name: "NUL", args: encoded("/private/tmp/a\x00b"), invalid: true},
		{name: "invalid UTF-8", args: encoded("/private/tmp/" + string([]byte{0xff})), invalid: true},
		{name: "hides oci-tools", args: "mp.workspace=/opt", invalid: true},
		{name: "hides engine state", args: "mp.workspace=/var", invalid: true},
		{name: "inside engine state", args: "mp.workspace=/var/lib/docker", invalid: true},
		{name: "covers tmp", args: "mp.workspace=/tmp", invalid: true},
		{name: "inside usr", args: encoded("/usr/local/src"), invalid: true},
		{name: "etc", args: "mp.workspace=/etc", invalid: true},
		{name: "inside tmp", args: "mp.workspace=/tmp/mpe2e.x/ws", want: "/tmp/mpe2e.x/ws"},
		{name: "homebrew opt", args: "mp.workspace=/opt/homebrew/src", want: "/opt/homebrew/src"},
		{name: "var folders", args: "mp.workspace=/var/folders/ab/T", want: "/var/folders/ab/T"},
		{name: "prefix lookalike", args: "mp.workspace=/library", want: "/library"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseWorkspace(strings.Fields(tc.args))
			if (err != nil) != tc.invalid || got != tc.want {
				t.Fatalf("parseWorkspace() = %q, %v, want %q, invalid %t", got, err, tc.want, tc.invalid)
			}
		})
	}
}

func TestHostConfigRequested(t *testing.T) {
	for _, tc := range []struct {
		name    string
		args    string
		want    bool
		invalid bool
	}{
		{name: "old host", args: "console=ttyAMA0 mp.worker=sample panic=-1"},
		{name: "requested", args: "panic=-1 mp.config=1", want: true},
		{name: "with workspace", args: "mp.workspace_b64=L3RtcC93cw==. mp.config=1 mp.mtu=9000", want: true},
		{name: "off", args: "mp.config=0"},
		{name: "last one wins", args: "mp.config=0 mp.config=1", want: true},
		{name: "turned off again", args: "mp.config=1 mp.config=0"},
		{name: "bare key", args: "mp.config"},
		{name: "empty", args: "mp.config=", invalid: true},
		{name: "word", args: "mp.config=yes", invalid: true},
		{name: "quoted", args: `mp.config="1"`, invalid: true},
		{name: "lookalike key", args: "mp.configs=1 mp.config_b64=1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := hostConfigRequested(cmdlineParams(strings.Fields(tc.args)))
			if got != tc.want || (err != nil) != tc.invalid {
				t.Fatalf("hostConfigRequested(%q) = %t, %v; want %t, invalid %t", tc.args, got, err, tc.want, tc.invalid)
			}
		})
	}
	// The mount point must never be one a workspace may take or hide.
	if reserved := reservedOverlap(hostConfigMount); reserved != "/run" {
		t.Fatalf("reservedOverlap(%q) = %q, want /run", hostConfigMount, reserved)
	}
}

func TestPrepareWorkspaceMountRejectsSymlinks(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	good := filepath.Join(root, `my "quoted" workspace`, "child")
	if err := prepareWorkspaceMount(good); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(good); err != nil || !info.IsDir() {
		t.Fatalf("workspace mountpoint was not created: %v", err)
	}
	target := filepath.Join(root, "somewhere else")
	if err := os.Mkdir(target, 0755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(target, alias); err != nil {
		t.Fatal(err)
	}
	if err := prepareWorkspaceMount(filepath.Join(alias, "child")); err == nil {
		t.Fatal("accepted a symlink in the workspace mountpoint")
	}
	if _, err := os.Lstat(filepath.Join(target, "child")); !os.IsNotExist(err) {
		t.Fatalf("workspace mount preparation followed a symlink: %v", err)
	}
}

// The engine learns what became of the host config share, so its cache
// policy fails closed whenever the host asked for one.
func TestHostConfigState(t *testing.T) {
	for _, tc := range []struct {
		requested, mounted bool
		want               string
	}{{false, false, ""}, {false, true, ""}, {true, true, "mounted"}, {true, false, "unavailable"}} {
		if got := hostConfigState(tc.requested, tc.mounted); got != tc.want {
			t.Fatalf("hostConfigState(%v, %v) = %q, want %q", tc.requested, tc.mounted, got, tc.want)
		}
	}
}

// mp.private_b64 names the machine directory to the engine only when it lies
// in the workspace, and only as a canonical absolute path.
func TestParsePrivateRoot(t *testing.T) {
	enc := func(p string) string { return base64.StdEncoding.EncodeToString([]byte(p)) + "." }
	for _, tc := range []struct {
		name, args, workspace, want string
		invalid                     bool
	}{
		{name: "standard machine", args: "mp.private_b64=" + enc("/Users/me/.micropod/hvf"), workspace: "/Users/me", want: "/Users/me/.micropod/hvf"},
		{name: "the workspace itself", args: "mp.private_b64=" + enc("/Users/me"), workspace: "/Users/me", want: "/Users/me"},
		{name: "outside the workspace", args: "mp.private_b64=" + enc("/private/tmp/m"), workspace: "/Users/me"},
		{name: "a sibling prefix", args: "mp.private_b64=" + enc("/Users/me2/m"), workspace: "/Users/me"},
		{name: "no workspace", args: "mp.private_b64=" + enc("/Users/me/.micropod/hvf")},
		{name: "old host", args: "mp.config=1", workspace: "/Users/me"},
		{name: "cut off", args: "mp.private_b64=" + strings.TrimSuffix(enc("/Users/me/x"), "."), workspace: "/Users/me", invalid: true},
		{name: "not base64", args: "mp.private_b64=@@.", workspace: "/Users/me", invalid: true},
		{name: "relative", args: "mp.private_b64=" + enc("me/x"), workspace: "/Users/me", invalid: true},
		{name: "unclean", args: "mp.private_b64=" + enc("/Users/me/../x"), workspace: "/Users/me", invalid: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parsePrivateRoot(cmdlineParams(strings.Fields(tc.args)), tc.workspace)
			if got != tc.want || (err != nil) != tc.invalid {
				t.Fatalf("parsePrivateRoot(%q, %q) = %q, %v; want %q, invalid %v", tc.args, tc.workspace, got, err, tc.want, tc.invalid)
			}
		})
	}
}
