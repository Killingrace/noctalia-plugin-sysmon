--!nonstrict
-- System Monitor panel: Processes / Performance / System tabs.
--
-- Data flow:
--   * process table  <- scripts/procs.sh (gawk) via runAsync, only while open
--                       and on the Processes tab; filtering/sorting happen there.
--   * graph history  <- noctalia.state "history", filled by service.luau.
--   * live values    <- noctalia.state "stats"/"cores" (service.luau reads /proc and
--                       /sys itself; no systemStats(), see there) + diskStats() for mounts.
--
-- Open a specific tab from IPC:
--   noctalia msg panel-toggle killingrace/sysmon:panel performance

local fmt = require("./lib/fmt.luau")

local tr = noctalia.tr

-- ── Configuration (re-read on every open) ────────────────────────────────────

local maxRows = 60
local cpuScale = "machine"
local showKthreads = false
local historyLen = 60
local procEvery = 1 -- process sample every N second ticks

local function readConfig()
  maxRows = math.clamp(tonumber(noctalia.getConfig("max_rows")) or 60, 10, 200)
  cpuScale = noctalia.getConfig("cpu_scale") == "core" and "core" or "machine"
  showKthreads = noctalia.getConfig("show_kernel_threads") == true
  historyLen = math.clamp(tonumber(noctalia.getConfig("history_length")) or 60, 20, 300)
  local interval = math.clamp(tonumber(noctalia.getConfig("update_interval")) or 1000, 500, 5000)
  procEvery = math.max(1, math.floor(interval / 1000 + 0.5))
end

-- ── State ────────────────────────────────────────────────────────────────────

local TABS = { "processes", "performance", "system" }
local TAB_GLYPHS = { processes = "list", performance = "activity", system = "device-desktop" }

local tab = "processes"
local isOpen = false
local tick = 0

local procs = {} -- rows in display order
local procInfo = { procs = 0, threads = 0, running = 0, matched = 0, ncpu = 1 }
local haveSample = false
local sortKey, sortOrder = "mem", "desc"
local DEFAULT_ORDER = { cpu = "desc", mem = "desc", name = "asc", user = "asc", pid = "asc" }
local filterText = ""
local mineOnly = false
local paused = false
local selectedPid = nil
local killArmedAt = nil -- ms timestamp of the first "Force kill" click on the selected row
local KILL_CONFIRM_MS = 3000
local inFlight = false
local resample = false
local lastError = nil

local sysInfo = nil -- static facts, loaded once
local mounts = nil

local scriptPath = (noctalia.pluginDir() or ".") .. "/scripts/procs.sh"
local canPkexec = noctalia.commandExists("pkexec")
local currentUser = noctalia.getenv("USER") or ""

-- ── Process sampling ─────────────────────────────────────────────────────────

local function parseProcs(out)
  local rows = {}
  for line in string.gmatch(out, "[^\n]+") do
    local f = string.split(line, "\t")
    if f[1] == "#" then
      procInfo = {
        procs = tonumber(f[2]) or 0,
        threads = tonumber(f[3]) or 0,
        running = tonumber(f[4]) or 0,
        matched = tonumber(f[5]) or 0,
        ncpu = tonumber(f[6]) or 1,
      }
    elseif #f >= 9 then
      table.insert(rows, {
        pid = tonumber(f[1]),
        ppid = tonumber(f[2]) or 0,
        user = f[3],
        state = f[4],
        cpu = tonumber(f[5]) or 0,
        memKb = tonumber(f[6]) or 0,
        threads = tonumber(f[7]) or 0,
        name = f[8],
        cmd = f[9],
      })
    end
  end
  return rows
end

-- While a process is selected, keep the previous row order so the row the user
-- is about to act on does not jump away. Values still refresh; newcomers go last,
-- and the selected row survives even if it fell out of the top-N sample.
local function lockOrder(newRows)
  if selectedPid == nil then
    return newRows
  end
  local byPid = {}
  for _, r in ipairs(newRows) do
    byPid[r.pid] = r
  end
  local out, seen = {}, {}
  for _, old in ipairs(procs) do
    local r = byPid[old.pid]
    if r == nil and old.pid == selectedPid then
      r = old
      r.stale = true
    end
    if r ~= nil then
      table.insert(out, r)
      seen[r.pid] = true
    end
  end
  for _, r in ipairs(newRows) do
    if not seen[r.pid] then
      table.insert(out, r)
    end
  end
  return out
end

local render -- forward declaration

local function sampleProcs()
  if inFlight then
    resample = true -- coalesce: one more run after the current one
    return
  end
  inFlight = true
  local argv = {
    "sh", scriptPath,
    tostring(maxRows), sortKey, sortOrder, cpuScale,
    showKthreads and "1" or "0", mineOnly and "1" or "0", filterText,
  }
  local started = noctalia.runAsync(argv, function(res)
    inFlight = false
    local ok, err = pcall(function()
      if res.timedOut then
        lastError = tr("proc.error_timeout")
      elseif res.stdout == "" then
        lastError = res.stderr ~= "" and res.stderr or tr("proc.error_empty")
      else
        lastError = nil
        procs = lockOrder(parseProcs(res.stdout))
        haveSample = true
      end
    end)
    if not ok then
      noctalia.log("[sysmon/panel] parse failed: " .. tostring(err))
    end
    if resample and isOpen then
      resample = false
      sampleProcs()
    end
    if isOpen then
      render()
    end
  end, 5000)
  if not started then
    inFlight = false
  end
end

-- ── Process actions ──────────────────────────────────────────────────────────

local function sendSignal(p, sig, asRoot)
  local argv = { "kill", "-" .. sig, tostring(p.pid) }
  if asRoot then
    table.insert(argv, 1, "pkexec")
  end
  noctalia.runAsync(argv, function(res)
    if res.exitCode ~= 0 then
      local why = noctalia.string.trim(res.stderr)
      noctalia.notifyError(tr("notify.signal_failed", { name = p.name, pid = p.pid }), why ~= "" and why or nil)
      return
    end
    if sig == "TERM" or sig == "KILL" then
      selectedPid = nil
    end
    sampleProcs()
  end, asRoot and 60000 or 3000)
