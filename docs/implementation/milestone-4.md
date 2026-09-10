# Milestone 4 — Local Customer Network vertical slice

Status: **simulator half complete on 2026-09-09. The in-world half has not been
run** — see [Gate evidence](#gate-evidence) below.

Milestone 4 is the first milestone with something an Operator can actually use.
`craftnet-router` and `craftnet-computer` are composition roots over the three
shared packages: a setup wizard, a LAN, a password, a join, and the traffic that
follows. Nothing crosses a Customer Network boundary yet; that is Milestone 5.

## Delivered

### `craftnet-router`

| Module | Owns |
|---|---|
| `router` | The composition root: runtime, links, listener, and the durable record of who joined |
| `lan` | Discovery, the LAN Password challenge-response, the session responder, and the credential a join produces |
| `wizard` | The setup questions and their rules, apart from the terminal that asks them |
| `bootstrap` | Finding the installed packages through the `ccpm` lock file |
| `setup` / `startup` | The two programs an Operator runs |

### `craftnet-computer`

| Module | Owns |
|---|---|
| `computer` | The composition root: join once, reconnect with the credential from then on |
| `join` | Discovery, the enrollment exchange, and the reconnect handshake |
| `bootstrap`, `setup`, `startup` | As above |

### Additions to the shared packages

- **`craftnet-runtime/links`** — the session-carrying links adapter, split out of
  the modem adapter so it works over any transport. `adapter_modem` is now just
  a modem: open a channel, move bytes.
- **`craftnet-runtime/secrets`** — a durable credential store kept in its own
  file. Ticket 16 says snapshots never contain secret values, and now that
  routers hold a LAN Credential per Computer, that has to be structural rather
  than incidental.
- **`craftnet-core`** — LAN admission rate limiting on the router, per claimed
  identity and again across the whole LAN.
- **`craftnet-protocol`** — `discovery` and `handshake` framing made public. A
  role package has to put those on the wire itself, before any session exists.

## Gate evidence

### Automated — complete

The Lua suite runs 190 tests, green on Lua 5.2, 5.4, 5.5, and LuaJIT.

`tests/lua/role_lan_test.lua` runs the code that ships: the real role packages,
runtime, links adapter, protocol, and engines. Only the modem is imaginary, and
`tests/lua/support/lanworld.lua` makes even that faithful — a shared air that
delivers to whoever has the channel open, with each node in a coroutine, which
is how CC:Tweaked handles the same problem.

| Gate requirement | Evidence |
|---|---|
| Four Computers join through passwords | `role_lan_test.lua` — `.20`, `.21`, `.22`, `.23`, lowest free each time |
| Wrong passwords fail | the join is refused, no Address Binding is created, and the Computer does not believe it joined |
| Repeated guessing is rate limited | per-identity and a shared sweep limit, refused with the same code a wrong password gives |
| Both networks allocate `.20` and `.21` | Home and Farm built separately on the identical pool |
| Local names resolve | `wall-display`, unknown names, and `api.craft` |
| Local requests never leave their router | no NAT Flow is created and the router records `delivered_local` |
| Restart does not change identity or address | a Computer returns from its own snapshot with both intact, and reconnects with its credential rather than the password |
| `ccpm` brings all dependencies into the lock file | `ccpm_install_test.lua` |

The `ccpm` test runs the real `ccpm.lua` inside a fake CraftOS whose HTTP serves
this repository's own registry and manifests, then **writes the install to a
real disk and loads it**. That last step matters: reading bytes out of a table
would only prove they arrived, while running them proves each manifest listed
every file its package needs. It caught a gap the first time it ran.

### In-world — not run

The gate also asks for "a small in-world wired or wireless LAN". I have no
Minecraft here, so that half is **unverified**. It is written up as a runnable
checklist at
[`acceptance/milestone-4-in-world.md`](acceptance/milestone-4-in-world.md),
covering the wizards, four joins, a wrong password, the rate limit, restart,
name resolution, local traffic, and two networks sharing a pool.

Until that is run, treat the following as untested: the modem transport, the
`fs`, `term`, and clock adapters, `ccpm` over real HTTP, and the two wizards as
an Operator types into them. Everything above those seams is covered.

- [ ] In-world acceptance run completed

## Decisions made inside this milestone

- **A Computer's identity is derived from its hostname.** `enroll_open` carries
  `client_id` only when re-enrolling, so a router has to name a first-time
  joiner. It uses `<customer_network_id>-<hostname>`, which is unique within the
  network because hostnames are, and which reads the same in a snapshot as on a
  screen. It does not follow a later rename: an identity is not a name.
- **The LAN Password is the enrollment secret directly.** Ticket 16 says the
  proof uses "the one-time ISP/Router enrollment token or LAN Password". The
  derived-secret machinery is for a parent issuing tokens from its own root
  secret, which is the ISP and Central case, not this one. The durable counter
  still does its job: it feeds the router's nonce, which is where ticket 16
  places the uniqueness guarantee.
- **Rate limiting is counted twice.** Per claimed identity, so a misconfigured
  Computer throttles only itself; and across the whole LAN, because an attacker
  rotating identities would otherwise walk past a per-identity limit. A blocked
  caller gets the same code a wrong password gives, so nothing is learned from
  being throttled, and the block lifts so a mistyped password cannot lock a
  Computer out of its own network.
- **Secrets moved out of the state snapshot.** Ticket 16 says snapshots never
  contain secret values. With routers now holding a credential per Computer,
  state carries a reference and the secret store carries the value — which keeps
  the Milestone 3 assertion that a snapshot contains no credential true rather
  than vacuous.
- **The links adapter's handshake handler reports, it does not feed the
  engine.** An enrollment step is not a CraftNet input. Whatever an exchange
  establishes reaches the engine through the same queued `link_up` every other
  relationship uses.
- **Wizard questions are separated from the terminal.** What an Operator is
  allowed to type is checked against the engine's own rules, and against the
  engine itself: one test feeds the wizard's output straight into `configure`.

## Deliberately deferred

- Cross-network traffic needs an ISP and the Central Server. The engine already
  routes it; there is nothing above it to carry it until Milestone 5.
- `craftnet-computer` has no Access Token or External Operation helpers yet.
  They have nothing to talk to until the Go application exists in Milestone 6.
- Revocation is implemented on the router (`Router:revoke`) but has no operator
  program in front of it.

Milestone 5 is the next implementation gate: `craftnet-isp` and
`craftnet-central`, enrollment upward, Provider Allocations, Route
Registrations, and the first traffic between two Customer Networks.
