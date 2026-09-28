# System Monitor

A DankMaterialShell-style system monitor for Noctalia, built as one declarative
panel plus a headless history service.

- **Processes**: live per-process CPU (tick deltas, like `top`, not `ps`'s lifetime
  average), memory, user and PID. Sort by any column, search by name, user, PID or
  command line, and switch between all processes and your own. Click a row for
  details and actions (end, force kill with a second-click confirm, pause/resume,
  copy PID/command, and force-kill as administrator through `pkexec` for other
  users' processes).
- **Performance**: history graphs for CPU, memory+swap, network, disk I/O, GPU+VRAM
  and temperatures, plus a tile per core with its own history sparkline, frequency
  and load average.
- **System**: OS, kernel, host, desktop, uptime, CPU and GPU models, memory, storage
  usage per mount, and process/thread counts.

## Open it

```sh
noctalia msg panel-toggle killingrace/sysmon:panel              # default tab
noctalia msg panel-toggle killingrace/sysmon:panel performance  # or processes | system
```

niri keybinding example (`~/.config/niri/config.kdl`):

```kdl
binds {
    Ctrl+Shift+Escape { spawn "noctalia" "msg" "panel-toggle" "killingrace/sysmon:panel"; }
}
```

## Requirements

- Noctalia with `plugin_api` ≥ 28 (`[system.monitor]` only for the Storage card).
- `gawk`, `find`, `kill`; optional `pkexec` (admin kill). GPU names come from sysfs + `pci.ids`
  (hwdata), never `lspci`, which would wake a sleeping discrete GPU. Optional
  `nvidia-smi` for NVIDIA load/VRAM/temperature.

## How it stays cheap

Noctalia gives every Luau callback a small CPU budget (about 25 ms). The per-process
work (walking `/proc`, CPU deltas, filtering, sorting, truncating to N rows) runs in
`scripts/procs.awk`. It only runs while the panel is open on the Processes tab, and
its snapshot lives in `$XDG_RUNTIME_DIR`. The history service reads a few small
files in `/proc` and `/sys` per tick.

## GPUs and hybrid laptops

Like DMS, GPU polling is opt-in per card (System tab → Monitoring). Integrated
AMD/Intel GPUs start on (sysfs reads only); discrete cards start off. The plugin
never calls `noctalia.systemStats()`, whose GPU probes would stay retained (with an
open NVML session on NVIDIA) until the plugin unloads, and never polls a card whose
`power/runtime_status` is `suspended`. A monitored discrete card that is awake is
polled with a one-shot `nvidia-smi` per tick, which does keep it from going idle, so
switch it off when you want it to sleep.

## Settings

| Key | Default | Meaning |
| --- | --- | --- |
| `update_interval` | 1000 ms | History sample rate and process refresh rate |
| `history_length` | 60 | Points per graph |
| `max_rows` | 60 | Processes listed after sort/filter |
| `cpu_scale` | machine | `machine`: rows add up to total CPU. `core`: 100% = one core |
| `show_kernel_threads` | false | Include kworker and other kernel threads |
| `default_tab` | processes | Tab shown when opened without context |