end

local function copy(text)
  noctalia.copyToClipboard(text, "text/plain")
end

local function selectPid(pid)
  selectedPid = selectedPid ~= pid and pid or nil
  killArmedAt = nil
  render()
end


-- ── Static system facts ──────────────────────────────────────────────────────

local function firstLine(path)
  local text = noctalia.readFile(path)
  return text and noctalia.string.trim((string.match(text, "[^\n]*"))) or nil
end

local function loadSysInfo()
  local info = {}
  local osRelease = noctalia.readFile("/etc/os-release") or ""
  info.os = string.match(osRelease, 'PRETTY_NAME="?([^"\n]+)') or "Linux"
  info.kernel = firstLine("/proc/sys/kernel/osrelease") or "—"
  info.host = firstLine("/proc/sys/kernel/hostname") or "—"
  info.desktop = noctalia.getenv("XDG_CURRENT_DESKTOP") or noctalia.getenv("XDG_SESSION_DESKTOP") or "—"
  info.session = noctalia.getenv("XDG_SESSION_TYPE") or "—"

  local cpuinfo = noctalia.readFile("/proc/cpuinfo") or ""
  info.cpuModel = string.match(cpuinfo, "model name%s*:%s*([^\n]+)") or "—"
  info.cores = tonumber(string.match(cpuinfo, "cpu cores%s*:%s*(%d+)"))
  local _, threads = string.gsub(cpuinfo, "\nprocessor%s*:", "")
  info.threads = threads + (string.find(cpuinfo, "^processor") and 1 or 0)

  -- "AMD Ryzen 7 8845HS w/ Radeon 780M Graphics": the iGPU half belongs to the
  -- GPU card, so the CPU line shows only the processor.
  info.cpuName = noctalia.string.trim((string.gsub(info.cpuModel, "%s+w/%s.*$", "")))

  -- GPUs come from the service (state "gpus"), which lists them via sysfs.
  info.shell = "Noctalia"
  sysInfo = info

  noctalia.runAsync({ "noctalia", "--version" }, function(res)
    local v = string.match(res.stdout, "v?(%d+%.%d+%.%d+)")
    if v then
      info.shell = "Noctalia " .. v
    end
  end, 3000)
end

local function uptimeSeconds()
  local text = noctalia.readFile("/proc/uptime")
  return text and tonumber(string.match(text, "^(%S+)")) or 0
end

-- ── Small UI building blocks ─────────────────────────────────────────────────

local function card(children, props)
  local p = { fill = "surface_variant", radius = 12, padding = 12, gap = 8 }
  if props then
    for k, v in pairs(props) do
      p[k] = v
    end
  end
  return ui.column(p, children)
end

local function cardTitle(glyph, title, value, valueColor, color)
  return ui.row({ align = "center", gap = 8 }, {
    ui.glyph({ name = glyph, size = 16, color = color or "primary" }),
    ui.label({ text = title, fontWeight = "semibold", color = "on_surface", flexGrow = 1, maxLines = 1 }),
    ui.label({ text = value or "", fontWeight = "bold", color = valueColor or color or "primary" }),
  })
end

local function dot(color)
  return ui.box({ width = 8, height = 8, radius = 4, fill = color })
end

local function legend(entries)
  local children = {}
  for i, e in ipairs(entries) do
    -- Entries keep their natural width; only the last one is flex-grown, which
    -- bounds its label to what is left so a long "VRAM 1.95 GiB / 7.96 GiB"
    -- ellipsizes instead of pushing past the card (and short ones never do).
    local last = i == #entries
    table.insert(children, ui.row({ gap = 6, align = "center", flexGrow = last and 1 or nil }, {
      dot(e[1]),
      ui.label({ text = e[2], fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = last and 1 or nil }),
    }))
  end
  return ui.row({ gap = 14, align = "center" }, children)
end

-- Fixed-width slot. Only flex containers (row/column) honour `width`: the host
-- drops it on labels and glyphs, and ui.spacer is always flexGrow = 1. Anything
-- that must line up across rows goes in one of these.
local function slot(width, justify, children)
  return ui.row({ width = width, align = "center", justify = justify or "start" }, children or {})
end

local function kv(key, value)
  return ui.row({ gap = 12, align = "start" }, {
    slot(130, "start", { ui.label({ text = key, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }) }),
    ui.label({ text = value or "—", color = "on_surface", flexGrow = 1, maxLines = 2 }),
  })
end

-- Oldest-first buffer -> fixed-width 0..1 series, right-aligned so the graph
-- scrolls in from the right edge while the history is still filling up.
local function series(buf, scale)
  local out = table.create(historyLen, 0)
  if buf == nil or scale <= 0 then
    return out
  end
  local len = #buf
  local offset = historyLen - len
  for i = math.max(1, 1 - offset), len do
    out[offset + i] = fmt.unit(buf[i] / scale)
  end
  return out
end

local function peak(...)
  local m = 0
  -- select() rather than ipairs({...}): ipairs would stop at a nil buffer
  for i = 1, select("#", ...) do
    local buf = select(i, ...)
    if buf then
      for _, v in ipairs(buf) do
        if v > m then
          m = v
        end
      end
    end
  end
  return m
end

-- Auto-scaled throughput graphs share one ceiling for both lines, so rx vs tx
-- (or read vs write) stay visually comparable. 64 KiB/s floor keeps an idle
-- link from blowing noise up to full height.
local function rateScale(a, b)
  return math.max(peak(a, b) * 1.15, 64 * 1024)
end

-- ── GPU helpers (Performance + System tabs) ──────────────────────────────────

