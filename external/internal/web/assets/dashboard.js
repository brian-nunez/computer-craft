// CraftNet dashboard.
//
// Three views over one selection. The topology canvas is primary; Traffic and
// Incidents answer "what did this node do" and "what went wrong" about whatever
// is selected there, so an Operator moves between them without finding the same
// node twice.
//
// Nothing here renders a credential, a token, a MAC, or a payload -- not because
// the code is careful about it, but because none of those ever arrive: the wire
// refuses to construct a Traffic Event that carries one, and the topology
// projection carries a reference where a secret would be.

"use strict";

const state = {
  world: null,
  worlds: [],
  topology: null,
  presence: null,
  traffic: [],
  audit: [],
  selection: null, // { kind, id, label, data }
  view: "topology",
  filters: { outcome: "", operation: "", direction: "", selectedOnly: true },
};

const $ = (id) => document.getElementById(id);

//--------------------------------------------------------------------------
// Talking to craftnetd
//--------------------------------------------------------------------------

async function api(path, options = {}) {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (response.status === 401) {
    showSignIn();
    throw new Error("signed out");
  }
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(body.message || body.code || response.statusText);
  }
  return body;
}

//--------------------------------------------------------------------------
// Sign in
//--------------------------------------------------------------------------

function showSignIn(problem) {
  $("app").hidden = true;
  $("signin").hidden = false;
  const line = $("signin-problem");
  line.hidden = !problem;
  line.textContent = problem || "";
}

$("signin-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = new FormData(event.target);
  try {
    await api("/api/session", {
      method: "POST",
      body: JSON.stringify({ name: form.get("name"), password: form.get("password") }),
    });
    await start();
  } catch (problem) {
    showSignIn(problem.message);
  }
});

$("signout").addEventListener("click", async () => {
  await fetch("/api/session", { method: "DELETE", credentials: "same-origin" });
  showSignIn();
});

//--------------------------------------------------------------------------
// Loading
//--------------------------------------------------------------------------

async function start() {
  let session;
  try {
    session = await api("/api/session");
  } catch {
    return;
  }
  $("signin").hidden = true;
  $("app").hidden = false;
  $("operator").textContent = session.operator;

  const listed = await api("/api/worlds");
  state.worlds = listed.worlds || [];
  const picker = $("world");
  picker.innerHTML = "";
  for (const world of state.worlds) {
    const option = document.createElement("option");
    option.value = world.world_id;
    option.textContent = world.world_id;
    picker.append(option);
  }
  state.world = state.worlds.length ? state.worlds[0].world_id : null;
  picker.value = state.world || "";
  await refresh();
}

$("world").addEventListener("change", async (event) => {
  state.world = event.target.value;
  state.selection = null;
  await refresh();
});

async function refresh() {
  if (!state.world) return;
  const [world, traffic, audit] = await Promise.all([
    api(`/api/worlds/${encodeURIComponent(state.world)}`),
    api(`/api/worlds/${encodeURIComponent(state.world)}/traffic`),
    api(`/api/worlds/${encodeURIComponent(state.world)}/audit`),
  ]);
  state.topology = world.topology || {};
  state.presence = world;
  state.traffic = traffic.events || [];
  state.audit = audit.records || [];
  render();
}

//--------------------------------------------------------------------------
// Views
//--------------------------------------------------------------------------

for (const button of document.querySelectorAll(".tabs button")) {
  button.addEventListener("click", () => {
    state.view = button.dataset.view;
    for (const other of document.querySelectorAll(".tabs button")) {
      other.classList.toggle("active", other === button);
    }
    render();
  });
}

function render() {
  for (const name of ["topology", "traffic", "incidents", "audit"]) {
    $(`view-${name}`).hidden = state.view !== name;
  }
  renderPresence();
  renderTopology();
  renderInspector();
  renderTraffic();
  renderIncidents();
  renderAudit();
}

