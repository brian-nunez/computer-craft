# Dashboard behaviour under test

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing — [Headless options for a repo with no JS toolchain](headless-options-without-a-js-toolchain.md) closed 2026-09-12
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

`dashboard.js` is 597 lines with no execution-level test. The suite asserts
substrings in the served CSS and HTML and nothing more, which is why a cascade
defect — an author style outranking the browser's handling of `[hidden]` — took
a browser and a person to find.

The fix that landed pins that one string:

```go
if !strings.Contains(styles, "[hidden]") || !strings.Contains(styles, "display: none !important") {
```

That closes the instance — and less of it than it looks. The research found that
this assertion proves somebody *typed* the rule, not that the rule *wins*: a
later component rule with higher specificity and its own `!important` passes
this test while reintroducing the same defect.

The question is whether to close the class.

Three answers, all defensible:

1. **Automate it.** Take one of the four browser options and make the
   dashboard's behaviour part of `make test`. All four can assert a computed
   style, so all four would have caught this; they separate on what enters
   `external/go.mod` and what a contributor needs locally.
2. **Rule it out of scope for v0.1.0** and lean on
   [the browser checklist](../../implementation/acceptance/milestone-7-dashboard.md),
   stating plainly in the release notes that dashboard behaviour is proved by
   hand. Honest, and consistent with a project that records what it did not
   prove.
3. **Neither — reduce the surface.** If the behaviour worth testing is small
   enough, move it to where the Go suite already reaches and leave the browser
   holding only what a browser must.

## What the research settled

Read [`research/headless-options.md`](../research/headless-options.md) before
deciding; the summary is in
[the research ticket's resolution](headless-options-without-a-js-toolchain.md#resolution--2026-09-12).
Three things it changes about this ticket:

- **CI cost is not the trade-off.** `ubuntu-latest` already ships every browser
  *and* Node 22, so no option needs an install step. What separates them is what
  lands in `external/go.mod` and what a contributor must have locally, because
  `make test` is the gate and it runs on both.
- **The null option is out on the merits, not on taste.** No Go library resolves
  the CSS cascade. Reaching a computed value in pure Go means writing a
  specificity calculator, a cascade sort, and a browser stylesheet baseline —
  the only unbounded cost on the page.
- **Health, not capability, is the live question.** playwright-go is the
  healthiest and the only one that puts a Node runtime into a repo that has
  none; chromedp is pure Go and offline but has one maintainer; rod is two years
  stale; the Firefox route is a live protocol behind a dormant Go client.

If the answer is (2), close this ticket by ruling it out of scope on the map
rather than by resolving it on the route.

## Evidence

- `external/internal/web/assets/dashboard.js` — 597 lines, no execution test
- `external/internal/web/dashboard_test.go` — `TestTheDashboardIsServedFromTheBinary`,
  `TestDashboardStylesPreserveHiddenState`, and the rest: substring assertions
- `external/internal/web/assets/dashboard.css` — the `[hidden]` rule that was added
- `.github/workflows/ci.yml` — the gate as it stands

## Also answer

Does this block the v0.1.0 tag?