-- Keyed by PCI vendor id rather than the vendor string or the driver: nvidia,
-- nvidia-open and nouveau are all NVIDIA, and an unbound card still has an id.
local GPU_BRAND = { ["10de"] = "#76b900", ["1002"] = "#ed1c24", ["8086"] = "#0071c5" }

local function gpuBrandColor(g): string?
  return GPU_BRAND[g.vendorId or ""]
end

-- Per-card opt-in, like DMS: the service polls only cards switched on here.
-- Saved in the plugin data dir so it survives restarts; the service reads the
-- shared state on its next tick.
local function setGpuMonitored(slot, on)
  local m = table.clone(noctalia.state.get("gpuMonitor") or {})
  m[slot] = on
  noctalia.state.set("gpuMonitor", m)
  local dir = noctalia.pluginDataDir()
  if dir then
    noctalia.writeFile(dir .. "/gpu-monitor.json", noctalia.json.encode(m) or "{}")
  end
  render()
end

-- ── Header & tabs ────────────────────────────────────────────────────────────

local function setTab(id)
  if tab == id then
    return
  end
  tab = id
  if id == "processes" then
    sampleProcs()
  end
  render()
end

local function header()
  local tabs = {}
  for _, id in ipairs(TABS) do
    table.insert(tabs, ui.button({
      key = "tab-" .. id .. (tab == id and "-on" or ""),
      text = tr("tabs." .. id),
      glyph = TAB_GLYPHS[id],
      variant = tab == id and "primary" or "ghost",
      controlSize = "sm",
      onClick = function()
        setTab(id)
      end,
    }))
  end

  local subtitle = sysInfo and string.format("%s · %s %s", sysInfo.host, tr("sys.uptime"), fmt.duration(uptimeSeconds())) or ""

  return ui.row({ align = "center", gap = 12 }, {
    ui.glyph({ name = "device-desktop-analytics", size = 22, color = "primary" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.row({ gap = 4, align = "center", fill = "surface_variant", radius = 10, padding = 4 }, tabs),
    ui.button({ glyph = "close", variant = "ghost", onClick = function()
      panel.close()
    end }),
  })
end

-- ── Processes tab ────────────────────────────────────────────────────────────

-- Fixed heights for everything above/below the list: only the list itself may
-- grow, otherwise flex layout sometimes hands spare height to the cards.
local SUMMARY_HEIGHT = 84
local TOOLBAR_HEIGHT = 36
local HEADER_HEIGHT = 28
local ROW_HEIGHT = 34
local FOOTER_HEIGHT = 18

local function summaryCard(glyph, title, value, sub, buf, color)
  return ui.column({
    flexGrow = 1, fill = "surface_variant", radius = 12, padding = 10, gap = 4,
    onClick = function()
      setTab("performance")
    end,
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 14, color = color }),
      ui.label({ text = title, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = value, fontWeight = "bold", color = color }),
    }),
    ui.graph({ values = buf, color = color, lineWidth = 1.5, fillOpacity = 0.18, height = 28 }),
    ui.label({ text = sub, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function summaryRow(stats, hist)
  hist = hist or {}
  local cpu = stats and stats.cpu or {}
  local ram = stats and stats.ram or {}
  local gpu = stats and stats.gpu or {}
  local net = stats and stats.net or {}
  local rs = rateScale(hist.rx, hist.tx)
  return ui.row({ gap = 10, height = SUMMARY_HEIGHT }, {
    summaryCard("cpu", tr("perf.cpu"), fmt.pct(cpu.usagePercent),
      string.format("%s · %s", fmt.mhz(cpu.freqMhz), fmt.temp(cpu.tempC)),
      series(hist.cpu, 100), fmt.levelColor(cpu.usagePercent)),
    summaryCard("memory", tr("perf.memory"), fmt.pct(ram.usagePercent),
      string.format("%s / %s", fmt.mib(ram.usedMb), fmt.mib(ram.totalMb)),
      series(hist.ram, 100), fmt.levelColor(ram.usagePercent, "secondary")),
    summaryCard("gpu-usage", tr("perf.gpu"), fmt.pct(gpu.usagePercent),
      string.format("%s · %s", gpu.vramUsedBytes and fmt.bytes(gpu.vramUsedBytes) or "—", fmt.temp(gpu.tempC)),
      series(hist.gpu, 100), fmt.levelColor(gpu.usagePercent, "tertiary")),
    summaryCard("network", tr("perf.network"), fmt.rate(net.rxBytesPerSec),
      string.format("↑ %s", fmt.rate(net.txBytesPerSec)),
      series(hist.rx, rs), "primary"),
  })
end

-- One column model drives both the header and every row, so a header cell and
-- the values under it always share the exact same width and alignment.
-- width = nil means "take the remaining space".
-- Fixed columns are slot()s: a width-less "fixed" spacer used to eat spare
-- width and push every column toward the middle.
local ICON_W, CHEVRON_W, COL_GAP = 18, 16, 8
local COLUMNS = {
  { key = "name", label = "proc.col_name", align = "start" },
  { key = "pid", label = "proc.col_pid", width = 72, align = "end" },
  { key = "user", label = "proc.col_user", width = 120, align = "start" },
  { key = "cpu", label = "proc.col_cpu", width = 76, align = "end" },
  { key = "mem", label = "proc.col_mem", width = 96, align = "end" },
}

local function setSort(key)
  if sortKey == key then
    sortOrder = sortOrder == "desc" and "asc" or "desc"
  else
    sortKey = key
    sortOrder = DEFAULT_ORDER[key]
  end
  sampleProcs()
  render()
end

-- Every column is sortable and every header cell is the same kind of node: a
-- clickable row with a label, plus an arrow on the active one.
local function headerCell(col)
  local active = sortKey == col.key
  local color = active and "primary" or "on_surface_variant"
  local text = ui.label({ text = tr(col.label), fontSize = 12, color = color, fontWeight = active and "bold" or "medium" })
  local children = { text }
  if active then
    local arrow = ui.glyph({ name = sortOrder == "desc" and "chevron-down" or "chevron-up", size = 12, color = color })
    children = col.align == "end" and { arrow, text } or { text, arrow }
  end
  return ui.row({
    key = "sort-" .. col.key .. (active and ("-" .. sortOrder) or ""),
    width = col.width,
    flexGrow = col.width == nil and 1 or nil,
    height = HEADER_HEIGHT,
    align = "center",
    justify = col.align == "end" and "end" or "start",
    gap = 4,
    onClick = function()
      setSort(col.key)
    end,
  }, children)
end

local function tableHeader()
  local cells = { slot(ICON_W) }
  for _, col in ipairs(COLUMNS) do
    table.insert(cells, headerCell(col))
  end
  table.insert(cells, slot(CHEVRON_W))
  return ui.row({ gap = COL_GAP, paddingH = 8, align = "center", height = HEADER_HEIGHT }, cells)
end

-- Glyph only. noctalia.appIconPath() walks desktop entries and icon themes; a
-- handful of lookups per render blew the 25ms callback budget and got the panel
-- disabled by the host watchdog.
local function procIcon(p)
  return slot(ICON_W, "start", {
    ui.glyph({
      key = "glyph-" .. p.pid,
      name = p.user == "root" and "settings" or "app-window",
      size = 16,
      color = "on_surface_variant",
    }),
  })
end

local STATE_KEYS = { R = "running", S = "sleeping", D = "disk", Z = "zombie", T = "stopped", t = "tracing", I = "idle", X = "dead" }

local function procDetails(p)
  local stateKey = STATE_KEYS[p.state]
  local stateText = stateKey and tr("state." .. stateKey) or p.state
  local stopped = p.state == "T"
  -- Signalling another user's process fails with EPERM; offer pkexec for those.
  local foreign = canPkexec and p.user ~= currentUser
  local armed = killArmedAt ~= nil
  return ui.column({ paddingH = 12, paddingV = 10, gap = 10 }, {
    ui.label({ text = p.cmd, fontSize = 11, color = "on_surface_variant", maxLines = 3 }),
    ui.row({ gap = 20 }, {
      ui.label({ text = string.format("%s %d", tr("proc.ppid"), p.ppid), fontSize = 11, color = "on_surface" }),
      ui.label({ text = string.format("%s %d", tr("proc.threads"), p.threads), fontSize = 11, color = "on_surface" }),
      ui.label({ text = string.format("%s %s", tr("proc.state"), stateText), fontSize = 11, color = "on_surface" }),
      ui.label({ text = tr("proc.stale"), fontSize = 11, color = "tertiary", visible = p.stale == true }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = tr("actions.terminate"), glyph = "player-stop", variant = "secondary", controlSize = "sm",
        onClick = function() sendSignal(p, "TERM") end }),
      -- SIGKILL loses unsaved work, so it takes a second click; the root variant
      -- is already confirmed by pkexec's own password prompt.
      ui.button({ text = tr(armed and "actions.kill_confirm" or "actions.kill"), glyph = armed and "alert-triangle" or "circle-x",
        variant = armed and "destructive" or "outline", controlSize = "sm",
        onClick = function()
          if armed then
            killArmedAt = nil
            sendSignal(p, "KILL")
            render() -- disarm now, not when the async kill reports back
          else
            killArmedAt = noctalia.nowMs()
            render()
          end
        end }),
      ui.button({ text = tr(stopped and "actions.cont" or "actions.stop"), glyph = stopped and "player-play" or "player-pause",
        variant = "outline", controlSize = "sm",
        onClick = function() sendSignal(p, stopped and "CONT" or "STOP") end }),
      ui.button({ glyph = "shield-lock", variant = "outline", controlSize = "sm", tooltip = tr("actions.kill_root"),
        visible = foreign, onClick = function() sendSignal(p, "KILL", true) end }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "PID", glyph = "copy", variant = "ghost", controlSize = "sm", tooltip = tr("actions.copy_pid"),
        onClick = function() copy(tostring(p.pid)) end }),
      ui.button({ text = tr("actions.command"), glyph = "copy", variant = "ghost", controlSize = "sm", tooltip = tr("actions.copy_cmd"),
        onClick = function() copy(p.cmd) end }),
    }),
  })
