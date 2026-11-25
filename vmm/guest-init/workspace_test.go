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
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseWorkspace(strings.Fields(tc.args))
			if (err != nil) != tc.invalid || got != tc.want {
				t.Fatalf("parseWorkspace() = %q, %v, want %q, invalid %t", got, err, tc.want, tc.invalid)
			}
		})
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
