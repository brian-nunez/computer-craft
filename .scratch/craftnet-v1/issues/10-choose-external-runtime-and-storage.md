Type: grilling
Status: resolved
Blocked by: 03, 05, 09

## Question

Which runtime, persistence store, and deployment shape should host the External Application, credential authority, WebSocket endpoint, and administrative API given the state ownership and protocol contracts?

## Answer

The External Application is a Go application built with the supported Go 1.27 toolchain. One process hosts the Central Server WebSocket endpoint, named External Operation handlers, operator authentication and administrative HTTP interface, dashboard interface, and embedded dashboard assets on one origin. The standard `net/http`, `encoding/json`, and `embed` packages provide the server boundary and static assets; `github.com/coder/websocket` provides the RFC 6455 adapter. Explicit decoding and validation occur before domain handlers receive any HTTP or WebSocket message.

The application uses one file-backed SQLite database through Go's `database/sql` interface and the CGo-free `modernc.org/sqlite` adapter, with foreign keys enabled, WAL journal mode, explicit transactions, prepared statements, and versioned hand-written SQL migrations. The database stores Worlds, credentials and revocations, operator identity, operation policy, topology projections, administrative commands, Traffic Events, and audit history. Live Gateway Sessions, pending requests, and connection presence remain in memory.

No web framework, ORM, Redis, message broker, background-worker process, or separate telemetry database is used in v1. Store modules isolate SQL from the rest of the application so a later capacity decision can replace SQLite without changing domain or protocol handlers.

The application runs as one container or one system service with a persistent data directory containing the SQLite file. It binds to a private application port and expects the Operator's existing reverse proxy to provide a trusted HTTPS/WSS origin in deployed environments. Local development may use HTTP/WS. Configuration and the database master secret come from environment variables or mounted secret files, never source control. The dashboard is served from the same origin to avoid a separate deployment and cross-origin authentication.

Operator login uses a secure HTTP-only same-site session cookie. Device and Gateway authentication remain bearer-based at their machine interfaces. JWT signing and verification occur only in this External Application; the specific algorithms and database fields belong to the wire-schema ticket.

Go 1.27 is a supported stable release as of this decision: [Go release history](https://go.dev/doc/devel/release). The selected WebSocket adapter is small, context-aware, and uses Go's standard HTTP interfaces: [`github.com/coder/websocket`](https://pkg.go.dev/github.com/coder/websocket). The SQLite adapter implements `database/sql` without requiring CGo: [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite).