end

local function procCells(p)
  local coreEquivalent = cpuScale == "machine" and p.cpu * procInfo.ncpu or p.cpu
  local cpuColor = p.cpu <= 0 and "on_surface_variant" or fmt.levelColor(math.min(coreEquivalent, 100), "on_surface")
  local unmapped = string.sub(p.user, 1, 4) == "uid "
  return {
    name = { text = p.name, color = "on_surface", fontWeight = "medium" },
    pid = { text = tostring(p.pid), color = "on_surface_variant", fontSize = 12 },
    user = { text = p.user, color = unmapped and "outline" or "on_surface_variant", fontSize = 12 },
    cpu = { text = fmt.pct(p.cpu, 1), color = cpuColor, fontWeight = "medium" },
    mem = { text = fmt.kib(p.memKb), color = "on_surface" },
  }
end

local function procRow(p)
  local selected = p.pid == selectedPid
  local function toggle()
    selectPid(p.pid)
  end

  local cellProps = procCells(p)
  local children = { procIcon(p) }
  for _, col in ipairs(COLUMNS) do
    local props = cellProps[col.key]
    props.maxLines = 1
    if col.width == nil then
      -- a flex-grown label gets an exact width, so long names ellipsize
      props.flexGrow = 1
      table.insert(children, ui.label(props))
    else
      table.insert(children, slot(col.width, col.align, { ui.label(props) }))
    end
  end
  -- Expanded rows show a collapse arrow; the slot is reserved on every row so
  -- columns never shift when a row opens.
  table.insert(children, slot(CHEVRON_W, "center",
    selected and { ui.glyph({ name = "chevron-up", size = 14, color = "primary" }) } or nil))

  local row = ui.row({
    key = "row-" .. p.pid,
    height = ROW_HEIGHT, align = "center", gap = COL_GAP, paddingH = 8, radius = 8,
    -- exactly one click target per state: nested targets could toggle twice
    onClick = not selected and toggle or nil,
    opacity = p.stale and 0.6 or 1,
  }, children)

  if not selected then
    return row
  end
  -- The whole expanded card toggles, not just its first line; the action
  -- buttons inside still take their own clicks.
  return ui.column({
    key = "sel-" .. p.pid, fill = "primary/0.10", border = "primary/0.35", borderWidth = 1, radius = 10,
    onClick = toggle,
  }, {
    row,
    procDetails(p),
  })
