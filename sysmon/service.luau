--!nonstrict
-- History service: samples the system once per tick and keeps ring buffers, so
-- the panel's graphs are already populated the moment it opens (the DMS
-- "always sampling" feel).
--
-- Everything is read straight from /proc and /sys, the way DMS's dgop does it,
-- and deliberately NOT through noctalia.systemStats(): its first call retains
-- the host's GPU probes until the plugin unloads, and once a hybrid laptop's
-- dGPU wakes up the host's open NVML session can keep it from sleeping again.
-- GPUs are polled only when the user switched monitoring on for that card
-- (System tab), and never while the card is runtime-suspended.
--
-- Publishes (noctalia.state):
--   stats       { cpu, ram, swap, net, loadAvg, gpu, gpus }  -- latest sample
--   history     { cpu, cpuTemp, ram, swap, gpu, gpuTemp, vram, rx, tx, rd, wr } -- oldest first,
--               only while the panel is open (it sets "panelOpen")
--   io          { readBps, writeBps }
--   cores       { number } per-core usage, /proc/stat order
--   coreHistory { { number } } one oldest-first buffer per core, same order (panel open only)
--   cpuInfo     { model, name, vendor, cores, threads } static, from /proc/cpuinfo
--   gpus        { GpuInfo } adapters from scripts/gpus.sh (static)
--   gpuMonitor  { [slot] = boolean } which adapters are polled; the panel edits it

local SERIES = { "cpu", "cpuTemp", "ram", "swap", "gpu", "gpuTemp", "vram", "rx", "tx", "rd", "wr" }

-- Whole block devices only: partitions would double-count, and loop/zram/dm
-- devices are views over something already counted.
local DISK_PATTERNS = { "^nvme%d+n%d+$", "^sd%a+$", "^vd%a+$", "^xvd%a+$", "^hd%a+$", "^mmcblk%d+$" }
local SECTOR_BYTES = 512

-- Bridges, veths and tunnels carry traffic the physical NIC already counted
-- (containers, k8s pods, VPNs); summing them would double the graph.
local VIRTUAL_IFACES = { "^lo$", "^veth", "^docker", "^br%-", "^virbr", "^cni", "^flannel", "^cali", "^kube",
  "^podman", "^vnet", "^tun", "^tap", "^wg" }

-- CPU package sensors by hwmon name, best first; temp1 is Tctl / Package id 0.
local CPU_SENSORS = { "k10temp", "zenpower", "coretemp", "cpu_thermal", "acpitz" }

local historyLen = 60
local hist = {}
local coreHist = {}
local prevDisk = nil -- { rd = sectors, wr = sectors, t = ms }
local prevCpu = nil -- { [name] = { total, idle } }
local prevNet = nil -- { rx, tx, t }
local cpuTempPath = nil
local maxFreqMhz = nil

local gpus = {} -- from scripts/gpus.sh
local gpuMonitor = nil -- { [slot] = boolean }, nil until the list and saved prefs are in
local nvidia = {} -- [slot] = { inFlight, last = sample }
local hasNvidiaSmi = noctalia.commandExists("nvidia-smi")

local pluginDir = noctalia.pluginDir() or "."

local function readConfig()
  historyLen = math.clamp(tonumber(noctalia.getConfig("history_length")) or 60, 20, 300)
  noctalia.setUpdateInterval(math.clamp(tonumber(noctalia.getConfig("update_interval")) or 1000, 500, 5000))
end

local function push(buf, v)
  table.insert(buf, v)
  while #buf > historyLen do
    table.remove(buf, 1)
  end
end

local function matchesAny(name, patterns)
  for _, pattern in ipairs(patterns) do
    if string.match(name, pattern) then
      return true
    end
  end
  return false
end

local function readNumber(path)
  local text = noctalia.readFile(path)
  return text and tonumber(string.match(text, "%-?%d+%.?%d*")) or nil
end

-- Text scanning. Inside Noctalia a Lua pattern costs about half a microsecond
-- for every position it is tried at (measured: one gmatch over the 29 KB
-- /proc/cpuinfo took ~16 ms of update()'s 25 ms budget; the stand-alone luau
-- binary does it in a fraction of that). So files are walked line by line with
-- plain string.find (one memchr per line), split with string.split, and
-- patterns only ever run anchored on a single short line.
local function lines(text)
  local pos, len = 1, #text
  return function()
    if pos > len then
      return nil
    end
    local e = string.find(text, "\n", pos, true) or (len + 1)
    local line = string.sub(text, pos, e - 1)
    pos = e + 1
    return line
  end
end

