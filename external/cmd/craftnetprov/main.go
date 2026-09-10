// Command craftnetprov generates a development World Key and Gateway
// Credential bundle.
//
// Initial Central Server provisioning requires the External Application; later
// in-world enrollment does not. Running this command is what lets Milestones 1
// through 5 be exercised without a running server and without any CraftOS role
// inventing a root secret or reusing a checked-in fixture credential.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/brian-nunez/computer-craft/external/internal/provisioning"
)

func main() {
	out := flag.String("out", "", "path to write the bundle to (required)")
	worldID := flag.String("world-id", "", "World identity (default world-development)")
	centralID := flag.String("central-id", "", "Central Server identity (default central-development)")
	gatewayURL := flag.String("gateway-url", "", "Gateway WebSocket URL (default wss://localhost:8443/gateway)")
	credentialRef := flag.String("gateway-credential-ref", "", "Gateway Credential reference (default gwc-development)")
	flag.Parse()

	if *out == "" {
		fmt.Fprintln(os.Stderr, "craftnetprov: -out is required")
		flag.Usage()
		os.Exit(2)
	}

	bundle, err := provisioning.New(provisioning.Options{
		WorldID:              *worldID,
		CentralID:            *centralID,
		GatewayURL:           *gatewayURL,
		GatewayCredentialRef: *credentialRef,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "craftnetprov: %v\n", err)
		os.Exit(1)
	}
	if err := bundle.Write(*out); err != nil {
		fmt.Fprintf(os.Stderr, "craftnetprov: %v\n", err)
		os.Exit(1)
	}

	// Secret values are never printed. The fingerprint is enough to confirm which
	// bundle a Central Server is running against.
	fmt.Printf("wrote %s\n", *out)
	fmt.Printf("  world_id     %s\n", bundle.WorldID)
	fmt.Printf("  central_id   %s\n", bundle.CentralID)
	fmt.Printf("  gateway_url  %s\n", bundle.GatewayURL)
	fmt.Printf("  fingerprint  %s\n", bundle.Fingerprint())
	fmt.Println("Keep this file out of the repository: it is the root of every credential in the World.")
}
