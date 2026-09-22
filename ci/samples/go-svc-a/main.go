package main

import (
	"fmt"

	"github.com/google/uuid"
)

// fingerprint is deterministic per service name: a v5 UUID (SHA-1), so the
// built image prints a stable, service-specific line for run-assertions.
func fingerprint(service string) string {
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte("ci-demo/"+service)).String()
}

func main() {
	fmt.Println("svc-a ok", fingerprint("svc-a"))
}
