# peripheral-discovery

Finding what is plugged into a Computer.

```
ccpm install peripheral-discovery
```

**Version 1.0.0 · no dependencies**

## What it is

CC:Tweaked reports peripherals by side or network name, with a type and a method
list, and nothing that says which of two modems is the one you meant. This turns
that into a uniform record so callers can select on **what a device can do**
rather than on where it happens to be attached.

```lua
local discovery = dofile("/.ccpm/packages/peripheral-discovery/1.0.0/init.lua")

for _, modem in ipairs(discovery.modems()) do
  print(modem.name, modem.type)
end
```

Each device is:

| Field | |
|---|---|
| `name` | the side or network name CC:Tweaked knows it by |
| `type` | its primary type |
| `types` | a set of **every** type it answers to — a peripheral may have several |
| `methods` | a set of its method names |
| `wrapped` | the wrapped peripheral table |

`types` and `methods` are sets, so `device.types.monitor` and
`device.methods.transmit` are the questions to ask. That is the whole point: a
caller looks for a capability instead of guessing from a name.

## Surface

| | |
|---|---|
| `scan()` | every attached peripheral, as records |
| `findAll(wanted, devices?)` | those answering to a type; pass `devices` to filter a scan you already have |
| `modems(devices?)` | shorthand for `findAll("modem", …)` |
| `monitors(devices?)` | shorthand for `findAll("monitor", …)` |
| `watch(callback)` | call `callback` on attach and detach |

`findAll` takes an optional device list so a caller that already scanned does not
scan again — attaching and detaching are rare, and a scan wraps every peripheral.

## What it is not

This package predates CraftNet and knows nothing about it. It has no idea what a
Logical Interface is, and it does not choose between two modems — that is
[`networking`](../networking/README.md), which is built on this.

It performs no I/O beyond `peripheral.*`, holds no state between calls, and is
the bottom of the dependency graph: nothing in the registry sits below it.
