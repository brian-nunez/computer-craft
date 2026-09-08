# ccpm

A small GitHub-backed package manager for CC:Tweaked. It resolves recursive
dependencies, chooses the newest compatible semantic version, detects cycles,
downloads files before installation, and records installed versions in a lock file.

## Publish it

1. Add the file URLs and manifests for your real packages.
2. Push the repository to GitHub and install ccpm on a CC:Tweaked computer:

```text
wget https://raw.githubusercontent.com/brian-nunez/computer-craft/main/ccpm.lua ccpm.lua
```

## Use it

```text
ccpm install networking
ccpm install peripheral-discovery ^1.0.0
ccpm list
```

Packages are stored under `/.ccpm/packages/<name>/<version>/`. Application code
can load a known locked package path, or a future ccpm release can add shims and a
`require` searcher. The lock file is `/.ccpm/lock.json`.

The `networking` package automatically installs `peripheral-discovery`. Load it
from its locked package path, then select a modem:

```lua
local networking = dofile("/.ccpm/packages/networking/1.0.0/init.lua")
local selected = networking.selectModem({
  -- CC:Tweaked reports both normal and Ender modems as wireless. Identify an
  -- Ender modem by its attached side/name when the server exposes no subtype.
  kinds = { left = "ender" },
})

if selected then
  print(selected.name, selected.kind)
  selected.wrapped.open(1234)
end

for _, monitor in ipairs(networking.monitors()) do
  print("monitor", monitor.name)
end
```

Modem selection is deterministic: Ender first, then wired, then ordinary
wireless; ties are sorted by peripheral name. The discovery package also offers
`scan`, `findAll`, `modems`, `monitors`, and `watch`.

Supported constraints are `*`, exact versions, `^`, `~`, `>=`, `>`, `<=`, and `<`.
This MVP accepts one constraint per dependency; compound ranges are not supported.