end

local function processesTab(stats, hist)
  local toolbar = ui.row({ gap = 8, align = "center", height = TOOLBAR_HEIGHT }, {
    ui.input({
      key = "search",
      value = filterText,
      placeholder = tr("proc.search"),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(v)
        filterText = v
        selectedPid = nil
        sampleProcs()
      end,
    }),
    ui.select({
      key = "scope",
      options = { tr("proc.all"), tr("proc.mine") },
      selectedIndex = mineOnly and 1 or 0,
      controlSize = "sm",
      width = 180,
      onChange = function(index)
        mineOnly = tonumber(index) == 1
        selectedPid = nil
        sampleProcs()
      end,
    }),
    ui.button({
      key = paused and "resume" or "pause",
      glyph = paused and "player-play" or "player-pause",
      variant = paused and "primary" or "ghost",
      controlSize = "sm",
      tooltip = tr(paused and "proc.resume" or "proc.pause"),
      onClick = function()
        paused = not paused
        if not paused then
          sampleProcs()
        end
        render()
      end,
    }),
  })

  local rows = {}
  if lastError ~= nil then
    table.insert(rows, ui.label({ text = lastError, color = "error", maxLines = 4 }))
  elseif not haveSample then
    table.insert(rows, ui.label({ text = tr("proc.loading"), color = "on_surface_variant" }))
  elseif #procs == 0 then
    table.insert(rows, ui.label({ text = tr("proc.empty"), color = "on_surface_variant" }))
  end
  for _, p in ipairs(procs) do
    table.insert(rows, procRow(p))
  end

  local status = tr("proc.footer", { procs = procInfo.procs, threads = procInfo.threads, running = procInfo.running })
  if procInfo.matched > #procs then
    status ..= "  ·  " .. tr("proc.showing", { shown = #procs, matched = procInfo.matched })
  end
  local note = selectedPid ~= nil and tr("proc.locked") or (paused and tr("proc.paused") or tr("proc.hint"))

  return ui.column({ flexGrow = 1, gap = 10 }, {
    summaryRow(stats, hist),
    toolbar,
    ui.column({ flexGrow = 1, gap = 4, fill = "surface_variant/0.45", radius = 12, padding = 6 }, {
      tableHeader(),
      ui.separator({ color = "outline/0.4" }),
      ui.scroll({ key = "proc-scroll", flexGrow = 1, gap = 2 }, rows),
    }),
    ui.row({ gap = 8, align = "center", height = FOOTER_HEIGHT }, {
      ui.label({ text = status, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = note, fontSize = 11, color = selectedPid ~= nil and "primary" or "on_surface_variant", maxLines = 1 }),
    }),
  })
end

-- ── Performance tab ──────────────────────────────────────────────────────────

local GRAPH_HEIGHT = 150

local function graphCard(o)
  return card({
    cardTitle(o.glyph, o.title, o.value, o.valueColor, o.color),
    ui.graph({
      values = o.values, values2 = o.values2,
      color = o.color, color2 = o.color2,
      -- fixed height: flex-grown graph rows left big empty gaps between rows
      lineWidth = 2, fillOpacity = 0.15, height = GRAPH_HEIGHT,
    }),
    legend(o.legend),
  }, { flexGrow = 1, gap = 6 })
end

-- Per-core usage from the service's own /proc/stat deltas.
local function currentCores()
  return noctalia.state.get("cores") or {}
end

-- One tile per core: label + live % on top, that core's own history below, so
-- a single pegged thread stands out instead of drowning in the average.
-- 8 per line keeps tiles wide enough for a readable sparkline.
local CORE_COLS = 8
local CORE_GRAPH_HEIGHT = 34

local function coreTile(i, v, buf)
  local color = fmt.levelColor(v)
  -- Same fill as the card, set apart by a hairline instead of a dark block.
  return ui.column({
    key = "core-" .. i, flexGrow = 1, fill = "surface_variant", border = "outline/0.3", borderWidth = 1,
    radius = 8, paddingH = 8, paddingV = 6, gap = 4,
  }, {
    ui.row({ align = "center", gap = 4 }, {
      ui.label({ text = tr("perf.core_short", { n = i - 1 }), fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = string.format("%d%%", math.floor(v + 0.5)), fontSize = 12, fontWeight = "bold",
        color = fmt.levelColor(v, "on_surface") }),
    }),
    -- colour in the key: a retained control may not pick up a new colour
    ui.graph({ key = "core-graph-" .. i .. "-" .. color, values = series(buf, 100), color = color,
      lineWidth = 1.5, fillOpacity = 0.2, height = CORE_GRAPH_HEIGHT }),
  })
end

local function coresCard(stats)
  local cores = currentCores()
  local coreHist = noctalia.state.get("coreHistory") or {}
  local cpu = stats and stats.cpu or {}
  local load = stats and stats.loadAvg or {}
  local COLS = CORE_COLS
  local rows = {}
  for start = 1, #cores, COLS do
    local cells = {}
    for i = start, math.min(start + COLS - 1, #cores) do
      table.insert(cells, coreTile(i, cores[i] or 0, coreHist[i]))
    end
    -- pad the last line so tiles keep the same width
    for _ = #cells + 1, COLS do
      table.insert(cells, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(rows, ui.row({ gap = 6 }, cells))
  end
  if #cores == 0 then
    table.insert(rows, ui.label({ text = tr("perf.cores_pending"), color = "on_surface_variant" }))
  end

  local loadText = #load >= 3 and tr("perf.load", {
    a = string.format("%.2f", load[1]), b = string.format("%.2f", load[2]), c = string.format("%.2f", load[3]),
  }) or ""
  local freq = cpu.maxFreqMhz and string.format("%s / %s", fmt.mhz(cpu.freqMhz), fmt.mhz(cpu.maxFreqMhz)) or fmt.mhz(cpu.freqMhz)

  -- Content-sized: exactly as tall as its core rows (two for 16 threads). The
  -- spare panel height goes to the graphs above instead.
  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "cpu", size = 16, color = "primary" }),
      ui.label({ text = tr("perf.cores"), fontWeight = "semibold", color = "on_surface" }),
      ui.label({ text = freq, fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = loadText, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = fmt.pct(cpu.usagePercent), fontWeight = "bold", color = fmt.levelColor(cpu.usagePercent) }),
    }),
  }
  for _, r in ipairs(rows) do
    table.insert(children, r)
  end
  return card(children, { gap = 10 })