function renderPresence() {
  const connected = state.presence && state.presence.connected;
  $("presence").innerHTML =
    `<span class="dot ${connected ? "up" : "down"}"></span>` +
    (connected ? "Gateway connected" : "Gateway disconnected");
  // A World nobody has heard from is shown as stale rather than as current.
  $("stale").hidden = !(state.presence && state.presence.stale);
}

//--------------------------------------------------------------------------
// Topology
//--------------------------------------------------------------------------

function statusOf(networkID) {
  const statuses = (state.topology && state.topology.network_statuses) || [];
  const found = statuses.find((entry) => entry.customer_network_id === networkID);
  return found ? found.status : "enabled";
}

function nodeElement({ kind, id, label, address, flags = [], data }) {
  const node = document.createElement("div");
  node.className = "node";
  if (state.selection && state.selection.kind === kind && state.selection.id === id) {
    node.classList.add("selected");
  }
  node.innerHTML =
    `<span class="kind">${kind}</span><span class="name"></span>` +
    (address ? `<span class="addr"></span>` : "");
  node.querySelector(".name").textContent = label;
  if (address) node.querySelector(".addr").textContent = address;
  for (const flag of flags) {
    const chip = document.createElement("span");
    chip.className = "flag" + (flag === "disabled" ? " disabled" : "");
    chip.textContent = flag;
    node.append(chip);
  }
  node.addEventListener("click", () => {
    state.selection = { kind, id, label, data };
    render();
  });
  return node;
}

function renderTopology() {
  const canvas = $("canvas");
  canvas.innerHTML = "";
  const topology = state.topology;
  if (!topology || !topology.world) {
    canvas.innerHTML = `<p class="empty">This World has not reported a topology yet.</p>`;
    return;
  }

  const world = topology.world;
  canvas.append(nodeElement({
    kind: "world", id: world.world_id, label: world.world_id, data: world,
  }));

  const central = document.createElement("div");
  central.className = "children";
  central.append(nodeElement({
    kind: "central", id: world.central_id || "central", label: world.central_id || "Central Server",
    data: world,
  }));
  canvas.append(central);

  const ispBranch = document.createElement("div");
  ispBranch.className = "children";
  central.append(ispBranch);

  for (const isp of topology.isps || []) {
    const allocation = (isp.provider_allocations || [])[0];
    ispBranch.append(nodeElement({
      kind: "isp", id: isp.isp_id, label: isp.display_name || isp.isp_id,
      address: allocation ? `${allocation.first} – ${allocation.last}` : undefined,
      data: isp,
    }));

    const routerBranch = document.createElement("div");
    routerBranch.className = "children";
    ispBranch.append(routerBranch);

    for (const router of topology.routers || []) {
      if (router.isp_id !== isp.isp_id) continue;
      const status = statusOf(router.customer_network_id);
      routerBranch.append(nodeElement({
        kind: "network", id: router.customer_network_id,
        label: router.customer_network_name || router.customer_network_id,
        address: router.router_provider_address,
        flags: status === "disabled" ? ["disabled"] : [],
        data: router,
      }));

      const computerBranch = document.createElement("div");
      computerBranch.className = "children";
      routerBranch.append(computerBranch);

      const computers = (topology.computers || [])
        .filter((entry) => entry.customer_network_id === router.customer_network_id);
      for (const computer of computers) {
        computerBranch.append(nodeElement({
          kind: "computer", id: computer.computer_id,
          label: computer.hostname || computer.computer_id,
          // The network-scoped address is shown next to the Provider Address
          // above it, because two networks legitimately hold the same one.
          address: computer.address,
          data: computer,
        }));
      }
      if (!computers.length) {
        const none = document.createElement("p");
        none.className = "empty";
        none.textContent = "no Computers have joined";
        computerBranch.append(none);
      }
    }
  }
}

//--------------------------------------------------------------------------
// Inspector
//--------------------------------------------------------------------------

