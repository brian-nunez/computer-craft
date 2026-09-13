# Finish the container and document it

- **Type**: `wayfinder:task`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: [Deployment posture for v0.1.0](deployment-posture.md)
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## What is wrong

The uncommitted `compose.yaml` and `external/Dockerfile` are careful in most
respects — non-root, `read_only`, `no-new-privileges`, resource limits, a
health check — and unfinished in three that an Operator meets immediately.

**A fresh clone cannot start it.** `data/` is gitignored, so on a clean
checkout Docker creates the `./data:/data` bind mount root-owned and the
`craftnet` user cannot write `craftnet.db`. It works on the machine it was
built on only because `data/` already exists there owned by `100:101` — the
container user's ids, leaked onto the host:

```
$ stat -c '%u:%g %n' data
100:101 data
```

**The image cannot say what it is.** `scripts/build-release.sh:49` stamps
`-X …/buildinfo.Version=$version`; the Dockerfile does not, so every image
reports `0.1.0-dev` however it was built, and `craftnetd version` — a command
the setup guide documents — cannot be trusted from a container.

**Nothing tells an Operator it exists.** `setup.md` never mentions
`docker compose up`, nor that `provision` and `operator` become
`docker compose exec`. The guide's own promise is *"You should not have to read
any source code, and if you do, that is a defect in this document"*, and gate
item 4 is a second Operator building a World from it alone.

## Carry the fix

Three approaches to the ownership problem, and the choice is small enough to
make while fixing rather than to decide first: a named volume, an entrypoint
that fixes ownership before dropping privileges, or `user:` pinned to the host
uid. Weigh them against `setup.md`'s documented `data/craftnet.db` default —
a named volume moves the file somewhere the recovery guide does not describe.

Then: stamp the version through a build arg, and give `setup.md` the container
path, including `docker compose exec` for the two commands that are not
`serve`. The binding and any TLS follow from
[Deployment posture](deployment-posture.md) — which is why that blocks this.

## Evidence

- `compose.yaml`, `external/Dockerfile`, `external/.dockerignore` — all uncommitted
- `scripts/build-release.sh:49` — the ldflags the Dockerfile omits
- `docs/operations/setup.md` — step 1, the command table, and "Where things are"
- `docs/operations/recovery.md` — describes the database by its documented path
