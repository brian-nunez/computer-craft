# networking

Choosing the right modem.

```
ccpm install networking
```

**Version 1.0.0 · depends on `peripheral-discovery` ^1.0.0**

## What it is

A Computer may have several modems attached, and which one matters: an Ender
modem reaches across the World, a wireless one reaches as far as the weather
allows, a wired one reaches exactly where the cable goes. This classifies each
modem it finds and orders them by that preference, so a caller asks for the
modem it needs instead of guessing at a side.

```lua
local networking = dofile("/.ccpm/packages/networking/1.0.0/init.lua")

local best = networking.selectModem()
print(best.name, best.kind)          --> back  ender
```

## Classification

Each modem gets a `kind`, decided by capability rather than by position:

| Kind | Recognised by | Priority |
|---|---|:---:|
| `ender` | an `ender_modem` type, or `ender` in its name | 1 |
| `wired` | `isWireless()` answering false | 2 |
| `wireless` | `isWireless()` answering true | 3 |

`modems()` returns them sorted by that priority, then by name — so the order is
stable across runs on the same Computer, which matters when the choice is being
made for you.

A modem whose `isWireless` cannot be called at all gets no kind and sorts last,
rather than being dropped: an unusual peripheral is still something a caller may
want to see.

## When the guess is wrong

Name it:

```lua
networking.selectModem({ kinds = { ["modem_3"] = "ender" } })
```

An unrecognised kind is an error, not a silent fallback — a typo in a build
script should stop, not quietly pick a different modem.

## Surface

| | |
|---|---|
| `modems(options?)` | every modem, classified and ordered by preference |
| `selectModem(options?)` | the first of those — the one you probably want |
| `monitors()` | attached monitors, passed through from `peripheral-discovery` |

`options.kinds` maps a peripheral name to `ender`, `wired`, or `wireless`.

## What it is not

This package predates CraftNet and knows nothing about it. It hands back a
modem; it does not open a channel, frame a message, or know what a Logical
Interface is.

CraftNet reaches it through `craftnet-runtime`'s modem adapter, which is where a
modem becomes a Logical Interface bound to a role and its channels. See
[`craftnet-runtime`](../craftnet-runtime/README.md).