function definition(pairs) {
  const list = document.createElement("dl");
  for (const [term, value] of pairs) {
    if (value === undefined || value === null || value === "") continue;
    const dt = document.createElement("dt");
    dt.textContent = term;
    const dd = document.createElement("dd");
    dd.textContent = String(value);
    list.append(dt, dd);
  }
  return list;
}

function renderInspector() {
  const panel = $("inspector");
  panel.innerHTML = "";
  const selection = state.selection;
  if (!selection) {
    panel.innerHTML = `<p class="hint">Select a node to inspect it.</p>`;
    return;
  }

  const heading = document.createElement("h2");
  heading.textContent = selection.label;
  panel.append(heading);

  const data = selection.data || {};
  const failures = state.traffic.filter((entry) =>
    matchesSelection(entry) && isFailure(entry.Event || entry.event)).length;

  if (selection.kind === "computer") {
    panel.append(definition([
      ["identity", data.computer_id],
      ["hostname", data.hostname],
      ["address", data.address],
      ["network", data.customer_network_id],
      ["router", data.router_id],
      ["isp", data.isp_id],
      ["recent failures", failures],
    ]));
  } else if (selection.kind === "network") {
    const status = statusOf(data.customer_network_id);
    panel.append(definition([
      ["network", data.customer_network_id],
      ["router", data.router_id],
      ["provider address", data.router_provider_address],
      ["isp", data.isp_id],
      ["network status", status],
      ["recent failures", failures],
      // Credential status is shown; a credential value never is.
      ["credentials", "held, not shown"],
    ]));

    const actions = document.createElement("div");
    actions.className = "actions";
    const toggle = document.createElement("button");
    const disabling = status !== "disabled";
    toggle.textContent = disabling ? "Disable this network" : "Enable this network";
    if (disabling) toggle.className = "danger";
    toggle.addEventListener("click", () => confirmStatus(data, disabling));
    actions.append(toggle);
    panel.append(actions);
  } else if (selection.kind === "isp") {
    const allocation = (data.provider_allocations || [])[0];
    panel.append(definition([
      ["identity", data.isp_id],
      ["name", data.display_name],
      ["allocation", allocation ? `${allocation.first} – ${allocation.last}` : undefined],
      ["recent failures", failures],
    ]));
  } else {
    panel.append(definition([
      ["world", data.world_id],
      ["central server", data.central_id],
      ["gateway", state.presence && state.presence.connected ? "connected" : "disconnected"],
      ["topology revision", state.presence && state.presence.revision],
    ]));
  }

  const jump = document.createElement("div");
  jump.className = "actions";
  for (const target of ["traffic", "incidents"]) {
    const button = document.createElement("button");
    button.textContent = target === "traffic" ? "See its traffic" : "See its failures";
    button.addEventListener("click", () => {
      state.filters.selectedOnly = true;
      $("filter-selected").checked = true;
      state.view = target;
      for (const tab of document.querySelectorAll(".tabs button")) {
        tab.classList.toggle("active", tab.dataset.view === target);
      }
      render();
    });
    jump.append(button);
  }
  panel.append(jump);
}

//--------------------------------------------------------------------------
// Enable and disable
//--------------------------------------------------------------------------

function confirmStatus(router, disabling) {
  const dialog = $("confirm");
  $("confirm-title").textContent = disabling ? "Disable this Customer Network?" : "Enable this Customer Network?";
  $("confirm-body").textContent = disabling
    ? `New CraftNet operations for ${router.customer_network_name || router.customer_network_id} will be refused with network_disabled. Its configuration, identities, addresses, routes, and credentials are kept, so enabling it again needs no re-enrollment.`
    : `${router.customer_network_name || router.customer_network_id} will accept traffic again, with the same addresses it had before.`;
  $("confirm-ok").textContent = disabling ? "Disable" : "Enable";
  $("confirm-ok").className = disabling ? "danger" : "";

  dialog.returnValue = "";
  dialog.showModal();
  dialog.addEventListener("close", async function once() {
    dialog.removeEventListener("close", once);
    if (dialog.returnValue !== "ok") return;
    try {
      await api(`/api/worlds/${encodeURIComponent(state.world)}/networks/${encodeURIComponent(router.customer_network_id)}/status`, {
        method: "POST",
        body: JSON.stringify({ status: disabling ? "disabled" : "enabled" }),
      });
    } catch (problem) {
      window.alert(problem.message);
    }
    await refresh();
  });
}

