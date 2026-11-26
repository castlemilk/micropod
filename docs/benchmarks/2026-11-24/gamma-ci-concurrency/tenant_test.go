package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestArtifactRangesUseIndependentOffsets(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	body := bytes.Repeat([]byte("micropod"), (8<<20)/8)
	mux := http.NewServeMux()
	if err := artifactRoutes(mux, "tenant-a", true); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(mux)
	defer server.Close()
	for _, mode := range []string{"file", "file-copy", "memory"} {
		change := httptest.NewRecorder()
		mux.ServeHTTP(change, httptest.NewRequest(http.MethodPost, "/artifact-mode?mode="+mode, nil))
		if change.Code != http.StatusOK || change.Body.String() != "tenant-a" {
			t.Fatalf("cannot select %s: %d %q", mode, change.Code, change.Body)
		}
		var wg sync.WaitGroup
		for _, start := range []int{0, 313, 1048571, len(body) - 65537} {
			wg.Add(1)
			go func(start int) {
				defer wg.Done()
				end := start + 65536
				req, err := http.NewRequest(http.MethodGet, server.URL+"/data", nil)
				if err != nil {
					t.Error(err)
					return
				}
				req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
				reply, err := server.Client().Do(req)
				if err != nil {
					t.Error(err)
					return
				}
				defer reply.Body.Close()
				part, err := io.ReadAll(reply.Body)
				if err != nil || reply.StatusCode != http.StatusPartialContent || !bytes.Equal(part, body[start:end+1]) {
					t.Errorf("%s returned incorrect range at %d: status %d, error %v", mode, start, reply.StatusCode, err)
				}
			}(start)
		}
		wg.Wait()
	}
}

func TestNormalTenantHasNoModeControl(t *testing.T) {
	mux := http.NewServeMux()
	if err := artifactRoutes(mux, "tenant-a", false); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/artifact-mode?mode=file", nil))
	if w.Code != http.StatusNotFound {
		t.Fatalf("unexpected control response %d", w.Code)
	}
}

func TestFrameOwnershipAndOrdering(t *testing.T) {
	const cookie = 0x12345678
	makeFrame := func(owner, seq uint64) []byte {
		b := bytes.Repeat([]byte{byte(owner + seq)}, frame)
		binary.LittleEndian.PutUint64(b, seq)
		binary.LittleEndian.PutUint64(b[8:], owner)
		return b
	}
	lastByte := makeFrame(cookie, 2)
	lastByte[len(lastByte)-1] ^= 1
	for _, tc := range []struct {
		name   string
		second []byte
		status int
	}{
		{"valid tail", makeFrame(cookie, 2), http.StatusOK},
		{"different tenant with same body pattern", makeFrame(cookie+256, 2), http.StatusUnprocessableEntity},
		{"replayed first frame", makeFrame(cookie, 1), http.StatusUnprocessableEntity},
		{"corrupted last byte", lastByte, http.StatusUnprocessableEntity},
		{"short body", makeFrame(cookie, 2)[:frame-1], http.StatusBadRequest},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := append(makeFrame(cookie, 1), tc.second...)
			req := httptest.NewRequest(http.MethodPost, "/frames", bytes.NewReader(body))
			req.ContentLength = 2 * frame
			rec := httptest.NewRecorder()
			instance := &tenant{name: "test", cookie: cookie}
			instance.frames(rec, req)
			if rec.Code != tc.status {
				t.Fatalf("received %d, want %d: %s", rec.Code, tc.status, rec.Body.String())
			}
		})
	}
}
