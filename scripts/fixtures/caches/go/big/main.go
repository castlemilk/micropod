// The kill -9 test downloads this module graph; it is big enough that the
// VMM dies while `go mod download` is still writing.
package main

import (
	"fmt"

	"golang.org/x/text/language"
	"golang.org/x/tools/go/packages"
)

func main() { fmt.Println(language.English, packages.NeedName) }
