# Map — the software half of the v0.1.0 gate

Label: `wayfinder:map`

## Destination

Every gap found in the software has a **recorded decision**: closed, deferred
with its reason, or ruled out of this release. Reaching the end of this map does
not mean every fix is merged. It means nobody has to guess what CraftNet intends
to do about any of them, and
[the acceptance report](../implementation/acceptance/report-v0.1.0.md) can state
the software half of the gate without a blank in it.

The twelve manual acceptance runs are a separate effort. See **Out of scope**.

## Notes

**Domain.** CraftNet. [`CONTEXT.md`](../../CONTEXT.md) is the vocabulary — use
those words in tickets, resolutions, and commits. [`AGENTS.md`](../../AGENTS.md)
is the house convention, including the rules with teeth that three of these
tickets exist because the code breaks.

**Skills.** Call `grilling` and `domain-modeling` by default. A ticket that
touches a message kind, a limit, or an error code reads
[`docs/protocol/v1.md`](../protocol/v1.md) and [`spec/README.md`](../../spec/README.md)
first — both languages and the fixtures change together, and a wire constant
changes by ADR rather than because an implementation found one inconvenient.

**This effort carries execution where there is nothing to decide.** That is a
deliberate override of the planning default:

- `wayfinder:grilling` stops at the decision and records it. The fix, if there
  is one, is somebody else's session.
- `wayfinder:task` carries its own fix and is resolved when it is merged with
  the regression test that fails without it.
- `wayfinder:research` is resolved by a subagent and blocks the decision that
  waits on it.

**Every decision ticket answers two questions**, not one: what CraftNet should
do, and whether it blocks the v0.1.0 tag. The second is what
[`fold-the-decisions-into-the-release-gate`](tickets/fold-the-decisions-into-the-release-gate.md)
collects.

**The gate is `make fmt-check` and `make test`.** Both, before a ticket closes.

**Finding the frontier.** This tracker is a folder, so it has no UI to render
blocking. The frontier is every ticket that is open, unclaimed, and has nothing
open blocking it:

```bash
grep -L 'Status: closed' docs/wayfinder/tickets/*.md | xargs grep -l 'Assignee: unclaimed'
```

Then read each one's **Blocked by** line and drop any whose blocker is still
open. Claim a ticket by writing your name into `Assignee:` **before** starting
work — that is the claim, and it is what stops two sessions colliding.

## Decisions so far

<!-- One line per closed ticket: the gist, then the link for the detail the
     ticket holds. A decision lives in its ticket and is never restated here. -->

- [Headless options for a repo with no JS toolchain](tickets/headless-options-without-a-js-toolchain.md):
  every browser option can assert a computed style and so would have caught the
  cascade defect; the null option cannot at any bounded price. CI install cost
  turns out not to separate them — `ubuntu-latest` ships every browser and Node
  22 — so the trade-off is what enters `external/go.mod` and what a contributor
  needs locally. Prices in [`research/headless-options.md`](research/headless-options.md).

## Not yet specified

**Whether the wire stays at v1.** Three open tickets could each want a wire
change — a new error code for a service that cannot answer, a credential kind
the frame carries rather than infers from a name, and a second `admin_command`
action for revocation. Nothing has been released, so v1 can still be edited in
place rather than succeeded. But if two or more land, whether that is one ADR or
three, and whether the fixture catalog regenerates once or repeatedly, is not
sharp enough to ticket. Revisit once
[`credential-rule-for-new-operations`](tickets/credential-rule-for-new-operations.md),
[`answering-a-service-that-cannot`](tickets/answering-a-service-that-cannot.md),
and [`where-revocation-lives`](tickets/where-revocation-lives.md) have answers.

**How a concurrent Gateway Session would be proved.** If
[`gateway-session-concurrency`](tickets/gateway-session-concurrency.md) decides
the session stops handling External Operations inline, the Go suite's `-race`
at two seeds is no longer obviously enough: ordering between an
`external_response` and a `topology_snapshot` becomes observable, and nothing
currently asserts it. What that test looks like depends on which shape wins.

**Whether any of this changes the tested-scale claims.** The release notes state
a tested scale as a tested scale. If the Gateway Session's concurrency model
changes, the 256-in-flight number may mean something different than it did when
`scale_test.lua` measured it. Revisit after the concurrency decision.

## Out of scope

Ruled beyond this map's destination. These stay on the release gate; they are
just not what this effort is finding its way to.

- **The twelve in-world acceptance scenarios** —
  [the checklist](../implementation/acceptance/milestone-8-in-world.md). Needs
  Minecraft, Ender modems, and a person. Fenced out at charting.
- **The dashboard browser checklist** —
  [milestone 7](../implementation/acceptance/milestone-7-dashboard.md). Needs a
  browser and a pair of eyes. Note that
  [`dashboard-behaviour-under-test`](tickets/dashboard-behaviour-under-test.md)
  is *in* scope: that ticket asks whether the class of defect should be
  automated, not whether this particular run happens.
- **A second Operator building a World from the setup guide alone** — gate item
  4. Needs a second Operator.
