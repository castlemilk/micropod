package main

import (
	"fmt"
	"net/http"

	"github.com/go-chi/chi/v5"
)

// Deliberately different dependency set (chi) from svc-a/svc-b: its
// `go mod download` layer actually fetches, proving the matrix can tell
// shared-cache hits from genuine misses.
func main() {
	r := chi.NewRouter()
	r.Get("/", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "svc-c ok")
	})
	fmt.Println("svc-c ok")
}
