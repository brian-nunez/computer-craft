# Milestone 7 — dashboard acceptance run

The API half of this gate is automated and runs in CI. This is the other half:
it needs a browser and a pair of eyes, and it has **not** been run yet.

Everything below is asserted against the API in `internal/web/dashboard_test.go`.
What this run adds is whether a person can actually *use* it: whether variant B
reads as the primary view, whether selection visibly carries between tabs, and
whether the confirmation dialog says enough to make the decision safely.

No Minecraft is required. A stand-in Central Server is enough.

## Setup

```bash
cd external
go run ./cmd/craftnetd provision -world world-overworld -central central-main
go run ./cmd/craftnetd operator -name alex          # type a passphrase
go run ./cmd/craftnetd serve -listen 127.0.0.1:8080
```

Then open <http://127.0.0.1:8080/>.

Feeding it a World needs something on the Gateway. Either connect a real Central
Server once the in-world transport exists, or run the test harness against a
long-lived server: `go test ./internal/web -run TestScenario9 -v` reports the
same fixture this checklist refers to.

## Checks

### 1. Sign-in

- [ ] The page opens on the sign-in card and shows nothing else — no World
      names, no topology, no counts.
- [ ] A wrong password says the same thing as an operator name that does not
      exist.
- [ ] Signing in lands on Topology with the World selected.
- [ ] `document.cookie` in the console does **not** show the session cookie.

### 2. Topology reads as primary

- [ ] Topology is the tab that is open on arrival.
- [ ] The hierarchy is legible without clicking: World, Central Server, ISP,
      Customer Networks, Computers.
- [ ] Each ISP shows its Provider Allocation range, each Customer Network its
      Provider Address, each Computer its network-scoped address.
- [ ] `alex-pc` and `harvester` both show `192.168.1.20`, and it is obvious from
      the layout that they are in different Customer Networks.
- [ ] A Customer Network with no Computers says so rather than looking broken.

### 3. Selection carries

- [ ] Selecting a Computer highlights it and fills the inspector.
- [ ] "See its traffic" switches to Traffic with only that Computer's events.
- [ ] Unchecking *only the selected node* widens it to the whole World without
      losing the selection.
- [ ] "See its failures" switches to Incidents, still scoped to the selection.
- [ ] Going back to Topology, the same node is still selected.

### 4. Traffic

- [ ] The counters agree with the visible rows as filters change.
- [ ] Filtering by outcome, operation, and direction each narrow the table.
- [ ] Clear resets every filter, including the selection scope.
- [ ] Failing outcomes are visually distinct from delivered ones.
- [ ] No column anywhere shows a payload, a token, a MAC, or a password.

### 5. Incidents

- [ ] The exception queue lists outcomes by count, worst first.
- [ ] Clicking one filters the timeline; clicking it again clears it.
- [ ] With nothing failing, both panes say so rather than showing an empty box.

### 6. Staleness

- [ ] With the Gateway connected, the header shows a green dot and no banner.
- [ ] Stop the Central Server. Within about thirty seconds the dot goes red and
      the banner appears.
- [ ] What was already reported is still readable underneath — the dashboard
      shows the last thing it heard, clearly marked as such, rather than
      emptying itself.

### 7. Disable and re-enable Farm

- [ ] Selecting the Farm network offers "Disable this network".
- [ ] The confirmation dialog names Farm, says new operations will be refused
      with `network_disabled`, and says the configuration is kept.
- [ ] Cancelling changes nothing.
- [ ] Confirming marks Farm disabled in the canvas.
- [ ] Farm's router, Provider Address, Computers, and their addresses are all
      still shown.
- [ ] New Farm traffic appears in Incidents as `network_disabled`.
- [ ] The Audit tab shows `network.disable`, attributed to the signed-in
      Operator, followed by `command.applied`.
- [ ] Re-enabling asks for confirmation too, and Farm comes back with the same
      addresses and no enrollment step.

### 8. Failing closed

- [ ] `curl -i http://127.0.0.1:8080/api/worlds` with no cookie returns 401.
- [ ] `curl -i http://127.0.0.1:8080/api/whatever` returns 401, not the page.
- [ ] Signing out and pressing Back does not show the previous view's data.
- [ ] `craftnetd operator -name alex -disable`, then reload: the session stops
      working immediately.

## What to record

Note the exact commit, the `craftnetd version` output, the browser and its
version, and anything that needed explaining out loud. A dashboard that needs
explaining is a dashboard finding.
