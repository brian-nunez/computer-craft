# Milestone 8 — Hardening, scale, and v1 release

Status: **the automated half is complete; the gate is not met.** Everything
below that could be proved without Minecraft has been. The in-world run has not
happened, and one acceptance scenario is blocked on work that is not built. See
[the acceptance report](acceptance/report-v0.1.0.md).

This milestone is not about new behaviour. It is about finding out whether what
already exists actually holds up — at scale, under damage, and after a restart —
and about making it something a second person can operate from documentation
alone.

## Delivered

### Scale and load

`tests/lua/scale_test.lua` stands up the verification design's scale fixture —
four ISPs, twenty Customer Routers each, twenty Computers each, **1,685
entities** — entirely through real state transitions. Nothing is written into an
engine by hand: every allocation, route, binding, and address was decided by
`craftnet-core`.

Against it:

- **10,000 seeded mixed operations.** Every reply reaches exactly the Computer
  that asked, from exactly the Computer that was addressed, carrying that
  request's own token — with half the destinations addressed by an RFC 1918
  address that twenty other networks also hold.
- **Disjoint Provider Allocations** per ISP, and the **identical RFC 1918 pool**
  reused by all eighty Customer Networks.
- **A full topology snapshot** that stays inside the 2,000-entity wire limit and
  validates as a `topology_snapshot`.
- **1,000 mixed requests** on the reference topology: one terminal result each,
  no reply anywhere else, and a canary that exists only inside a payload
  searched for in every field of every Traffic Event.
- **Nothing left behind.** Past the 30-second idle limit, no role holds a NAT
  Flow or a correlation record.

### The restart matrix

`tests/lua/restart_matrix_test.lua` is scenario 12. Each role is torn down and
rebuilt from nothing but its own snapshot — no state handed across in memory —
and then the World has to still work: Home to Farm, around the Central Server,
and back to the Computer that asked.

It covers a Computer, each Customer Router, the ISP, the Central Server, and all
of them at once, top down. What must survive does; what must not, does not.

The shared World builder moved to `tests/lua/support/world.lua`, so the
internetwork scenarios and the restart matrix stand up the same World rather
than two that drift.

### The malformed input corpus

`tests/lua/malformed_corpus_test.lua` is broader and less precise than the
fixture catalog on purpose. The catalog proves specific bad inputs are
classified identically in Lua and Go. This proves that a systematic sweep —
every truncation of a valid frame, a byte flipped at every position, deep
nesting, oversized strings and objects and arrays, every required field removed
from every message kind, every field given seven kinds of wrong value, and
twenty-nine damaged engine inputs against every role — always produces a stable
catalog error, never a crash, and never a durable change.

`external/internal/web/hardening_test.go` does the same to the Gateway, and adds
the stronger claim: a live session takes the whole corpus and is still there
afterwards, still authenticated, still able to do its job. One bad frame is not
a reason to lose a World.

### Operator tooling that was missing

The gate says a second Operator must be able to follow the documentation without
editing source. Writing the documentation found three commands that did not
exist:

| Command | What it does |
|---|---|
| `expose` | Publish or withdraw a Computer's service, by hostname; on its own, list what is published |
| `revoke` | Take a Computer off a Customer Network, destroying its credential and freeing its address; on its own, list who is on the network |
| `craftnet` | The Computer's own command line: `status`, `resolve NAME`, `call NAME SERVICE` |

`tests/lua/role_programs_test.lua` holds every one of the fourteen documented
programs to the same bar: it compiles, it reaches for no global CC:Tweaked does
not provide, it says something actionable when it cannot start, and it never
prints or unmasks a secret.

### Documentation

- **[Setting up CraftNet](../operations/setup.md)** — the whole procedure from
  nothing to a working World, ending in a table of every command an Operator can
  type.
- **[Recovering CraftNet](../operations/recovery.md)** — organised by what you
  will actually see, with every stable error code and what to do about it.
- **[The in-world checklist](acceptance/milestone-8-in-world.md)** — all twelve
  scenarios, from clean Computers and a clean data directory.
- **[The acceptance report](acceptance/report-v0.1.0.md)** — the automated half
  filled in, the rest marked as what it is.
- **[Release notes](../releases/v0.1.0.md)** — including the tested scale stated
  as a tested scale, and the v1 exclusions as decisions rather than gaps.

### Release machinery

`scripts/build-release.sh` builds one CGo-free binary per platform, each stamped
with the version it claims to be, plus a SHA-256 manifest covering all of them.
`buildinfo.Version` became a `var` so a release build can stamp it — and so a
binary built any other way reports `0.1.0-dev` rather than claiming to be a
release nobody cut.

## Defects this milestone found

Both were found by tests written for the gate, and both have a regression test
that fails without the fix.

**A restarted role could never reconnect to a parent that had not restarted.**
Found by the restart matrix. A role bumped its session generation in memory but
never wrote it down, so a restart began counting from one again. Its parent had
already seen that nonce and refused the repeat as a replay — correctly — and the
child sat there unable to reconnect, with no error that pointed at why. The
counter is durable now, in all three roles that hold one.

This is the kind of defect that only a restart matrix finds: every individual
role's restart test passed, because each of them restarted the parent too.

**Correlated requests were unbounded per relationship.** The protocol's Link
refused work past 64 in flight, but the role engines opened correlation records
and NAT Flows with no bound at all — so the refusal happened at the wire while
the memory accumulated underneath it. Every role now refuses the 65th with
`busy`, at the layer where the memory would actually have grown, and the bound
comes from the protocol so a role and a link cannot disagree about it.

## Gate evidence

`make fmt-check` and `make test`: **253 Lua tests, 0 failures**, and the Go suite
under `-race` at two seeds. The full threshold-by-threshold table is in [the
acceptance report](acceptance/report-v0.1.0.md).

## What is not met, and why

**The in-world Gateway transport does not exist**, so acceptance scenario 8 is
blocked and scenarios 9 and 10 are two halves that meet at a defined seam rather
than one path. This is [Milestone 6's open
question](milestone-6.md#deliberately-deferred) still open: how a Computer names
an External Operation on the in-world wire is a protocol decision the tickets do
not settle, and the transport belongs with it. Improvising one at a release gate
would be the worst possible moment to decide it.

> Both were done in [Milestone 9](milestone-9.md), which exists for exactly
> this reason. Scenario 8 is no longer blocked.

**No in-world run has been performed**, so the twelve scenarios stand unrun in
the target stack, as do the Milestone 4, 5, and 7 checklists.

**No second Operator has followed the documentation.** The commands it names all
exist and are held to a standard by a test, but nobody has built a World from
the guide alone.

None of that is a reason to stop; it is a reason not to tag. The repository
stays at `0.1.0-dev`, and every binary it builds says so.
