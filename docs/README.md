# CraftNet documentation

## Start here

| You want | Read |
|---|---|
| To build a World and run it | [Setting up CraftNet](operations/setup.md) |
| To fix one that broke | [Recovering CraftNet](operations/recovery.md) |
| To understand how it works | [Architecture](architecture.md) |
| To know what a word means | [`CONTEXT.md`](../CONTEXT.md) |
| To change the code | [Contributing](contributing.md), then [`AGENTS.md`](../AGENTS.md) |
| To implement against the wire | [The CraftNet v1 wire](protocol/v1.md) and [the fixture catalog](../spec/README.md) |

## Reference

**[`protocol/v1.md`](protocol/v1.md)** — the wire, in prose: canonical JSON, the
three framings, key derivation, every message body, the Gateway, limits, and the
error catalog. [`spec/`](../spec/) is the executable version and wins any
disagreement.

**[`architecture.md`](architecture.md)** — the roles, who owns what, the effect
seam, and what a local, cross-network, and external call each do.

**[`operations/`](operations/)** — [setup](operations/setup.md) is the whole
procedure in order; [recovery](operations/recovery.md) is organised by what you
will actually see when something breaks, with every stable error code and what
to do about it.

**[`contributing.md`](contributing.md)** — the gate, the four test harnesses and
which to reach for, and how to add an External Operation or a role program.

## The packages

Every package in the `ccpm` registry has a README describing what it hides, its
public surface, and what it deliberately does not do.

| | |
|---|---|
| [`craftnet-protocol`](../packages/craftnet-protocol/README.md) | the v1 wire, in pure Lua |
| [`craftnet-core`](../packages/craftnet-core/README.md) | pure role state transitions |
| [`craftnet-runtime`](../packages/craftnet-runtime/README.md) | one configured role, running — the only package that performs I/O |
| [`craftnet-central`](../packages/craftnet-central/README.md) | the Central Server, and the World's one way out |
| [`craftnet-isp`](../packages/craftnet-isp/README.md) | an ISP |
| [`craftnet-router`](../packages/craftnet-router/README.md) | a Customer Router |
| [`craftnet-computer`](../packages/craftnet-computer/README.md) | a Computer |
| [`networking`](../packages/networking/README.md) | choosing the right modem |
| [`peripheral-discovery`](../packages/peripheral-discovery/README.md) | finding what is plugged in |

## Decisions

[`adr/`](adr/) — one accepted decision per file, in the order they were taken.
Read one before contradicting it.

| | |
|---|---|
| [0001](adr/0001-separate-world-coordination-from-isps.md) | The Central Server is world infrastructure, not an ISP |
| [0002](adr/0002-keep-network-authority-in-world.md) | Network authority stays in world |
| [0003](adr/0003-build-craftnet-on-raw-modem-channels.md) | Raw modem channels, not rednet |
| [0004](adr/0004-authenticate-modem-sessions-with-derived-keys.md) | Derived keys and replay counters |
| [0005](adr/0005-use-network-scoped-addresses-without-subnets.md) | Network-scoped addresses, no subnets |
| [0006](adr/0006-use-paired-flows-for-simplified-nat.md) | Paired flows for simplified NAT |
| [0007](adr/0007-centralize-interconnection-with-exact-route-registrations.md) | One exact route per Customer Network |
| [0008](adr/0008-use-one-semantic-gateway-session-per-world.md) | One semantic Gateway Session per World |
| [0009](adr/0009-use-a-single-go-service-with-sqlite.md) | A single Go service with SQLite |
| [0010](adr/0010-name-the-external-application-with-its-own-message-kind.md) | `external_call` names the External Application |

## History

[`implementation/`](implementation/) — one record per milestone, each stating
what it delivered **and what it did not prove**. These are dated records, not
living documentation: for how something works now, read
[Architecture](architecture.md) instead.

Milestones [0](implementation/milestone-0.md) ·
[1](implementation/milestone-1.md) · [2](implementation/milestone-2.md) ·
[3](implementation/milestone-3.md) · [4](implementation/milestone-4.md) ·
[5](implementation/milestone-5.md) · [6](implementation/milestone-6.md) ·
[7](implementation/milestone-7.md) · [8](implementation/milestone-8.md) ·
[9](implementation/milestone-9.md)

## The release gate

[`implementation/acceptance/`](implementation/acceptance/) — the checklists a
release is measured against, and
[the report](implementation/acceptance/report-v0.1.0.md) recording what is
proved and what is not. **The report is checked in incomplete on purpose:** a
gate that records what actually happened is worth more than one that waits until
it can say everything passed.

| Checklist | Covers |
|---|---|
| [milestone-4-in-world](implementation/acceptance/milestone-4-in-world.md) | a local Customer Network |
| [milestone-5-in-world](implementation/acceptance/milestone-5-in-world.md) | the internetwork |
| [milestone-7-dashboard](implementation/acceptance/milestone-7-dashboard.md) | the dashboard, in a browser |
| [milestone-8-in-world](implementation/acceptance/milestone-8-in-world.md) | all twelve scenarios, from clean Computers |

[`releases/`](releases/) — release notes, stating the tested scale as a tested
scale and the v1 exclusions as decisions rather than gaps.
