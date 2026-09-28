--!nonstrict
-- Number formatting shared by the panel. Pure functions, no host calls.

local fmt = {}

local UNITS = { "B", "KiB", "MiB", "GiB", "TiB" }

-- 1536 -> "1.5 KiB". Three significant digits, like the built-in bar widgets.
function fmt.bytes(n: number?): string
  n = n or 0
  local i = 1
  while n >= 1024 and i < #UNITS do
    n /= 1024
    i += 1
  end
  if i == 1 then
    return string.format("%d B", n)
  end
  return string.format(n >= 100 and "%.0f %s" or (n >= 10 and "%.1f %s" or "%.2f %s"), n, UNITS[i])
end

function fmt.kib(n: number?): string
  return fmt.bytes((n or 0) * 1024)
end

function fmt.mib(n: number?): string
  return fmt.bytes((n or 0) * 1024 * 1024)
end

function fmt.rate(bytesPerSec: number?): string
  return fmt.bytes(bytesPerSec) .. "/s"
end

function fmt.pct(v: number?, decimals: number?): string
  if v == nil then
    return "—"
  end
  return string.format("%." .. (decimals or 0) .. "f%%", v)
end

function fmt.temp(c: number?): string
  if c == nil then
    return "—"
  end
  return string.format("%.0f°C", c)
end

function fmt.mhz(m: number?): string
  if m == nil then
    return "—"
  end
  if m >= 1000 then
    return string.format("%.2f GHz", m / 1000)
  end
  return string.format("%.0f MHz", m)
end

-- 273840 -> "3d 4h 4m"
function fmt.duration(seconds: number?): string
  local s = math.floor(seconds or 0)
  local d = s // 86400
  local h = (s % 86400) // 3600
  local m = (s % 3600) // 60
  if d > 0 then
    return string.format("%dd %dh %dm", d, h, m)
  elseif h > 0 then
    return string.format("%dh %dm", h, m)
  end
  return string.format("%dm", m)
end

-- Clamp into the 0..1 range ui.graph / ui.progress expect.
function fmt.unit(v: number?): number
  v = v or 0
  if v < 0 then
    return 0
  elseif v > 1 then
    return 1
  end
  return v
end

-- Load colour: calm → attention → alarm. Same thresholds everywhere so the
-- process list, core grid and summary cards agree.
function fmt.levelColor(pct: number?, base: string?): string
  pct = pct or 0
  if pct >= 85 then
    return "error"
  elseif pct >= 60 then
    return "tertiary"
  end
  return base or "primary"
end

function fmt.tempColor(c: number?): string
  if c == nil then
    return "on_surface_variant"
  elseif c >= 85 then
    return "error"
  elseif c >= 70 then
    return "tertiary"
  end
  return "on_surface"
end

return fmt
