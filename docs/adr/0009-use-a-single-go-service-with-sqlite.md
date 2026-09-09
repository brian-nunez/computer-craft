# Use a single Go service with SQLite

The External Application runs as one Go service that hosts its WebSocket, HTTP interfaces, authentication, and embedded dashboard from one origin, with durable state in SQLite through `database/sql` and a CGo-free adapter. This minimizes deployment and operational complexity for one Minecraft world while explicit protocol validation, store seams, and hand-written migrations preserve a path to split processes or replace storage if measured capacity later requires it.
