# Headless options for a repo with no JS toolchain

- **Type**: `wayfinder:research`
- **Status**: closed — 2026-09-12
- **Assignee**: research subagent, charting session
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

What are the realistic ways to exercise `dashboard.js` in CI for a repository
whose entire gate is `lua5.2`, `lua5.4`, and `go test`, with no Node, no
package manager, and no JS dependencies anywhere?

What the decision that waits on this needs to know, per option:

- What has to be installed on a CI runner, and whether `.github/workflows/ci.yml`
  can get it from `apt` or a `setup-*` action rather than a toolchain.
- Whether it can drive the **real** `craftnetd` handler — the suite already
  stands up `httptest.NewServer(application.Web.Handler())`, so anything that
  cannot point at a live URL is a poor fit.
- Whether it runs offline, given the dashboard deliberately has no external
  dependencies and declares what it may talk to.
- What it costs in wall-clock on top of a Go suite that currently takes ~10s
  for `internal/web`.
- Whether the thing it catches includes the cascade defect that motivated
  this: an author style outranking the browser's built-in `[hidden]` handling,
  which is a *computed style* question, not a DOM-shape question.

Candidates worth pricing: `chromedp`, `playwright-go`, `rod`, a headless
Firefox driven over WebDriver, and the null option — a DOM-less assertion
library that parses the CSS and JS without a browser (which is close to what
the suite does today and did not catch the bug).

## Deliverable

Findings written to `docs/wayfinder/research/headless-options.md`, linked from
this ticket. Facts and trade-offs only — the choice belongs to the ticket this
blocks.

## Blocks

[Dashboard behaviour under test](dashboard-behaviour-under-test.md)

---

## Resolution — 2026-09-12

Findings: [`research/headless-options.md`](../research/headless-options.md).

**The question's own premise was wrong, in a way that matters.** `ubuntu-latest`
already ships Chrome, ChromeDriver, Chromium, Firefox, geckodriver, Selenium —
**and Node 22**. No candidate needs an install step on CI. So "what must be
installed on the runner" does not separate anything, and the real discriminator
is **what lands in `external/go.mod`, and what a contributor needs on their own
machine**, because `make test` is the gate and it runs locally too.

**All four browser options can assert a computed style**, so all four would have
caught the cascade defect: chromedp through `ComputedStyle`, rod through
`Visible()` (which calls `getComputedStyle`), playwright-go through
`ToHaveCSS`, and WebDriver through a protocol command rather than injected
script — which is the only one that never has to reckon with the page's
`'unsafe-eval'`-free CSP. Chromium is fine regardless: CDP's `Runtime.evaluate`
defaults `allowUnsafeEvalBlockedByCSP` to true.

**The null option definitively cannot, at any price short of writing a CSS
engine.** No Go library resolves the cascade: cascadia matches selectors but
never scores specificity, douceur applies rules in source order and models no
browser stylesheet, nothing ships a UA stylesheet, and goja and otto have no
DOM. Reaching a computed value in pure Go means a specificity calculator, a
cascade sort, a browser stylesheet baseline, and DOM stubs. That is the only
option here whose cost is unbounded.

**Maintenance is the sharpest trade-off.** playwright-go is the healthiest
binding (v0.6201.1, 2026-08-17) and the only one that drags a Node runtime and
an npm-sourced driver into a repo that has neither, with a first run that is not
offline. rod is the stalest by two years (v0.116.2, 2024-07-12). chromedp is
alive but slow — four commits in six months, one maintainer. The Firefox route
pairs a browser Mozilla actively maintains with a Go client nobody has pushed
since 2025-01-28.

**Two corrections to the record.** The ~10s baseline is `-race`, not the
package: `go test ./internal/web` is 1.3s and `-race` is 10.5s, so the race
detector is what that number is made of. And `TestDashboardStylesPreserveHiddenState`
— the test in the working tree — pins that somebody typed the rule, not that the
rule wins: a later component rule with higher specificity and its own
`!important` would pass it while reintroducing the bug.

No recommendation, by design. The choice belongs to
[Dashboard behaviour under test](dashboard-behaviour-under-test.md), which is
now unblocked.
