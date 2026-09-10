// Command catalogcheck validates the local ccpm registry and package manifests.
package main

import (
	"fmt"
	"os"

	"github.com/brian-nunez/computer-craft/external/internal/catalog"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: catalogcheck <repository-root>")
		os.Exit(2)
	}
	if err := catalog.Validate(os.Args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "catalogcheck: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("ccpm package catalog is valid")
}
