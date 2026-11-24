-- v2 shared helpers: maths, angles, files.
local U = {}

function U.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U.sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end

-- Angle difference folded into -180..180 (target - current).
function U.wrap180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

function U.wrap360(a)
    return a % 360
end

U.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

-- Compass bearing (0 = north/-Z, 90 = east/+X) from a world dx/dz.
function U.bearing(dx, dz)
    return U.wrap360(math.deg(U.atan2(dx, -dz)))
end

function U.hypot(a, b)
    return math.sqrt(a * a + b * b)
end

-- Speed that still lets you stop within `dist` at deceleration `a`.
function U.brakeSpeed(dist, a)
    if dist <= 0 then return 0 end
    return math.sqrt(2 * a * dist)
end

-- Move `cur` toward `want` by at most `step`.
function U.approach(cur, want, step)
    if want > cur then return math.min(want, cur + step) end
    return math.max(want, cur - step)
end

-- First-order low-pass step (time constant tau seconds).
function U.lowpass(prev, new, dt, tau)
    if prev == nil then return new end
    if tau <= 0 then return new end
    local a = dt / (tau + dt)
    return prev + (new - prev) * a
end

function U.fmt(n, decimals)
    if n == nil or n ~= n then return "--" end
    return string.format("%." .. (decimals or 0) .. "f", n)
end

-- Read a Lua table file ("return {...}"). nil on any failure.
function U.loadTable(path)
    if not fs.exists(path) then return nil end
    local fn = loadfile(path, "t", {})
    if not fn then return nil end
    local ok, t = pcall(fn)
    if ok and type(t) == "table" then return t end
    return nil
end

-- Write a table as "return <serialized>". Writes a temp file first so a full
-- disk can never leave a half-written (unreadable) file behind.
function U.saveTable(path, t)
    local ok, data = pcall(textutils.serialize, t)
    if not ok then return false end
    local tmp = path .. ".tmp"
    local wok = pcall(function()
        local f = fs.open(tmp, "w")
        if not f then error("open") end
        f.write("return " .. data .. "\n")
        f.close()
    end)
    if not wok then pcall(fs.delete, tmp) return false end
    pcall(fs.delete, path)
    return pcall(fs.move, tmp, path)
end

function U.copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = U.copy(v) end
    return o
end

-- Overlay b onto a (recursive), returns a.
function U.merge(a, b)
    for k, v in pairs(b or {}) do
        if type(v) == "table" and type(a[k]) == "table" then
            U.merge(a[k], v)
        else
            a[k] = v
        end
    end
    return a
end

return U