-- Non-empty space-separated fields of one line ("cpu  12 34" -> cpu, 12, 34).
-- The files split this way (stat, net/dev, diskstats) pad with spaces only.
local function fields(line)
  local out = {}
  for _, tok in ipairs(string.split(line, " ")) do
    if tok ~= "" then
      table.insert(out, tok)
    end
  end
  return out
end

-- Rest of the line that starts with `key` (first occurrence), after the colon:
-- "MemTotal:  32 kB" -> "32 kB". Keys used here only ever start a line.
local function field(text, key, from)
  local s = string.find(text, key, from or 1, true)
  if not s then
    return nil, nil
  end
  local e = string.find(text, "\n", s, true) or (#text + 1)
  local line = string.sub(text, s + #key, e - 1)
  return string.match(line, "^[^:]*:%s*(.*)$"), e
end

-- ── CPU / memory / network / load ────────────────────────────────────────────

local function findCpuSensor()
  local dirs = noctalia.listDir("/sys/class/hwmon") or {}
  local found = {}
  for _, dir in ipairs(dirs) do
    local base = "/sys/class/hwmon/" .. dir
    local name = noctalia.readFile(base .. "/name")
    if name then
      found[noctalia.string.trim(name)] = base .. "/temp1_input"
    end
  end
  for _, name in ipairs(CPU_SENSORS) do
    if found[name] then
      return found[name]
    end
  end
  return nil
end

-- /proc/stat: "cpu" is the aggregate, "cpuN" the logical CPUs. Busy share of
-- the jiffies since the previous tick; iowait counts as idle, like top.
local function sampleCpu()
  local text = noctalia.readFile("/proc/stat") or ""
  local cur = {}
  -- the cpu lines come first; stop before the (very long) "intr" line
  for line in lines(text) do
    if string.sub(line, 1, 3) ~= "cpu" then
      break
    end
    local f = fields(line)
    local total, idle = 0, 0
    for i = 2, math.min(9, #f) do -- user nice system idle iowait irq softirq steal (guest is in user)
      local v = tonumber(f[i]) or 0
      total += v
      if i == 5 or i == 6 then
        idle += v
      end
    end
    cur[f[1]] = { total, idle }
  end

  local function usage(name)
    local now, before = cur[name], prevCpu and prevCpu[name]
    if now == nil or before == nil or now[1] <= before[1] then
      return 0
    end
    local dt = now[1] - before[1]
    return math.clamp((dt - (now[2] - before[2])) / dt * 100, 0, 100)
  end

  local cores = {}
  local i = 0
  while cur["cpu" .. i] do
    table.insert(cores, usage("cpu" .. i))
    i += 1
  end
  local total = usage("cpu")
  prevCpu = cur
  return total, cores
end

-- /proc/cpuinfo is read OFF the script thread. For every "cpu MHz" line the
-- kernel asks that CPU for its frequency (an IPI, and amd-pstate reads an MSR
-- on it) and spins until it answers; with idle cores in deep C-states that
-- kernel time alone blew the 25 ms thread-CPU budget of update(). readFileAsync
-- runs on the host's I/O pool, so the result simply lands a tick later.
local cpuFreqMhz = nil
local cpuStatic = nil -- { model, name, vendor, cores, threads }, parsed once
local cpuinfoInFlight = false
local gpusRequested = false
local loadGpus -- forward declaration: needs the CPU model/vendor first

local function onCpuInfo(text)
  local sum, n, pos = 0, 0, 1
  while true do
    local mhz, nextPos = field(text, "cpu MHz", pos)
    if nextPos == nil then
      break
    end
    local v = tonumber(mhz)
    if v then
      sum += v
      n += 1
    end
    pos = nextPos
  end
  cpuFreqMhz = n > 0 and sum / n or cpuFreqMhz
  if cpuStatic == nil then
    local model = field(text, "model name") or "—"
    local threads, at = 0, 1
    while true do
      local s = string.find(text, "processor", at, true)
      if s == nil then
        break
      end
      threads += 1
      at = s + 9
    end
    cpuStatic = {
      model = model,
      -- "AMD Ryzen 7 260 w/ Radeon 780M Graphics": the iGPU half belongs to
      -- the GPU card, so the CPU line shows only the processor
      name = noctalia.string.trim((string.gsub(model, "%s+w/%s.*$", ""))),
      vendor = noctalia.string.trim(field(text, "vendor_id") or ""),
      cores = tonumber((field(text, "cpu cores"))),
      threads = threads,
    }
    noctalia.state.set("cpuInfo", cpuStatic)
  end
end

local function refreshCpuInfo()
  if cpuinfoInFlight then
    return
  end
  cpuinfoInFlight = noctalia.readFileAsync("/proc/cpuinfo", function(text)
    cpuinfoInFlight = false
    if text then
      -- A failed parse (e.g. a long GC step right after a reload tripping the
      -- budget) just retries on the next tick instead of logging an error.
      local ok, err = pcall(onCpuInfo, text)
      if not ok then
        noctalia.log("[sysmon/history] cpuinfo parse deferred: " .. tostring(err))
      end
    end
  end)
end

local function sampleMemory()
  local text = noctalia.readFile("/proc/meminfo") or ""
  local function kb(key) -- "MemTotal:  32596124 kB" -> 32596124
    local v = field(text, key) or ""
    return tonumber(string.match(v, "^(%d+)")) or 0
  end
  local total, avail = kb("MemTotal"), kb("MemAvailable")
  local swapTotal, swapFree = kb("SwapTotal"), kb("SwapFree")
  local used = math.max(0, total - avail)
  return {
    totalMb = total / 1024,
    usedMb = used / 1024,
    usagePercent = total > 0 and used / total * 100 or nil,
  }, { totalMb = swapTotal / 1024, usedMb = math.max(0, swapTotal - swapFree) / 1024 }
end

local function sampleNet(nowMs)
  local text = noctalia.readFile("/proc/net/dev") or ""
  local rx, tx = 0, 0
  -- "  iface: rxBytes rxPackets ... (8 rx fields) txBytes ..."; the two
  -- header lines have no colon
  for line in lines(text) do
    local colon = string.find(line, ":", 1, true)
    if colon then
      local name = noctalia.string.trim(string.sub(line, 1, colon - 1))
      if not matchesAny(name, VIRTUAL_IFACES) then
        local f = fields(string.sub(line, colon + 1))
        rx += tonumber(f[1]) or 0
        tx += tonumber(f[9]) or 0
      end
    end
  end
  local rxBps, txBps = 0, 0
  if prevNet ~= nil and nowMs > prevNet.t then
    local dt = (nowMs - prevNet.t) / 1000
    rxBps = math.max(0, (rx - prevNet.rx) / dt)
    txBps = math.max(0, (tx - prevNet.tx) / dt)
  end
  prevNet = { rx = rx, tx = tx, t = nowMs }
  return { rxBytesPerSec = rxBps, txBytesPerSec = txBps }
end

local function sampleLoad()
  local text = noctalia.readFile("/proc/loadavg") or ""
  local a, b, c = string.match(text, "^(%S+)%s+(%S+)%s+(%S+)")
  return a and { tonumber(a), tonumber(b), tonumber(c) } or {}
end

-- Bytes/s read and written across physical disks. /proc/diskstats is read on
-- the host's I/O pool: a synchronous read held the script thread ~10 ms per
-- tick (most of update()'s budget), for 9 short lines. The rate is computed
-- when the data lands and picked up by the next tick.
local diskRate = { readBps = 0, writeBps = 0 }
local diskInFlight = false

local function onDiskStats(text, nowMs)
  local rd, wr = 0, 0
  -- major minor name reads merged SECTORS_READ ms writes merged SECTORS_WRITTEN ...
  for line in lines(text) do
    local f = fields(line)
    if f[3] and matchesAny(f[3], DISK_PATTERNS) then
      rd += tonumber(f[6]) or 0
      wr += tonumber(f[10]) or 0
    end
  end
  if prevDisk ~= nil and nowMs > prevDisk.t then
    local dt = (nowMs - prevDisk.t) / 1000
    diskRate = {
      readBps = math.max(0, (rd - prevDisk.rd) * SECTOR_BYTES / dt),
      writeBps = math.max(0, (wr - prevDisk.wr) * SECTOR_BYTES / dt),
    }
  end
  prevDisk = { rd = rd, wr = wr, t = nowMs }
end

local function refreshDisk()
  if diskInFlight then
    return
  end
  diskInFlight = noctalia.readFileAsync("/proc/diskstats", function(text)
    diskInFlight = false
    if text then
      local ok, err = pcall(onDiskStats, text, noctalia.nowMs())
      if not ok then
        noctalia.log("[sysmon/history] diskstats parse failed: " .. tostring(err))
      end
    end
  end)
end

-- ── GPUs ─────────────────────────────────────────────────────────────────────

local function prefsPath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/gpu-monitor.json") or nil
end

-- Integrated GPUs (same vendor as the CPU, sysfs-only driver) are always awake
-- and cheap to read, so they start monitored; everything else - above all a
-- discrete NVIDIA card - starts off, like DMS's per-GPU opt-in.
local function defaultMonitored(g, cpuVendor)
  local integrated = (g.vendorId == "1002" and cpuVendor == "AuthenticAMD" and g.driver == "amdgpu")
    or (g.vendorId == "8086" and cpuVendor == "GenuineIntel" and (g.driver == "i915" or g.driver == "xe"))
  return integrated
end

local function loadGpuMonitor(cpuVendor)
  local saved = {}
  local path = prefsPath()
  local text = path and noctalia.readFile(path)
  if text then
    saved = noctalia.json.decode(text) or {}
  end
  local out = {}
  for _, g in ipairs(gpus) do
    if type(saved[g.slot]) == "boolean" then
      out[g.slot] = saved[g.slot]
    else
      out[g.slot] = defaultMonitored(g, cpuVendor)
    end
  end
  gpuMonitor = out
  noctalia.state.set("gpuMonitor", out)
end

loadGpus = function(cpu)
  local cpuModel, cpuVendor = cpu.model, cpu.vendor
  noctalia.runAsync({ "sh", pluginDir .. "/scripts/gpus.sh" }, function(res)
    local igpuName = string.match(cpuModel, "(Radeon [%w ]-Graphics)")
    local list = {}
    for line in string.gmatch(res.stdout or "", "[^\n]+") do
      local f = string.split(line, "\t")
      if #f >= 9 then
        local vendor, device = f[8], f[9]
        local short = string.match(vendor, "%[(.-)%]") or string.match(vendor, "^(%S+)") or ""
        local model = string.match(device, "%[(.-)%]")
        -- AMD APUs report a codename ("HawkPoint1"); the marketing name is in the CPU model.
        if model == nil and f[3] == "1002" and igpuName then
          model = igpuName
          short = "AMD"
        end
        table.insert(list, {
          name = string.format("%s %s", short, model or device),
          model = model or device,
          vendor = vendor,
          vendorId = f[3],
          driver = f[5],
          pciAddr = f[2],
          slot = (string.gsub(f[2], "^0000:", "")),
          path = f[1],
          hwmon = f[7] ~= "-" and f[7] or nil,
          primary = f[6] == "1",
        })
      end
    end
    gpus = list
    noctalia.state.set("gpus", list)
    loadGpuMonitor(cpuVendor)
  end, 5000)
end

-- power/runtime_status is served by the PM core: asking never wakes the card.
local function isAsleep(g)
  local status = noctalia.readFile(g.path .. "/power/runtime_status")
  status = status and noctalia.string.trim(status) or "active"
  return status == "suspended" or status == "suspending"
end

-- One-shot nvidia-smi (no NVML session left open), started only while the
-- card is awake; the result lands for the next tick.
local function pollNvidia(g)
  local st = nvidia[g.slot] or {}
  nvidia[g.slot] = st
  if st.inFlight or not hasNvidiaSmi then
    return
  end
  st.inFlight = true
  local started = noctalia.runAsync({
    "nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total",
    "--format=csv,noheader,nounits", "-i", g.pciAddr,
  }, function(res)
    st.inFlight = false
    local u, t, used, total = string.match(res.stdout or "", "(%d+),%s*(%d+),%s*(%d+),%s*(%d+)")
    st.last = u and {
      usage = tonumber(u), tempC = tonumber(t),
      vramUsed = tonumber(used) * 1024 * 1024, vramTotal = tonumber(total) * 1024 * 1024,
    } or nil
  end, 3000)
  if not started then
    st.inFlight = false
  end
end

local function sampleGpu(g, monitored)
  local s = { asleep = isAsleep(g), monitored = monitored }
  if s.asleep or not monitored then
    if nvidia[g.slot] then
      nvidia[g.slot].last = nil
    end
    return s
  end
  if g.driver == "amdgpu" then
    -- these attributes go through the driver: read only while awake (checked above)
    s.usage = readNumber(g.path .. "/gpu_busy_percent")
    s.vramUsed = readNumber(g.path .. "/mem_info_vram_used")
    s.vramTotal = readNumber(g.path .. "/mem_info_vram_total")
  elseif g.driver == "nvidia" then
    pollNvidia(g)
    local last = nvidia[g.slot].last
    if last then
      s.usage, s.tempC, s.vramUsed, s.vramTotal = last.usage, last.tempC, last.vramUsed, last.vramTotal
    end
  end
  if s.tempC == nil and g.hwmon then
    local milli = readNumber(g.hwmon .. "/temp1_input")
    s.tempC = milli and milli / 1000
  end
  return s
end

-- The adapter the Performance graphs follow: a monitored discrete card while
-- it is awake (that is where heavy work runs), otherwise the first monitored
-- one with numbers.
local function featuredGpu(samples)
  local best, bestRank = nil, 0
  for _, g in ipairs(gpus) do
    local s = samples[g.slot]
    if s and s.monitored and not s.asleep and (s.usage ~= nil or s.tempC ~= nil) then
      local rank = g.primary and 1 or 2
      if g.vendorId == "10de" then
        rank = 3
      end
      if rank > bestRank then
        best, bestRank = g, rank
      end
    end
  end
  return best
end

-- ── Tick ─────────────────────────────────────────────────────────────────────

local function sample()
  local now = noctalia.nowMs()
  refreshCpuInfo()
  -- Full buffers go to shared state (JSON-encoded by the host, ~2000 numbers)
  -- only while someone draws them; closed, the service just keeps them.
  local panelOpen = noctalia.state.get("panelOpen") == true
  if cpuStatic ~= nil and not gpusRequested then
    gpusRequested = true -- the GPU list needs the CPU vendor; spawned from a tick, not the file callback
    loadGpus(cpuStatic)
  end

  local cpuUsage, cores = sampleCpu()
  local ram, swap = sampleMemory()
  local net = sampleNet(now)
  if cpuTempPath == nil then
    cpuTempPath = findCpuSensor() or false
  end
  local milli = cpuTempPath and readNumber(cpuTempPath)
  local cpu = {
    usagePercent = cpuUsage,
    tempC = milli and milli / 1000,
    freqMhz = cpuFreqMhz,
    maxFreqMhz = maxFreqMhz,
  }

  -- the panel may have toggled monitoring since the last tick
  gpuMonitor = noctalia.state.get("gpuMonitor") or gpuMonitor
  local samples = {}
  for _, g in ipairs(gpus) do
    samples[g.slot] = sampleGpu(g, gpuMonitor ~= nil and gpuMonitor[g.slot] == true)
  end
  local featured = featuredGpu(samples)
  local fs = featured and samples[featured.slot] or {}
  local gpu = featured and {
    name = featured.model,
    slot = featured.slot,
    usagePercent = fs.usage,
    tempC = fs.tempC,
    vramUsedBytes = fs.vramUsed,
    vramTotalBytes = fs.vramTotal,
  } or {}

  push(hist.cpu, cpuUsage)
  push(hist.cpuTemp, cpu.tempC or 0)
  push(hist.ram, ram.usagePercent or 0)
  push(hist.swap, swap.totalMb > 0 and swap.usedMb / swap.totalMb * 100 or 0)
  push(hist.gpu, gpu.usagePercent or 0)
  push(hist.gpuTemp, gpu.tempC or 0)
  local vramTotal = gpu.vramTotalBytes or 0
  push(hist.vram, vramTotal > 0 and (gpu.vramUsedBytes or 0) / vramTotal * 100 or 0)
  push(hist.rx, net.rxBytesPerSec)
  push(hist.tx, net.txBytesPerSec)

  if #cores > 0 then
    noctalia.state.set("cores", cores)
    for i, v in ipairs(cores) do
      coreHist[i] = coreHist[i] or {}
      push(coreHist[i], v)
    end
    for i = #coreHist, #cores + 1, -1 do -- CPU went offline
      coreHist[i] = nil
    end
    if panelOpen then
      noctalia.state.set("coreHistory", coreHist)
    end
  end

  refreshDisk()
  local readBps, writeBps = diskRate.readBps, diskRate.writeBps
  push(hist.rd, readBps)
  push(hist.wr, writeBps)

  noctalia.state.set("stats", {
    cpu = cpu, ram = ram, swap = swap, net = net, loadAvg = sampleLoad(), gpu = gpu, gpus = samples,
  })
  noctalia.state.set("io", { readBps = readBps, writeBps = writeBps })
  if panelOpen then
    noctalia.state.set("history", hist)
  end
end

for _, key in ipairs(SERIES) do
  hist[key] = {}
end
readConfig()
local maxKhz = readNumber("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
maxFreqMhz = maxKhz and maxKhz / 1000
refreshCpuInfo() -- also loads the GPU list once the CPU vendor is known

function update()
  local ok, err = pcall(sample)
  if not ok then
    noctalia.log("[sysmon/history] sample failed: " .. tostring(err))
  end
end

function onConfigChanged()
  readConfig()
  for _, key in ipairs(SERIES) do
    while #hist[key] > historyLen do
      table.remove(hist[key], 1)
    end
  end
  for _, buf in ipairs(coreHist) do
    while #buf > historyLen do
      table.remove(buf, 1)
    end
  end
end
