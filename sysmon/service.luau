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
--   history     { cpu, cpuTemp, ram, swap, gpu, gpuTemp, vram, rx, tx, rd, wr } -- oldest first
--   io          { readBps, writeBps }
--   cores       { number } per-core usage, /proc/stat order
--   coreHistory { { number } } one oldest-first buffer per core, same order
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
  for name, rest in string.gmatch(text, "(cpu%d*) +([^\n]+)") do
    local total, idle, i = 0, 0, 0
    for n in string.gmatch(rest, "%d+") do
      i += 1
      if i <= 8 then -- user nice system idle iowait irq softirq steal (guest is in user)
        local v = tonumber(n)
        total += v
        if i == 4 or i == 5 then
          idle += v
        end
      end
    end
    cur[name] = { total, idle }
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

local function sampleCpuInfo()
  local text = noctalia.readFile("/proc/cpuinfo") or ""
  local sum, n = 0, 0
  for mhz in string.gmatch(text, "cpu MHz%s*:%s*([%d.]+)") do
    sum += tonumber(mhz)
    n += 1
  end
  return n > 0 and sum / n or nil
end

local function sampleMemory()
  local text = noctalia.readFile("/proc/meminfo") or ""
  local function kb(key)
    return tonumber(string.match(text, key .. ":%s*(%d+)")) or 0
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
  -- "  iface: rxBytes rxPackets ... (8 rx fields) txBytes ..."
  for name, fields in string.gmatch(text, "%s*([^%s:]+):%s*([^\n]+)") do
    if not matchesAny(name, VIRTUAL_IFACES) then
      local i = 0
      for n in string.gmatch(fields, "%d+") do
        i += 1
        if i == 1 then
          rx += tonumber(n)
        elseif i == 9 then
          tx += tonumber(n)
          break
        end
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

-- Bytes/s read and written across physical disks since the previous tick.
local function sampleDisk(nowMs)
  local text = noctalia.readFile("/proc/diskstats")
  if text == nil then
    return 0, 0
  end
  local rd, wr = 0, 0
  -- major minor name reads merged SECTORS_READ ms writes merged SECTORS_WRITTEN ...
  for name, r, w in string.gmatch(text, "%s*%d+%s+%d+%s+(%S+)%s+%d+%s+%d+%s+(%d+)%s+%d+%s+%d+%s+%d+%s+(%d+)[^\n]*") do
    if matchesAny(name, DISK_PATTERNS) then
      rd += tonumber(r)
      wr += tonumber(w)
    end
  end

  local readBps, writeBps = 0, 0
  if prevDisk ~= nil and nowMs > prevDisk.t then
    local dt = (nowMs - prevDisk.t) / 1000
    readBps = math.max(0, (rd - prevDisk.rd) * SECTOR_BYTES / dt)
    writeBps = math.max(0, (wr - prevDisk.wr) * SECTOR_BYTES / dt)
  end
  prevDisk = { rd = rd, wr = wr, t = nowMs }
  return readBps, writeBps
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

local function loadGpus()
  local cpuinfo = noctalia.readFile("/proc/cpuinfo") or ""
  local cpuModel = string.match(cpuinfo, "model name%s*:%s*([^\n]+)") or ""
  local cpuVendor = string.match(cpuinfo, "vendor_id%s*:%s*(%S+)") or ""
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
    freqMhz = sampleCpuInfo(),
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
    noctalia.state.set("coreHistory", coreHist)
  end

  local readBps, writeBps = sampleDisk(now)
  push(hist.rd, readBps)
  push(hist.wr, writeBps)

  noctalia.state.set("stats", {
    cpu = cpu, ram = ram, swap = swap, net = net, loadAvg = sampleLoad(), gpu = gpu, gpus = samples,
  })
  noctalia.state.set("io", { readBps = readBps, writeBps = writeBps })
  noctalia.state.set("history", hist)
end

for _, key in ipairs(SERIES) do
  hist[key] = {}
end
readConfig()
local maxKhz = readNumber("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
maxFreqMhz = maxKhz and maxKhz / 1000
loadGpus()

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