end

local function performanceTab(stats, hist, io)
  hist = hist or {}
  io = io or {}
  local cpu = stats and stats.cpu or {}
  local ram = stats and stats.ram or {}
  local swap = stats and stats.swap or {}
  local gpu = stats and stats.gpu or {}
  local net = stats and stats.net or {}
  local seconds = tr("perf.window", { seconds = historyLen })

  local netScale = rateScale(hist.rx, hist.tx)
  local diskScale = rateScale(hist.rd, hist.wr)
  local swapPct = (swap.totalMb or 0) > 0 and swap.usedMb / swap.totalMb * 100 or nil

  local cpuCard = graphCard({
    glyph = "cpu", title = tr("perf.cpu"), value = fmt.pct(cpu.usagePercent), color = "primary",
    valueColor = fmt.levelColor(cpu.usagePercent),
    values = series(hist.cpu, 100),
    legend = { { "primary", string.format("%s · %s", fmt.mhz(cpu.freqMhz), seconds) } },
  })
  -- Every card's corner shows the headline number (a % where one exists);
  -- absolute amounts live in the legend.
  local memCard = graphCard({
    glyph = "memory", title = tr("perf.memory"), value = fmt.pct(ram.usagePercent),
    valueColor = fmt.levelColor(ram.usagePercent, "secondary"),
    -- ui.graph paints series 2 (fill included) over series 1: the headline
    -- series goes second so swap never covers RAM.
    color = "tertiary", color2 = "secondary",
    values = series(hist.swap, 100), values2 = series(hist.ram, 100),
    legend = {
      { "secondary", string.format("%s %s / %s", tr("perf.ram"), fmt.mib(ram.usedMb), fmt.mib(ram.totalMb)) },
      { "tertiary", string.format("%s %s", tr("perf.swap"), swapPct and fmt.pct(swapPct) or "—") },
    },
  })
  local netCard = graphCard({
    glyph = "network", title = tr("perf.network"), value = tr("perf.peak", { value = fmt.rate(peak(hist.rx, hist.tx)) }), valueColor = "on_surface_variant", color = "primary", color2 = "secondary",
    values = series(hist.rx, netScale), values2 = series(hist.tx, netScale),
    legend = {
      { "primary", string.format("↓ %s", fmt.rate(net.rxBytesPerSec)) },
      { "secondary", string.format("↑ %s", fmt.rate(net.txBytesPerSec)) },
    },
  })
  local diskCard = graphCard({
    glyph = "device-floppy", title = tr("perf.disk"), value = tr("perf.peak", { value = fmt.rate(peak(hist.rd, hist.wr)) }), valueColor = "on_surface_variant", color = "tertiary", color2 = "secondary",
    values = series(hist.rd, diskScale), values2 = series(hist.wr, diskScale),
    legend = {
      { "tertiary", string.format("%s %s", tr("perf.read"), fmt.rate(io.readBps)) },
      { "secondary", string.format("%s %s", tr("perf.write"), fmt.rate(io.writeBps)) },
    },
  })
  local vram = gpu.vramTotalBytes and string.format("%s / %s", fmt.bytes(gpu.vramUsedBytes), fmt.bytes(gpu.vramTotalBytes)) or "—"
  -- The service picks one adapter for these graphs (a monitored dGPU while it
  -- is awake, else the iGPU); its name is the title, so "GPU 3%" is not a guess.
  local gpuCard = graphCard({
    glyph = "gpu-usage", title = gpu.name or tr("perf.gpu"), value = fmt.pct(gpu.usagePercent),
    color = "secondary", color2 = "tertiary", -- load (the corner number) on top
    valueColor = fmt.levelColor(gpu.usagePercent, "tertiary"),
    values = series(hist.vram, 100), values2 = series(hist.gpu, 100),
    -- the load line is named by the corner value in its colour
    legend = gpu.name and { { "secondary", string.format("%s %s", tr("perf.vram"), vram) } }
      or { { "on_surface_variant", tr("perf.gpu_unmonitored") } },
  })
  local hottest = math.max(cpu.tempC or -1, gpu.tempC or -1)
  local tempCard = graphCard({
    glyph = "temperature", title = tr("perf.temps"), color = "error", color2 = "tertiary",
    value = hottest >= 0 and fmt.temp(hottest) or "—", valueColor = fmt.tempColor(hottest >= 0 and hottest or nil),
    values = series(hist.cpuTemp, 100), values2 = series(hist.gpuTemp, 100),
    legend = {
      { "error", string.format("%s %s", tr("perf.cpu"), fmt.temp(cpu.tempC)) },
      { "tertiary", string.format("%s %s", tr("perf.gpu"), fmt.temp(gpu.tempC)) },
    },
  })

  -- Natural heights top-to-bottom; the scroll only matters on a short screen.
  return ui.scroll({ key = "perf-scroll", flexGrow = 1, gap = 12 }, {
    ui.row({ gap = 12 }, { cpuCard, memCard, gpuCard }),
    ui.row({ gap = 12 }, { netCard, diskCard, tempCard }),
    coresCard(stats),
  })
