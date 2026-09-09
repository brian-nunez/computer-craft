Type: grilling
Status: resolved
Blocked by: 03, 05, 09

## Question

Which runtime, persistence store, and deployment shape should host the External Application, credential authority, WebSocket endpoint, and administrative API given the state ownership and protocol contracts?

## Answer

The External Application is a TypeScript application running on Node.js 24 LTS. One Fastify process hosts the Central Server WebSocket endpoint, named External Operation handlers, operator authentication and administrative API, dashboard API, and compiled dashboard assets on one origin. `@fastify/websocket` provides WebSocket integration, and Fastify JSON Schema validates all HTTP and WebSocket boundary messages before domain handlers receive them.

The application uses one file-backed SQLite database through `better-sqlite3`, with foreign keys enabled, WAL journal mode, explicit transactions, prepared statements, and versioned hand-written SQL migrations. The database stores Worlds, credentials and revocations, operator identity, API policy, topology projections, administrative commands, Traffic Events, and audit history. Live Gateway Sessions, pending requests, and connection presence remain in memory.

No ORM, Redis, message broker, background-worker service, or separate telemetry database is used in v1. Repository functions isolate SQL from the rest of the application so a later capacity decision can replace SQLite without changing domain or protocol handlers. Traffic retention and capacity limits will be decided by the recovery and operations tickets.

The application runs as one container or one system service with a persistent data directory containing the SQLite file. It binds to a private application port and expects the Operator's existing reverse proxy to provide a trusted HTTPS/WSS origin in deployed environments. Local development may use HTTP/WS. Configuration and the database master secret come from environment variables or mounted secret files, never source control. The dashboard is served from the same origin to avoid a separate deployment and cross-origin authentication.

Operator login uses a secure HTTP-only same-site session cookie. Device and Gateway authentication remain bearer-based at their machine interfaces. JWT signing and verification occur only in this External Application; the specific algorithms and database fields belong to the wire-schema ticket.

Node.js 24 is an active LTS line as of this decision: [Node.js release schedule](https://nodejs.org/en/about/previous-releases). Fastify supplies TypeScript, validation, serialization, lifecycle, and plugin boundaries, with WebSocket support in its ecosystem: [Fastify reference](https://fastify.dev/docs/latest/Reference/), [Fastify ecosystem](https://fastify.dev/docs/latest/Guides/Ecosystem/). Node's built-in `node:sqlite` remains release-candidate stability, so v1 selects the established `better-sqlite3` API instead: [`node:sqlite` status](https://nodejs.org/api/sqlite.html), [`better-sqlite3`](https://github.com/WiseLibs/better-sqlite3).