//--------------------------------------------------------------------------
// Traffic
//--------------------------------------------------------------------------

const DELIVERED = new Set(["delivered_local", "delivered_remote", "delivered_external"]);
const isFailure = (event) => event && !DELIVERED.has(event.outcome);

function eventOf(entry) { return entry.Event || entry.event || {}; }

function matchesSelection(entry) {
  if (!state.filters.selectedOnly || !state.selection) return true;
  const event = eventOf(entry);
  switch (state.selection.kind) {
    case "computer": return event.computer_id === state.selection.id;
    case "network": return event.customer_network_id === state.selection.id;
    case "isp": return event.isp_id === state.selection.id;
    default: return true;
  }
}

function filtered() {
  return state.traffic.filter((entry) => {
    const event = eventOf(entry);
    if (state.filters.outcome && event.outcome !== state.filters.outcome) return false;
    if (state.filters.operation && event.operation !== state.filters.operation) return false;
    if (state.filters.direction && event.direction !== state.filters.direction) return false;
    return matchesSelection(entry);
  });
}

for (const [id, key] of [["filter-outcome", "outcome"], ["filter-operation", "operation"], ["filter-direction", "direction"]]) {
  $(id).addEventListener("change", (event) => {
    state.filters[key] = event.target.value;
    render();
  });
}
$("filter-selected").addEventListener("change", (event) => {
  state.filters.selectedOnly = event.target.checked;
  render();
});
$("filter-clear").addEventListener("click", () => {
  state.filters = { outcome: "", operation: "", direction: "", selectedOnly: false };
  $("filter-outcome").value = "";
  $("filter-operation").value = "";
  $("filter-direction").value = "";
  $("filter-selected").checked = false;
  render();
});

function refreshFilterOptions() {
  for (const [id, field] of [["filter-outcome", "outcome"], ["filter-operation", "operation"]]) {
    const picker = $(id);
    const chosen = picker.value;
    const values = [...new Set(state.traffic.map((entry) => eventOf(entry)[field]).filter(Boolean))].sort();
    picker.innerHTML = `<option value="">any</option>`;
    for (const value of values) {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      picker.append(option);
    }
    picker.value = values.includes(chosen) ? chosen : "";
  }
}

function renderTraffic() {
  refreshFilterOptions();
  const rows = filtered();

  const failures = rows.filter((entry) => isFailure(eventOf(entry))).length;
  const bytes = rows.reduce((total, entry) => total + (eventOf(entry).bytes || 0), 0);
  $("counters").innerHTML = "";
  for (const [label, value, bad] of [
    ["events", rows.length, false],
    ["failures", failures, failures > 0],
    ["bytes", bytes, false],
  ]) {
    const counter = document.createElement("div");
    counter.className = "counter" + (bad ? " bad" : "");
    counter.innerHTML = `<div class="value"></div><div class="label"></div>`;
    counter.querySelector(".value").textContent = String(value);
    counter.querySelector(".label").textContent = label;
    $("counters").append(counter);
  }

  const body = $("traffic").querySelector("tbody");
  body.innerHTML = "";
  if (!rows.length) {
    body.innerHTML = `<tr><td colspan="8" class="empty">No Traffic Events match.</td></tr>`;
    return;
  }
  for (const entry of rows) {
    const event = eventOf(entry);
    const row = document.createElement("tr");
    const where = event.computer_id || event.customer_network_id || event.isp_id || "";
    row.innerHTML =
      `<td class="mono"></td><td class="mono"></td><td></td><td></td>` +
      `<td class="mono"></td><td class="outcome ${isFailure(event) ? "bad" : "ok"}"></td>` +
      `<td class="mono"></td><td class="mono"></td>`;
    const cells = row.querySelectorAll("td");
    cells[0].textContent = entry.Sequence ?? entry.sequence ?? "";
    cells[1].textContent = (entry.ObservedAt || entry.observed_at || "").replace("T", " ").replace("Z", "");
    cells[2].textContent = event.direction || "";
    cells[3].textContent = event.kind || "";
    cells[4].textContent = event.operation || "";
    cells[5].textContent = event.outcome || "";
    cells[6].textContent = event.bytes ?? "";
    cells[7].textContent = where;
    body.append(row);
  }
}

