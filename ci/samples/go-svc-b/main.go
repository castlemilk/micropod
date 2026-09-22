package main

import (
	"fmt"

	"github.com/google/uuid"
)

// Same dependency set as svc-a (uuid), different code: the deps layers and
// the warm module cache are shared, only the final COPY + compile re-run.
func fingerprint(service string) string {
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("ci-demo/"+service)).String()
}

func main() {
	fmt.Println("svc-b ok", fingerprint("svc-b"))
}
