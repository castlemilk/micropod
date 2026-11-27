package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"slices"
	"strings"

	"github.com/distribution/reference"
)

// ctrPath is the bundle's ctr (a variable only so tests can stand one in).
var ctrPath = "/opt/micropod-oci/runner/bin/ctr"

// These infrequent, streaming image operations use the same namespace and
// snapshotter as CRI and BuildKit. Image bytes never enter the agent heap.
func imageCommand(ctx context.Context, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, ctrPath, append([]string{"--namespace", "k8s.io", "images"}, args...)...)
}

type toolTail []byte

func (b *toolTail) Write(p []byte) (int, error) {
	n := len(p)
	const max = 8192
	if n >= max {
		*b = append((*b)[:0], p[n-max:]...)
	} else {
		*b = append(*b, p...)
		if len(*b) > max {
			*b = (*b)[len(*b)-max:]
		}
	}
	return n, nil
}

// Resolve Docker's implicit registry, library namespace and latest tag. ctr
// requires canonical references; invalid flags or whitespace are never arguments.
func imageName(s string) (string, error) {
	if s == "" || s[0] == '-' || strings.ContainsAny(s, " \t\r\n\x00") {
		return "", errors.New("invalid image reference")
	}
	head, _, slash := strings.Cut(s, "/")
	if !slash {
		s = "docker.io/library/" + s
	} else if !strings.ContainsAny(head, ".:") && head != "localhost" {
		s = "docker.io/" + s
	}
	if !strings.ContainsAny(s[strings.LastIndexByte(s, '/')+1:], ":@") {
		s += ":latest"
	}
	return s, nil
}

func importImages(w http.ResponseWriter, r *http.Request) error {
	cmd := imageCommand(r.Context(), "import", "--local", "--digests", "--skip-digest-for-named", "--platform", "linux/arm64", "-")
	var out toolTail
	cmd.Stdin = r.Body
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		return fail(400, fmt.Sprintf("image import: %s: %v", out, err))
	}
	// ctr unpacked what it imported: on the disk before the load answers
	// (image_durability_linux.go).
	if err := imageSync.Sync(); err != nil {
		return err
	}
	writeJSON(w, 200, map[string]string{"stream": string(out)})
	return nil
}
func (s *dockerEngine) exportImages(w http.ResponseWriter, r *http.Request, refs []string) error {
	if len(refs) == 0 {
		return fail(400, "an image name is required")
	}
	if slices.ContainsFunc(refs, func(raw string) bool {
		ref, err := reference.ParseNormalizedNamed(raw)
		_, canonical := ref.(reference.Canonical)
		return err == nil && canonical
	}) {
		return s.exportDigestImages(w, r, refs)
	}
	args := []string{"export", "--local", "--platform", "linux/arm64", "-"}
	for _, ref := range refs {
		name, err := imageName(ref)
		if err != nil {
			return fail(400, err.Error())
		}
		args = append(args, name)
	}
	cmd := imageCommand(r.Context(), args...)
	var diag toolTail
	cmd.Stderr = &diag
	p, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err = cmd.Start(); err != nil {
		return err
	}
	var first [512]byte
	n, err := io.ReadFull(p, first[:])
	if err != nil {
		p.Close()
		_ = cmd.Wait()
		return fail(404, "image export: "+string(diag))
	}
	w.Header().Set("Content-Type", "application/x-tar")
	_, err = w.Write(first[:n])
	if err == nil {
		_, err = io.Copy(w, p)
	}
	p.Close()
	if wait := cmd.Wait(); wait != nil || err != nil {
		panic(http.ErrAbortHandler)
	}
	return nil
}