//--------------------------------------------------------------------------
// Incidents
//--------------------------------------------------------------------------

function renderIncidents() {
  const failures = state.traffic.filter((entry) => isFailure(eventOf(entry)) && matchesSelection(entry));

  const counts = new Map();
  for (const entry of failures) {
    const code = eventOf(entry).outcome;
    counts.set(code, (counts.get(code) || 0) + 1);
  }

  const queue = $("queue");
  queue.innerHTML = `<h2>Exceptions</h2>`;
  if (!counts.size) {
    queue.insertAdjacentHTML("beforeend", `<p class="empty">Nothing has failed.</p>`);
  }
  for (const [code, count] of [...counts.entries()].sort((a, b) => b[1] - a[1])) {
    const row = document.createElement("div");
    row.className = "row" + (state.filters.outcome === code ? " selected" : "");
    row.innerHTML = `<span class="code"></span><span class="count"></span>`;
    row.querySelector(".code").textContent = code;
    row.querySelector(".count").textContent = String(count);
    row.addEventListener("click", () => {
      state.filters.outcome = state.filters.outcome === code ? "" : code;
      render();
    });
    queue.append(row);
  }

  const timeline = $("timeline");
  timeline.innerHTML = `<h2>Timeline</h2>`;
  const shown = state.filters.outcome
    ? failures.filter((entry) => eventOf(entry).outcome === state.filters.outcome)
    : failures;
  if (!shown.length) {
    timeline.insertAdjacentHTML("beforeend", `<p class="empty">Nothing to show.</p>`);
    return;
  }
  for (const entry of shown.slice().reverse()) {
    const event = eventOf(entry);
    const item = document.createElement("div");
    item.className = "event";
    item.innerHTML = `<div class="when"></div><div class="what"></div>`;
    item.querySelector(".when").textContent =
      (entry.ObservedAt || entry.observed_at || "").replace("T", " ").replace("Z", "");
    item.querySelector(".what").textContent =
      `${event.outcome} — ${event.kind}${event.operation ? " " + event.operation : ""}` +
      `${event.computer_id ? " @ " + event.computer_id : ""}`;
    timeline.append(item);
  }
}

//--------------------------------------------------------------------------
// Audit
//--------------------------------------------------------------------------

function renderAudit() {
  const body = $("audit").querySelector("tbody");
  body.innerHTML = "";
  if (!state.audit.length) {
    body.innerHTML = `<tr><td colspan="5" class="empty">Nothing recorded yet.</td></tr>`;
    return;
  }
  for (const record of state.audit.slice().reverse()) {
    const row = document.createElement("tr");
    row.innerHTML = `<td class="mono"></td><td></td><td></td><td class="mono"></td><td></td>`;
    const cells = row.querySelectorAll("td");
    cells[0].textContent = (record.recorded || "").replace("T", " ").replace("Z", "");
    cells[1].textContent = record.actor || "";
    cells[2].textContent = record.action || "";
    cells[3].textContent = record.subject || "";
    cells[4].textContent = record.detail || "";
    body.append(row);
  }
}

start();
