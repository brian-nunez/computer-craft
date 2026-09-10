// Command craftnetd is the CraftNet External Application.
//
// Milestone 0 intentionally provides only a buildable composition root. Server
// behavior begins in later milestones.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/brian-nunez/computer-craft/external/internal/buildinfo"
)

func main() {
	showVersion := flag.Bool("version", false, "print version information")
	flag.Parse()

	if *showVersion {
		fmt.Printf("craftnetd %s (wire v%d)\n", buildinfo.Version, buildinfo.WireVersion)
		return
	}

	fmt.Fprintln(os.Stderr, "craftnetd: server behavior is not implemented until a later milestone")
	os.Exit(2)
}
