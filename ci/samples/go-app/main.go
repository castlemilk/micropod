package main

import (
	"fmt"
	"net/http"
)

// greeting is pure logic so unit tests cover it without any I/O.
func greeting(name string) string {
	if name == "" {
		name = "world"
	}
	return fmt.Sprintf("hello, %s", name)
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, greeting(r.URL.Query().Get("name")))
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusNoContent)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", helloHandler)
	mux.HandleFunc("/healthz", healthHandler)
	if err := http.ListenAndServe(":8080", mux); err != nil {
		panic(err)
	}
}