end

-- ── System tab ───────────────────────────────────────────────────────────────

local function storageCard()
  if mounts == nil then
    mounts = noctalia.diskMounts() or {}
  end
  local children = { cardTitle("database", tr("sys.storage"), nil, nil, "primary") }
  for _, m in ipairs(mounts) do
    local d = noctalia.diskStats(m.path)
    if d ~= nil and d.totalBytes > 0 then
      local used = d.totalBytes - d.freeBytes
      local pct = d.usagePercent
      table.insert(children, ui.column({ gap = 4 }, {
        ui.row({ gap = 8, align = "center" }, {
          ui.label({ text = m.path, color = "on_surface", fontWeight = "medium" }),
          ui.label({ text = string.format("%s · %s", m.filesystem, m.source), fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
          ui.label({ text = tr("sys.used_of", { used = fmt.bytes(used), total = fmt.bytes(d.totalBytes) }), fontSize = 11, color = "on_surface" }),
        }),
        ui.progress({ progress = fmt.unit(pct / 100), fill = fmt.levelColor(pct), track = "outline/0.25", height = 6, radius = 3 }),
      }))
    end
  end
  if #children == 1 then
    table.insert(children, ui.label({ text = tr("perf.unavailable"), color = "on_surface_variant" }))
  end
  return card(children, { gap = 10 })
end

-- Label + "used of total" + bar; shared by the memory card.
local function meter(label, usedBytes, totalBytes, pct, color)
  return ui.column({ gap = 4 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = label, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = tr("sys.used_of", { used = fmt.bytes(usedBytes), total = fmt.bytes(totalBytes) }), color = "on_surface" }),
      slot(44, "end", { ui.label({ text = fmt.pct(pct), color = color, fontWeight = "bold" }) }),
    }),
    ui.progress({ key = "meter-" .. label .. "-" .. color, progress = fmt.unit((pct or 0) / 100), fill = color,
      track = "outline/0.25", height = 6, radius = 3 }),
  })
end

local MIB = 1024 * 1024

local function osCard(info)
  return card({
    cardTitle("device-desktop", tr("sys.system"), nil, nil, "primary"),
    kv(tr("sys.os"), info.os),
    kv(tr("sys.kernel"), info.kernel),
    kv(tr("sys.host"), info.host),
    kv(tr("sys.desktop"), string.format("%s (%s)", info.desktop or "—", info.session or "—")),
    kv(tr("sys.shell"), info.shell),
    kv(tr("sys.uptime"), fmt.duration(uptimeSeconds())),
    kv(tr("sys.procs"), haveSample and tr("proc.footer", {
      procs = procInfo.procs, threads = procInfo.threads, running = procInfo.running,
    }) or "—"),
  }, { flexGrow = 1 })
end

