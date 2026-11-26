// Read the identity of the publishing interface from the service network namespace.
package main

import (
	"encoding/json"
	"os"
	"strings"
)

func main() {
	result := map[string]string{}
	for _, name := range []string{"ifindex", "iflink", "address"} {
		b, err := os.ReadFile("/sys/class/net/mppub0/" + name)
		if err != nil {
			panic(err)
		}
		result[name] = strings.TrimSpace(string(b))
	}
	ns, err := os.Readlink("/proc/self/ns/net")
	if err != nil {
		panic(err)
	}
	result["netns"] = ns
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
