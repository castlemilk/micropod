package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// Exposing just Read and Seek keeps ServeContent's range handling but makes
// the regular-file control read through userspace.
type userCopyFile struct{ io.ReadSeeker }

func artifactRoutes(mux *http.ServeMux, marker string, experiment bool) error {
	body := sync.OnceValue(func() []byte { return bytes.Repeat([]byte("micropod"), (8<<20)/8) })
	var mode atomic.Uint32
	var path string
	if experiment {
		f, err := os.CreateTemp("", "micropod-artifact-")
		if err != nil {
			return err
		}
		path = f.Name()
		_, writeErr := f.Write(body())
		closeErr := f.Close()
		if writeErr != nil {
			return writeErr
		}
		if closeErr != nil {
			return closeErr
		}
		mux.HandleFunc("POST /artifact-mode", func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Query().Get("mode") {
			case "memory":
				mode.Store(0)
			case "file-copy":
				mode.Store(1)
			case "file":
				mode.Store(2)
			default:
				http.Error(w, "unknown artifact mode", http.StatusBadRequest)
				return
			}
			fmt.Fprint(w, marker)
		})
		mux.HandleFunc("GET /artifact-mode", func(w http.ResponseWriter, _ *http.Request) {
			names := [...]string{"memory", "file-copy", "file"}
			fmt.Fprintf(w, "%s\t%s", marker, names[mode.Load()])
		})
	}
	mux.HandleFunc("GET /data", func(w http.ResponseWriter, r *http.Request) {
		selected := mode.Load()
		if selected == 0 {
			http.ServeContent(w, r, "data", time.Time{}, bytes.NewReader(body()))
			return
		}
		// Each connection gets its own offset, including simultaneous range requests.
		f, err := os.Open(path)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer f.Close()
		var content io.ReadSeeker = f
		if selected == 1 {
			content = userCopyFile{f}
		}
		http.ServeContent(w, r, "data", time.Time{}, content)
	})
	return nil
}
