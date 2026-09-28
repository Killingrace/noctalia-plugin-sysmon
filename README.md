# noctalia-plugin-sysmon

A [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)-style system
monitor for the [Noctalia](https://github.com/noctalia-dev/noctalia-shell) shell: one
floating panel with a live process list, history graphs and system info, written as a
native Noctalia Luau plugin.

| Tab | What you get |
| --- | --- |
| **Processes** | Live per-process CPU (tick deltas, like `top`), memory, user, PID. Sort by any column, search by name/user/PID/command line, all vs. your own processes. Click a row for details and actions: end, force kill (asks for a second click), pause/resume, copy PID/command, kill as admin via `pkexec`. |
| **Performance** | History graphs for CPU, memory + swap, network, disk I/O, GPU + VRAM and temperatures, plus a tile per core with its own sparkline. |
| **System** | OS, kernel, desktop, uptime, CPU, memory, storage per mount, and one card per GPU with its power state and per-card monitoring switch. |

Translations: English, Ukrainian.

## Install

Add this repo as a plugin source, then enable the plugin:

```sh
noctalia msg plugins source add sysmon git https://github.com/Killingrace/noctalia-plugin-sysmon
noctalia msg plugins enable killingrace/sysmon
```

Or in **Settings → Plugins → Add source**, then toggle **System Monitor** on. Updates
arrive with `noctalia msg plugins update sysmon` (or Noctalia's auto-update).

Requires Noctalia with plugin API ≥ 28, plus `gawk`, `find` and `kill`. Optional:
`pkexec` (kill other users' processes), `nvidia-smi` (NVIDIA load/VRAM/temperature),
`hwdata` (GPU model names from `pci.ids`).

## Open it

```sh
noctalia msg panel-toggle killingrace/sysmon:panel              # default tab
noctalia msg panel-toggle killingrace/sysmon:panel performance  # or processes | system
```

For example, as a niri keybinding:

```kdl
binds {
    Ctrl+Shift+Escape { spawn "noctalia" "msg" "panel-toggle" "killingrace/sysmon:panel"; }
}
```

## Hybrid-graphics friendly

The plugin never wakes a sleeping discrete GPU just to show numbers. It lists
adapters from sysfs instead of `lspci`, polls a card only if you switched monitoring
on for it (integrated GPUs start on, discrete cards off, like DMS), and skips any
card whose `power/runtime_status` is `suspended`. It also avoids
`noctalia.systemStats()`, whose GPU probes would otherwise keep an NVML session open.
Details are in [`sysmon/README.md`](sysmon/README.md#gpus-and-hybrid-laptops).

## Repository layout

```
catalog.toml          source catalog Noctalia reads (one row per plugin)
sysmon/
  plugin.toml         manifest: settings, the history service and the panel
  service.luau        always-on sampler: /proc + /sys -> ring buffers in shared state
  panel.luau          the panel UI (declarative ui.* tree)
  lib/fmt.luau        number formatting and load colours
  scripts/procs.*     process table sampler (gawk), runs only while the panel is open
  scripts/gpus.sh     GPU list from sysfs + pci.ids, without waking any card
  translations/       en, uk-UA
```

Settings (refresh rate, history length, row limit, CPU % scale, kernel threads,
default tab) and implementation notes are documented in
[`sysmon/README.md`](sysmon/README.md).

## Development

Register your clone as a local source; Noctalia hot-reloads the `.luau` files when
they change:

```sh
noctalia msg plugins source add sysmon-dev path ~/path/to/noctalia-plugin-sysmon
noctalia msg plugins enable killingrace/sysmon
```

Changes to `plugin.toml` or `translations/` need a plugin restart
(`noctalia msg plugins disable killingrace/sysmon && noctalia msg plugins enable killingrace/sysmon`).
Every Luau callback has a CPU budget of about 25 ms, so keep heavy work in `scripts/`,
and watch `~/.cache/noctalia/noctalia.log` for `[sysmon/panel] slow render` warnings.

## License

[MIT](LICENSE)