local function cpuCard(info, stats)
  local cpu = stats and stats.cpu or {}
  local load = stats and stats.loadAvg or {}
  local topology = info.cores and tr("sys.topology_value", { cores = info.cores, threads = info.threads })
    or tostring(info.threads or "—")
  local freq = cpu.maxFreqMhz and string.format("%s / %s", fmt.mhz(cpu.freqMhz), fmt.mhz(cpu.maxFreqMhz)) or fmt.mhz(cpu.freqMhz)
  return card({
    cardTitle("cpu", tr("sys.cpu"), fmt.pct(cpu.usagePercent), fmt.levelColor(cpu.usagePercent), "primary"),
    kv(tr("sys.model"), info.cpuName or info.cpuModel),
    kv(tr("sys.topology"), topology),
    kv(tr("sys.freq"), freq),
    kv(tr("sys.temp"), fmt.temp(cpu.tempC)),
    kv(tr("sys.load"), #load >= 3 and string.format("%.2f  ·  %.2f  ·  %.2f", load[1], load[2], load[3]) or "—"),
  }, { flexGrow = 1 })
end

local function memoryCard(stats)
  local ram = stats and stats.ram or {}
  local swap = stats and stats.swap or {}
  local totalMb, usedMb = ram.totalMb or 0, ram.usedMb or 0
  local swapPct = (swap.totalMb or 0) > 0 and swap.usedMb / swap.totalMb * 100 or 0
  return card({
    cardTitle("memory", tr("sys.memory"), fmt.mib(totalMb), "on_surface_variant", "secondary"),
    meter(tr("sys.ram"), usedMb * MIB, totalMb * MIB, ram.usagePercent, fmt.levelColor(ram.usagePercent, "secondary")),
    kv(tr("sys.available"), fmt.mib(math.max(0, totalMb - usedMb))),
    (swap.totalMb or 0) > 0
      and meter(tr("sys.swap"), (swap.usedMb or 0) * MIB, swap.totalMb * MIB, swapPct, fmt.levelColor(swapPct, "tertiary"))
      or kv(tr("sys.swap"), tr("perf.unavailable")),
  }, { flexGrow = 1, gap = 12 })
end

local function gpuStateChip(asleep, brand)
  local color = asleep and "on_surface_variant" or (brand or "primary")
  return ui.row({ gap = 5, align = "center", paddingH = 8, paddingV = 3, radius = 10,
    fill = asleep and "outline/0.15" or (brand and brand .. "33" or "primary/0.18") }, {
    dot(color),
    ui.label({ text = tr(asleep and "sys.gpu_asleep" or "sys.gpu_active"), fontSize = 11, color = color }),
  })
end

-- DMS-style per-card switch. Off = the plugin never touches the card.
local function gpuMonitorButton(g, on)
  return ui.button({
    key = "gpu-mon-" .. g.slot .. (on and "-on" or "-off"),
    text = tr(on and "sys.gpu_monitor_on" or "sys.gpu_monitor_off"),
    glyph = on and "activity" or "eye-off",
    variant = on and "secondary" or "outline",
    controlSize = "sm",
    tooltip = tr("sys.gpu_monitor_tip"),
    onClick = function()
      setGpuMonitored(g.slot, not on)
    end,
  })
end

local function gpuBlock(i, g, s, monitored)
  local brand = gpuBrandColor(g)
  local asleep = s.asleep == true
  local details = string.format("%s · %s %s · %s %s", g.vendor, tr("sys.driver"), g.driver, tr("sys.slot"), g.slot)
  if g.primary then
    details ..= " · " .. tr("sys.gpu_primary")
  end
  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = g.name, color = brand or "on_surface", fontWeight = "semibold", maxLines = 2, flexGrow = 1 }),
      gpuStateChip(asleep, brand),
      gpuMonitorButton(g, monitored),
    }),
    ui.label({ text = details, fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
  }
  local hasData = monitored and not asleep and (s.usage ~= nil or s.tempC ~= nil)
  if hasData then
    local vram = s.vramTotal and s.vramTotal > 0
      and tr("sys.used_of", { used = fmt.bytes(s.vramUsed), total = fmt.bytes(s.vramTotal) }) or "—"
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
      ui.progress({ key = "gpu-bar-" .. i, progress = fmt.unit((s.usage or 0) / 100), fill = brand or "tertiary",
        track = "outline/0.25", height = 6, radius = 3, flexGrow = 1 }),
      slot(44, "end", { ui.label({ text = fmt.pct(s.usage), fontWeight = "bold", color = brand or "tertiary" }) }),
    }))
    table.insert(children, ui.label({ text = string.format("%s %s · %s", tr("perf.vram"), vram, fmt.temp(s.tempC)),
      fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  else
    local note = not monitored and "sys.gpu_off_note" or (asleep and "sys.gpu_asleep_note" or "sys.gpu_no_data")
    table.insert(children, ui.label({ text = tr(note), fontSize = 11, color = "on_surface_variant", maxLines = 2 }))
  end
  -- brand tint: ~12% fill, ~45% border (#rrggbbaa), like DMS's vendor cards;
  -- a sleeping card fades so the one doing the work stands out
  return ui.column({
    key = "gpu-" .. i, radius = 8, padding = 10, gap = 6, opacity = asleep and 0.7 or 1,
    fill = brand and brand .. "1f" or "surface_variant",
    border = brand and brand .. "73" or "outline/0.3", borderWidth = 1,
  }, children)
end

local function gpuCard(stats)
  local gpus = noctalia.state.get("gpus") or {}
  local monitor = noctalia.state.get("gpuMonitor") or {}
  local samples = stats and stats.gpus or {}
  local children = { cardTitle("gpu-usage", tr("sys.gpu"), nil, nil, "tertiary") }
  for i, g in ipairs(gpus) do
    table.insert(children, gpuBlock(i, g, samples[g.slot] or {}, monitor[g.slot] == true))
  end
  if #gpus == 0 then
    table.insert(children, ui.label({ text = tr("sys.gpu_none"), color = "on_surface_variant" }))
  end
  return card(children, { flexGrow = 1 })
end

local function systemTab(stats)
  local info = sysInfo or {}
  return ui.scroll({ key = "sys-scroll", flexGrow = 1, gap = 12 }, {
    ui.row({ gap = 12 }, { osCard(info), cpuCard(info, stats) }),
    ui.row({ gap = 12 }, { memoryCard(stats), gpuCard(stats) }),
    storageCard(),
  })
end

-- ── Render & lifecycle ───────────────────────────────────────────────────────

render = function()
  if not isOpen then
    return
  end
  local startedAt = os.clock()
  local stats = noctalia.state.get("stats") -- sampled by service.luau, never noctalia.systemStats()
  local hist = noctalia.state.get("history")
  local io = noctalia.state.get("io")

  local body
  if tab == "performance" then
    body = performanceTab(stats, hist, io)
  elseif tab == "system" then
    body = systemTab(stats)
  else
    body = processesTab(stats, hist)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14 }, { header(), body }))

  -- Early warning well below the host's ~25ms budget, so a slow path shows up
  -- in the log before the watchdog disables the panel.
  local ms = (os.clock() - startedAt) * 1000
  if ms > 8 then
    noctalia.log(string.format("[sysmon/panel] slow render on '%s' tab: %.1f ms", tab, ms))
  end
end

function onOpen(context)
  readConfig()
  isOpen = true
  tick = 0
  if sysInfo == nil then
    loadSysInfo()
  end
  mounts = nil

  local requested = type(context) == "string" and string.lower(noctalia.string.trim(context)) or ""
  if table.find(TABS, requested) then
    tab = requested
  else
    local default = noctalia.getConfig("default_tab")
    tab = table.find(TABS, default) and default or "processes"
  end

  panel.setWantsSecondTicks(true)
  render()
  sampleProcs() -- always: System tab shows process counts too
end

function onClose()
  isOpen = false
  selectedPid = nil
  paused = false
  killArmedAt = nil
  panel.setWantsSecondTicks(false)
end

function update()
  if not isOpen then
    return
  end
  tick += 1
  if killArmedAt ~= nil and noctalia.nowMs() - killArmedAt > KILL_CONFIRM_MS then
    killArmedAt = nil -- disarm; the render below restores the button
  end
  if tab == "processes" and not paused and tick % procEvery == 0 then
    sampleProcs() -- renders when the sample lands
  else
    render()
  end
end
