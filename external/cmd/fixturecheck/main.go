// Command fixturecheck validates the CraftNet protocol fixture catalog.
package main

import (
	"fmt"
	"os"

	"github.com/brian-nunez/computer-craft/external/internal/fixtures"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: fixturecheck <spec/protocol/v1>")
		os.Exit(2)
	}
	if err := fixtures.Validate(os.Args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "fixturecheck: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("protocol fixture catalog is valid")
}
