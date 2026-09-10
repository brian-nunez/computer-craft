// Command craftnetd is the CraftNet External Application.
//
// One process serves the Central Server's Gateway, the operator HTTP interface,
// and (from Milestone 7) the embedded dashboard, on one origin and out of one
// SQLite file.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/app"
	"github.com/brian-nunez/computer-craft/external/internal/buildinfo"
	"github.com/brian-nunez/computer-craft/external/internal/store/sqlite"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "serve":
			os.Exit(serve(os.Args[2:]))
		case "provision":
			os.Exit(provision(os.Args[2:]))
		case "version":
			fmt.Printf("craftnetd %s (wire v%d, schema v%d)\n",
				buildinfo.Version, buildinfo.WireVersion, sqlite.SchemaVersion)
			return
		}
	}
	usage()
	os.Exit(2)
}

func usage() {
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  craftnetd serve      [-database PATH] [-listen ADDR]")
	fmt.Fprintln(os.Stderr, "  craftnetd provision  -world ID -central ID [-database PATH] [-gateway-url URL]")
	fmt.Fprintln(os.Stderr, "  craftnetd version")
}

// open connects to the database and migrates it forward.
func open(ctx context.Context, path string) (*sqlite.Store, error) {
	if directory := filepath.Dir(path); directory != "" && directory != "." {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, fmt.Errorf("create the data directory: %w", err)
		}
	}
	return sqlite.Open(ctx, path)
}

//--------------------------------------------------------------------------
// serve
//--------------------------------------------------------------------------

func serve(arguments []string) int {
	flags := flag.NewFlagSet("serve", flag.ExitOnError)
	database := flags.String("database", "data/craftnet.db", "SQLite database path")
	listen := flags.String("listen", "127.0.0.1:8080", "address to listen on")
	retention := flags.Duration("retention", 30*24*time.Hour, "how long Traffic Events are kept")
	_ = flags.Parse(arguments)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	backing, err := open(ctx, *database)
	if err != nil {
		log.Printf("craftnetd: %v", err)
		return 1
	}
	defer backing.Close()

	application, err := app.New(app.Options{
		Store: backing, Retention: *retention, Logf: log.Printf,
	})
	if err != nil {
		log.Printf("craftnetd: %v", err)
		return 1
	}

	go application.PruneDaily(ctx, 24*time.Hour, log.Printf)

	server := &http.Server{
		Addr:    *listen,
		Handler: application.Web.Handler(),
		// A Gateway Session is long-lived, so there is deliberately no read
		// timeout on the whole connection; the header timeout still bounds how
		// long an unauthenticated caller can hold a slot.
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdown)
	}()

	log.Printf("craftnetd %s listening on %s (%s)", buildinfo.Version, *listen, application.Describe())
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("craftnetd: %v", err)
		return 1
	}
	log.Printf("craftnetd: stopped")
	return 0
}

//--------------------------------------------------------------------------
// provision
//--------------------------------------------------------------------------

// provision creates a World and prints the bundle exactly once. Afterwards the
// application holds only digests and cannot produce it again, which is why the
// output says to write it down.
func provision(arguments []string) int {
	flags := flag.NewFlagSet("provision", flag.ExitOnError)
	database := flags.String("database", "data/craftnet.db", "SQLite database path")
	worldID := flags.String("world", "", "World identity (required)")
	centralID := flags.String("central", "", "Central Server identity (required)")
	gatewayURL := flags.String("gateway-url", "ws://127.0.0.1:8080/gateway", "Gateway URL for the Central Server")
	_ = flags.Parse(arguments)

	if *worldID == "" || *centralID == "" {
		fmt.Fprintln(os.Stderr, "craftnetd: -world and -central are required")
		return 2
	}

	ctx := context.Background()
	backing, err := open(ctx, *database)
	if err != nil {
		fmt.Fprintf(os.Stderr, "craftnetd: %v\n", err)
		return 1
	}
	defer backing.Close()

	application, err := app.New(app.Options{Store: backing})
	if err != nil {
		fmt.Fprintf(os.Stderr, "craftnetd: %v\n", err)
		return 1
	}

	bundle, err := application.Identities.ProvisionWorld(ctx, backing, *worldID, *centralID, *gatewayURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "craftnetd: %v\n", err)
		return 1
	}

	fmt.Println("Provisioned " + bundle.WorldID)
	fmt.Println()
	fmt.Println("Type these into the Central Server's setup wizard:")
	fmt.Println()
	fmt.Println("  World identity            " + bundle.WorldID)
	fmt.Println("  Central Server identity   " + bundle.CentralID)
	fmt.Println("  External Application URL  " + bundle.GatewayURL)
	fmt.Println("  World Key                 " + bundle.WorldKey)
	fmt.Println("  Gateway Credential        " + bundle.GatewayCredential)
	fmt.Println()
	fmt.Println("This is the only time they are shown. The application keeps only")
	fmt.Println("digests, and cannot print them again.")
	return 0
}
