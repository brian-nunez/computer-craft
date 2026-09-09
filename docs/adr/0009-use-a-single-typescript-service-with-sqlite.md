# Use a single TypeScript service with SQLite

The External Application runs as one Node.js 24 LTS TypeScript/Fastify service that hosts its WebSocket, HTTP APIs, authentication, and dashboard from one origin, with durable state in SQLite through `better-sqlite3`. This minimizes deployment and operational complexity for one Minecraft world while schema validation, repository boundaries, and explicit migrations preserve a path to split services or replace storage if measured capacity later requires it.
