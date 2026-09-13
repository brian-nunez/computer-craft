# Headless options for a repo with no JS toolchain

What each candidate costs if the dashboard's behaviour becomes part of `make
test`. Written for
[`dashboard-behaviour-under-test`](../tickets/dashboard-behaviour-under-test.md),
which decides whether to spend any of it; this file only prices the options.
Resolves [`headless-options-without-a-js-toolchain`](../tickets/headless-options-without-a-js-toolchain.md).

Everything below was checked against project sources on 2026-09-12. Where no
primary source publishes a number, this says so rather than inventing one.

## What the gate looks like today

`.github/workflows/ci.yml` installs `lua5.2` and `lua5.4` from `apt`, takes Go
from `actions/setup-go@v7`, and runs `scripts/test-all.sh`. There is no Node
step and no package manager. `scripts/test-go.sh` runs `go test -race ./...`,
and on this machine `go test -race ./internal/web` takes **10.5s** against
**1.3s** without `-race` — so the `-race` requirement, not the browser, is what
the ~10s baseline is made of.

Two facts change the shape of this question, and both are easy to get wrong:

**The runner already has every browser.** `ubuntu-latest` currently maps to
Ubuntu 24.04, and that image ships Google Chrome 152.0.7977.82, ChromeDriver
152.0.7977.82, Chromium 152.0.7977.0, Firefox 155.0, Geckodriver 0.37.1,
Selenium server 4.48.0 — **and Node.js 22.23.2**
([runner-images README](https://github.com/actions/runner-images),
[Ubuntu 24.04 image manifest](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md)).
No candidate below needs an install step on CI. The image's Firefox comes from
`ppa:mozillateam/ppa` rather than the snap
([install-firefox.sh](https://github.com/actions/runner-images/blob/main/images/ubuntu/scripts/build/install-firefox.sh)),
which matters because stock Ubuntu 24.04's `firefox` package is a transitional
snap ([packages.ubuntu.com/noble/firefox](https://packages.ubuntu.com/noble/firefox))
and the snap confinement breaks geckodriver
([Launchpad #1968266](https://bugs.launchpad.net/bugs/1968266),
[Mozilla bug 1766125](https://bugzilla.mozilla.org/show_bug.cgi?id=1766125)).

So "what must be installed on the runner" is the wrong discriminator. The real
one is **what lands in `external/go.mod` and what a contributor has to have on
their own machine**, because the gate is `make test` and it runs locally too.

**The page refuses `eval`.** `internal/web/dashboard.go` sends
`default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`,
with no `'unsafe-eval'`. Any option that reads a computed style by injecting
JavaScript has to survive that. It does, on the Chromium side: CDP's
`Runtime.evaluate` carries `allowUnsafeEvalBlockedByCSP`, documented as "this
flag bypasses CSP for this evaluation and allows unsafe-eval. Defaults to true"
([Runtime domain](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/)).
WebDriver sidesteps the question entirely, because reading a computed style
there is a protocol command rather than a script.

## The criterion that separates them

The defect was a cascade defect. `index.html` carries `hidden` on seven
elements, `dashboard.js` toggles `.hidden` on five of them, and the component
rules in `dashboard.css` are author styles, so they outranked the browser's own
`[hidden] { display: none }` and the sign-in panel stayed on screen behind the
dashboard. The fix adds `[hidden] { display: none !important; }` to the author
sheet.

The suite's assertion for it is
`TestDashboardStylesPreserveHiddenState` in `dashboard_test.go`, which fetches
`/assets/dashboard.css` and looks for the substrings `[hidden]` and
`display: none !important`. That pins the one line that was added. It cannot
tell whether the rule wins, only whether somebody typed it — and a later
component rule with higher specificity and its own `!important` would pass the
test while reintroducing the bug.

Catching the class means resolving the cascade: author rules against the
browser's built-in stylesheet, by origin, importance, specificity and source
order, down to a computed value. That is the question every candidate is
graded on below, and it is what the null option cannot answer.

## chromedp

[github.com/chromedp/chromedp](https://github.com/chromedp/chromedp) speaks the
Chrome DevTools Protocol directly.

**Installed.** Nothing, on CI or locally, beyond a Chrome or Chromium that is
already there. `findExecPath` in
[`allocate.go`](https://github.com/chromedp/chromedp/blob/master/allocate.go)
searches `headless_shell`, `chromium`, `chromium-browser`, `google-chrome`,
`google-chrome-stable`, `/snap/bin/chromium` and friends; it never downloads a
browser. Its direct dependencies are `chromedp/cdproto`,
`go-json-experiment/json`, `gobwas/ws`, `ledongthuc/pdf` and
`orisano/pixelmatch` — [all pure Go](https://github.com/chromedp/chromedp/blob/master/go.mod),
no Node anywhere. On a machine without Chrome, `apt install chromium` or
[browser-actions/setup-chrome](https://github.com/browser-actions/setup-chrome)
covers it without npm.

**Live URL.** `chromedp.Navigate(urlstr)`
([`nav.go`](https://github.com/chromedp/chromedp/blob/master/nav.go)) takes an
arbitrary URL string with no scheme or host restriction, so
`httptest.NewServer(application.Web.Handler()).URL` goes straight in. The
existing harness needs no change.

**Offline.** Yes. The browser binary is found, not fetched, and the only
traffic is the local CDP websocket plus whatever the page requests — which for
this dashboard is its own origin and nothing else.

**Cost.** No project source publishes a launch time, so treat any figure as
unverified. What the API guarantees is that you pay it once:
`chromedp.NewContext(parent)` inherits the parent's allocated browser and
"its first Run creates a new tab on that browser," allocating a new browser
only when the parent has none
([`chromedp.go`](https://github.com/chromedp/chromedp/blob/master/chromedp.go)).
One browser per `TestMain`, one tab per test.

**Computed style.** Yes, two ways.
`chromedp.ComputedStyle(sel, &style)`
([`query.go`](https://github.com/chromedp/chromedp/blob/master/query.go)) calls
CDP's [`CSS.getComputedStyleForNode`](https://chromedevtools.github.io/devtools-protocol/tot/CSS/#method-getComputedStyleForNode),
which "returns the computed style for a DOM node" — post-cascade, with the
browser's own stylesheet in the mix. `chromedp.Evaluate` runs
`getComputedStyle(el).display` directly. Either would have reported `flex` on a
`[hidden]` element that an author rule had rescued, which is the defect stated
as an assertion.

**Maintenance.** Tag `v0.16.0` dated 2026-07-14; the most recent formal release
entry is `v0.15.1`, 2026-04-01
([releases](https://github.com/chromedp/chromedp/releases),
[tags](https://github.com/chromedp/chromedp/tags)). Four commits in the six
months to 2026-09-12 and nothing since mid-July; 180 open issues; effectively
one maintainer. Alive and slow, not stalled.

## playwright-go

[playwright-community/playwright-go](https://github.com/playwright-community/playwright-go),
which now redirects to `mxschmitt/playwright-go` — the module path in `go.mod`
is still `github.com/mxschmitt/playwright-go`.

**Installed.** This is the one that drags in a JS toolchain, and it does so by
design rather than by accident. The Go package is a binding over Playwright's
Node driver, which its own README describes: "The bridge between Node.js and
the other languages is basically a Node.js runtime combined with Playwright
which gets shipped for each of these languages (around 50MB) and then
communicates over stdio"
([README](https://github.com/playwright-community/playwright-go/blob/main/README.md)).
[`run.go`](https://github.com/playwright-community/playwright-go/blob/main/run.go)
pins `playwrightCliVersion = "1.62.1"` and `nodeVersion = "24.19.0"`, and
`playwright.Install()` downloads the `playwright-core` npm tarball from
`registry.npmjs.org` **and a Node.js binary from `nodejs.org/dist`**, unless
`PLAYWRIGHT_NODEJS_PATH` or `PLAYWRIGHT_CLI_PATH` points at existing ones. The
runner's preinstalled Node 22.23.2 could serve for the former. There is no
pure-Go code path: every Playwright call shells out to Node over stdio.

**Live URL.** Yes — `page.Goto(url)`
([`page.go`](https://github.com/playwright-community/playwright-go/blob/main/page.go)),
an ordinary string, no loopback restriction.

**Offline.** Only after a priming step that is not offline. Driver assembly and
browser installation happen in `Install()`, not at test time, and both can be
pre-seeded — `PLAYWRIGHT_BROWSERS_PATH` for browsers
([browsers doc](https://github.com/microsoft/playwright/blob/main/docs/src/browsers.md)),
a pre-populated driver directory or the two env vars above for the driver. So a
second run is offline; the first is not, and a fresh CI runner is always a
first run. Playwright's own CI guidance argues against caching the browsers:
"Caching browser binaries is not recommended, since the amount of time it takes
to restore the cache is comparable to the time it takes to download the
binaries"
([ci doc](https://github.com/microsoft/playwright/blob/main/docs/src/ci.md)).

**Cost.** The driver bundle is "around 50MB" per the README. Browsers occupy
281M for Chromium, 187M for Firefox, 180M for WebKit on disk, per Playwright's
own `du -hs` figures; Playwright installs only what is asked for. Download and
launch times are not published — unverified.

**Computed style.** Yes, and with the nicest assertion of the five.
`ToHaveCSS(name, value)`
([`locator_assertions.go`](https://github.com/playwright-community/playwright-go/blob/main/locator_assertions.go))
"ensures the Locator resolves to an element with the given computed CSS style,"
and the upstream doc's own canonical example is `toHaveCSS('display', 'flex')`
([LocatorAssertions](https://github.com/microsoft/playwright/blob/main/docs/src/api/class-locatorassertions.md)).
`ToBeVisible` is also computed rather than structural — "Element is considered
visible when it has non-empty bounding box and does not have `visibility:hidden`
computed style"
([actionability](https://github.com/microsoft/playwright/blob/main/docs/src/actionability.md))
— so it reports on the rendered result, not on the presence of the `hidden`
attribute. The exact defect, expressed as one line.

**Maintenance.** The healthiest of the five: `v0.6201.1` released 2026-08-17,
commits on `main` as recently as 2026-09-09. It is a **community** binding —
the officially maintained Playwright bindings are JS/TS, Python, .NET and Java —
and each release pins one upstream Playwright version, so a Playwright upgrade
is a deliberate bump rather than a drift.

## rod

[github.com/go-rod/rod](https://github.com/go-rod/rod), also a direct CDP
client.

**Installed.** By default, rod fetches its own Chromium.
`Launcher.getBin` is documented as "a smart helper to get the browser
executable path. If Browser.BinPath is not valid it will auto download the
browser"
([`launcher.go`](https://github.com/go-rod/rod/blob/main/lib/launcher/launcher.go)),
racing `storage.googleapis.com`, `registry.npmmirror.com` and
`playwright.azureedge.net` and caching into `$HOME/.cache/rod/browser`
([`browser.go`](https://github.com/go-rod/rod/blob/main/lib/launcher/browser.go)).
That is avoidable rather than inherent: `launcher.LookPath()` finds a system
browser and `launcher.New().Bin(path)` pins it
([custom-launch](https://github.com/go-rod/go-rod.github.io/blob/main/custom-launch.md)),
and rod's own compatibility notes treat a manually installed browser as a
first-class path. Its [dependencies](https://github.com/go-rod/rod/blob/main/go.mod)
are six `ysmood/*` modules, all pure Go; the npm-mirror entry is an HTTP mirror
URL, not a Node requirement.

**Live URL.** Yes — `page.Navigate(url)` / `MustNavigate`, any http URL.

**Offline.** Yes, provided `Bin()` is set so the download path is never
entered. With a system browser pinned, the only traffic is the local CDP
websocket.

**Cost.** No published launch figures. Reuse is well served: `MustIncognito`
for isolated contexts on one browser, plus `rod.PagePool` and `rod.BrowserPool`
for pooling
([browsers-pages](https://github.com/go-rod/go-rod.github.io/blob/main/browsers-pages.md)).

**Computed style.** Yes, and it is the default meaning of "visible" —
`Element.Visible()` runs a helper that reads
`window.getComputedStyle(el)` and requires `display !== 'none'`,
`visibility !== 'hidden'` and a non-empty bounding box
([`lib/js/helper.js`](https://github.com/go-rod/rod/blob/main/lib/js/helper.js)).
`Page.Eval` / `Element.Eval` run arbitrary JS, and
`proto.CSSGetComputedStyleForNode`
([`definitions.go`](https://github.com/go-rod/rod/blob/main/lib/proto/definitions.go))
exposes the CDP command. A `[hidden]` element rescued to `display: flex` comes
back visible, correctly.

**Maintenance.** The weakest of the three CDP clients. Latest release
`v0.116.2`, **2024-07-12** — over two years old
([releases](https://github.com/go-rod/rod/releases)). Three commits in the six
months to 2026-09-12, all of them sponsor-file updates rather than code. 212
open issues. One effective maintainer: 715 contributions against the next
contributor's nine. Not archived, but not moving either.

## Headless Firefox over WebDriver

The W3C protocol rather than a vendor one, with Mozilla's geckodriver in
front of it.

**Installed.** Nothing on CI: Firefox 155.0 and geckodriver 0.37.1 are on the
runner image, and both came from the Mozilla PPA and a GitHub release rather
than the snap, so the confinement problem above does not apply there. Locally
it does — `apt install firefox` on Ubuntu 24.04 installs the snap, and a
contributor would need the PPA or a tarball.
[browser-actions/setup-firefox](https://github.com/browser-actions/setup-firefox)
and `setup-geckodriver` exist and are current, and neither asks the repo for
Node.

The real cost here is the Go client. This is the one candidate where the
binding, not the browser, is the liability — see maintenance below.

**Live URL.** Yes by definition: `POST /session/{id}/url`
([Navigate To](https://www.w3.org/TR/webdriver2/#navigate-to)), with no
loopback restriction in the spec.

**Offline.** Nearly. geckodriver's default profile disables telemetry, update
checks, SNTP and remote settings
([`prefs.rs`](https://github.com/mozilla/geckodriver/blob/release/src/prefs.rs)),
but not captive-portal detection, which Firefox leaves on by default
([captive portals](https://firefox-source-docs.mozilla.org/networking/captive_portals.html)).
An offline run still sees probe attempts unless that pref is set explicitly.
They fail harmlessly, but they are traffic, and this dashboard's whole claim is
that it makes none.

**Cost.** Unpublished — unverified. A WebDriver session persists until
`Delete Session`, so one session can span a Go suite.

**Computed style.** Yes, and it is the only candidate where this is a
first-class protocol command rather than injected script.
[Get Element CSS Value](https://www.w3.org/TR/webdriver2/#get-element-css-value)
(`GET /session/{id}/element/{id}/css/{property name}`) returns the computed
value of the property, defined against
[CSS Cascade's computed value](https://drafts.csswg.org/css-cascade-4/#computed-value)
— genuinely post-cascade.
[Execute Script](https://www.w3.org/TR/webdriver2/#execute-script) with
`getComputedStyle` is the fallback. Asking for `display` on the sign-in panel
returns `flex` when the bug is present and `none` when it is not. Because it
needs no script injection, the page's `'unsafe-eval'`-free CSP is not even a
question.

**Maintenance.** Split, and this is the point. geckodriver is Mozilla's, with
v0.37.1 released 2026-07-20 and active development. The Go client is not:
[tebeka/selenium](https://github.com/tebeka/selenium) has had no push since
2025-01-28, over eighteen months, and no maintained successor turned up —
the one candidate found is a fork with a single 2026-07-19 push. Choosing this
route means a live protocol reached through a dormant client, or writing the
handful of HTTP calls the suite needs by hand.

## The null option — parsing without a browser

What the suite does today, taken as far as pure Go can take it.

**Installed.** Nothing. This is its entire case, and it is a strong one: no
browser, no binding, no runner dependency, no change to `.github/workflows/ci.yml`,
and `go test -race` stays exactly as fast as it is.

**Live URL.** It already uses one — `TestDashboardStylesPreserveHiddenState`
fetches the stylesheet from the `httptest` server. The fit is perfect because
it is the status quo.

**Offline.** Entirely.

**Cost.** Milliseconds.

**Computed style. No.** This is where it ends, and nothing in the Go ecosystem
changes the answer:

- `golang.org/x/net/html` implements the
  [WHATWG tree-construction algorithm](https://pkg.go.dev/golang.org/x/net/html)
  and does no CSS at all.
  [cascadia](https://github.com/andybalholm/cascadia) (v1.3.5, 2026-09-04, well
  maintained) matches selectors against that tree — it says *which* rules apply,
  never which one wins.
- No Go CSS library resolves the cascade.
  [tdewolff/parse](https://github.com/tdewolff/parse) (v2.8.16, 2026-08-11) is
  a CSS Syntax Level 3 tokenizer and parser, syntax only.
  [gorilla/css](https://github.com/gorilla/css) (v1.0.1, 2023-11-05) is a
  tokenizer. [vanng822/css](https://github.com/vanng822/css) (v1.0.1, 2021)
  produces an AST. [douceur](https://github.com/aymerick/douceur) (v0.2.0,
  2015) has an inliner, but it accumulates matched rules in source order
  without computing specificity, and it models no browser stylesheet — it reads
  only the `<style>` blocks in the document it is given.
- No Go project ships a browser's built-in stylesheet, and none implements
  origin, importance, specificity and source-order sorting to a computed value.
  The closest thing to an engine is
  [gost-dom/browser](https://github.com/gost-dom/browser), a headless browser
  for Go; its CSS package is another selector matcher, and its DOM package has
  no computed-style implementation.
- Running the script instead of reading it does not help.
  [goja](https://github.com/dop251/goja) is healthy — ES5.1 plus most of ES6,
  commits through 2026-09-11 — but its README is explicit that it is a
  JavaScript engine and not a DOM implementation, and `goja_nodejs` adds an
  event loop and timers rather than a `document`.
  [otto](https://github.com/robertkrimen/otto) targets ES5 (v0.5.1, 2024-11-05;
  last push 2025-06-13) and likewise has no DOM. `dashboard.js` uses
  `async`/`await`, template literals, `fetch`, 22 `createElement` calls, 12
  `addEventListener` calls and 13 `querySelector`/`querySelectorAll` calls, so
  a shim would have to cover real surface before the first assertion runs.

Reaching a `getComputedStyle`-equivalent answer in pure Go means hand-writing a
browser stylesheet baseline, a specificity calculator over a selector AST per
[Selectors 4](https://www.w3.org/TR/selectors-4/), and a cascade sort per
[CSS Cascade 4](https://www.w3.org/TR/css-cascade-4/), and then — for anything
`dashboard.js` does at runtime — DOM stubs under goja as well. That is building
a small CSS engine and calling it a test helper. It is the only option on this
page whose cost is unbounded.

Which does not make the null option worthless. It catches what it catches:
that the asset is served, that the CSP header says what it should, that the
page reaches for nothing off-origin, that a named rule is present. It cannot
catch a cascade defect, which is the specific thing this ticket was raised
about.

## Side by side

| | runner install | local install | live URL | offline | added deps | computed style | last release |
|---|---|---|---|---|---|---|---|
| **chromedp** | none — Chrome preinstalled | a Chrome or Chromium | yes | yes | 5, all pure Go | **yes** — `ComputedStyle`, `Evaluate` | v0.16.0 tag, 2026-07-14 |
| **playwright-go** | none — Node preinstalled | Node + driver + browsers | yes | after a priming download | Node runtime + npm driver | **yes** — `ToHaveCSS`, `ToBeVisible` | v0.6201.1, 2026-08-17 |
| **rod** | none — Chrome preinstalled | a Chrome, or it fetches one | yes | yes, if `Bin()` is pinned | 6, all pure Go | **yes** — `Visible()`, `Eval`, CDP | v0.116.2, **2024-07-12** |
| **Firefox/WebDriver** | none — Firefox + geckodriver preinstalled | Firefox off-snap | yes | almost — captive-portal probes | a dormant Go client | **yes** — a protocol command | geckodriver 0.37.1, 2026-07-20; client 2025-01-28 |
| **null option** | none | none | already does | yes | none | **no** | n/a |

Against the ticket's five criteria, the four browser options all clear the one
that matters — every one of them can assert a computed style, because every one
of them drives a real engine that resolves the cascade. They separate on the
other four:

1. **chromedp** — nothing to install anywhere a browser already exists, five
   pure-Go dependencies, offline, browser reuse built into the context model,
   two ways to read a computed style. Its weakness is cadence: four commits in
   six months and one maintainer.
2. **rod** — the same shape and the same strengths, with a friendlier
   `Visible()` and page pooling, but it downloads a browser unless told not to,
   and its release and commit record is the oldest here by two years.
3. **Firefox/WebDriver** — the only standardised protocol, the only
   computed-style read that is a protocol command rather than injected script,
   and a browser Mozilla actively maintains. Its cost is the Go client, which
   nobody maintains, and a local Firefox that has to come from outside the snap.
4. **playwright-go** — the best assertions and the healthiest binding on this
   page, bought by putting a Node runtime and an npm-sourced driver into a repo
   that has neither, and by a first run that is not offline.
5. **null option** — free on all four of the other criteria and unable to
   answer the fifth at any price short of writing a CSS engine.

The choice, including the choice not to spend anything,
belongs to [`dashboard-behaviour-under-test`](../tickets/dashboard-behaviour-under-test.md).
