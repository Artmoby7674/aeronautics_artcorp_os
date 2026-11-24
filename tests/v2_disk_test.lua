-- v2 ship backup on a floppy (v2/lib/shipdisk.lua): save on one computer,
-- load on another, with a fake filesystem, disk drive and floppy.
package.path = "./v2/lib/?.lua;" .. package.path
package.loaded["shipdisk"], package.loaded["util"] = nil, nil

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

-- ---------------------------------------------------------------- fakes
local saved = { fs = rawget(_G, "fs"), peripheral = rawget(_G, "peripheral"), disk = rawget(_G, "disk"),
    textutils = rawget(_G, "textutils"), loadfile = loadfile }

local files, dirs, cap = {}, {}, 125000 -- floppy: 125 KB
local function norm(p) return (p:gsub("^/+", ""):gsub("/+$", "")) end
local function used(prefix)
    local n = 0
    for p, d in pairs(files) do if p:sub(1, #prefix + 1) == prefix .. "/" then n = n + #d end end
    return n
end
_G.fs = {
    combine = function(a, b) a, b = norm(a), norm(b) if a == "" then return b end return a .. "/" .. b end,
    getDir = function(p) return (norm(p):match("^(.*)/[^/]*$")) or "" end,
    exists = function(p) p = norm(p) return files[p] ~= nil or dirs[p] == true end,
    isDir = function(p) return dirs[norm(p)] == true end,
    makeDir = function(p)
        p = norm(p)
        local acc = ""
        for part in p:gmatch("[^/]+") do acc = acc == "" and part or (acc .. "/" .. part) dirs[acc] = true end
    end,
    list = function(d)
        d = norm(d)
        local out, seen = {}, {}
        for p in pairs(files) do
            local rest = p:match("^" .. d:gsub("%p", "%%%0") .. "/([^/]+)")
            if rest and not seen[rest] then seen[rest] = true out[#out + 1] = rest end
        end
        return out
    end,
    delete = function(p)
        p = norm(p)
        files[p], dirs[p] = nil, nil
        for k in pairs(files) do if k:sub(1, #p + 1) == p .. "/" then files[k] = nil end end
        for k in pairs(dirs) do if k:sub(1, #p + 1) == p .. "/" then dirs[k] = nil end end
    end,
    copy = function(a, b)
        a, b = norm(a), norm(b)
        if files[b] then error("File exists") end
        if b:sub(1, 5) == "disk/" and used("disk") + #files[a] > cap then error("Out of space") end
        files[b] = files[a]
    end,
    move = function(a, b) a, b = norm(a), norm(b) files[b] = files[a] files[a] = nil end,
    getSize = function(p) return #(files[norm(p)] or "") end,
    getFreeSpace = function(p) if norm(p):sub(1, 4) == "disk" then return cap - used("disk") end return 1e6 end,
    open = function(p, mode)
        p = norm(p)
        if mode == "r" then
            if not files[p] then return nil end
            local d = files[p]
            return { readAll = function() return d end, close = function() end }
        end
        if p:sub(1, 5) == "disk/" and used("disk") > cap then return nil end
        local buf = {}
        return { write = function(s) buf[#buf + 1] = s end, writeLine = function(s) buf[#buf + 1] = s .. "\n" end,
            close = function() files[p] = table.concat(buf) end }
    end,
}
local function ser(v, ind)
    ind = ind or ""
    if type(v) == "table" then
        local out = { "{\n" }
        for k, x in pairs(v) do
            local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
            out[#out + 1] = ind .. "  " .. key .. " = " .. ser(x, ind .. "  ") .. ",\n"
        end
        out[#out + 1] = ind .. "}"
        return table.concat(out)
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
_G.textutils = { serialize = ser, unserialize = function(s) return load("return " .. s)() end,
    formatTime = function(t) return string.format("%.2f", t) end }

_G.loadfile = function(path, mode, env)
    local d = files[norm(path)]
    if not d then return nil, "no file" end
    return load(d, "@" .. path, "t", env or _G)
end

local drive = { present = true, data = true }
local have_drive = true
_G.peripheral = {
    getNames = function() return have_drive and { "redstone_relay_0", "drive_0" } or { "redstone_relay_0" } end,
    getType = function(n) return n:match("^drive") and "drive" or "redstone_relay" end,
}
_G.disk = {
    isPresent = function() return drive.present end,
    hasData = function() return drive.data end,
    getMountPath = function() return "disk" end,
}

local SD = require("shipdisk")

-- ---------------------------------------------------------------- ship A
files["config/ArtAtlas.lua"] = "return { name = 'ArtAtlas' }"
files["config/assignments_ArtAtlas.lua"] = "return { aux_relay = 'redstone_relay_8' }"
files["v2/data/learned.lua"] = "return { hover = 6.9 }"
files["v2/data/atmos.lua"] = "return { band = 10, bands = {} }"
files["v2/data/waypoints.lua"] = "return { { name = 'REACTOR', x = 1, z = 2 } }"
files["v2/data/slot"] = "ArtAtlas"
files["v2/data/log.txt"] = "not part of a ship backup"

-- no drive / no floppy / blank floppy
have_drive = false
local n, why = SD.save("ArtAtlas", { ship = "ArtAtlas" })
check("no drive: says so", not n and why == "NO DISK DRIVE FOUND", why)
have_drive = true
drive.present = false
n, why = SD.save("ArtAtlas", { ship = "ArtAtlas" })
check("no floppy: says so", not n and why == "PUT A FLOPPY IN THE DRIVE", why)
drive.present = true
local m
m, why = SD.peek()
check("blank floppy: nothing to load", not m and why == "NO SHIP SAVED ON THIS DISK", why)

-- save
n, why = SD.save("ArtAtlas", { ship = "ArtAtlas", os = "v2.28" })
check("save: 6 ship files", n == 6, tostring(n) .. " " .. tostring(why))
check("save: config on disk", files["disk/artcorp_ship/config/ArtAtlas.lua"] ~= nil)
check("save: learned on disk", files["disk/artcorp_ship/v2/data/learned.lua"] == "return { hover = 6.9 }")
check("save: logs left out", files["disk/artcorp_ship/v2/data/log.txt"] == nil)
m = SD.peek()
check("save: manifest names the ship", m and m.ship == "ArtAtlas" and m.slot == "ArtAtlas" and m.os == "v2.28")
-- saving again replaces the old backup
files["v2/data/learned.lua"] = "return { hover = 7.1 }"
n = SD.save("ArtAtlas", { ship = "ArtAtlas" })
check("save again: replaced", n == 6 and files["disk/artcorp_ship/v2/data/learned.lua"] == "return { hover = 7.1 }")

-- ---------------------------------------------------------------- ship B
-- a different computer: other files, the floppy carried over
for k in pairs(files) do if k:sub(1, 5) ~= "disk/" then files[k] = nil end end
files["config/Other.lua"] = "return { name = 'Other' }"
files["v2/data/learned.lua"] = "return { hover = 5.0 }"
files["v2/data/slot"] = "Other"
m, why = SD.load()
check("load: ok", m and m.ship == "ArtAtlas", why)
check("load: config copied", files["config/ArtAtlas.lua"] == "return { name = 'ArtAtlas' }")
check("load: assignments copied", files["config/assignments_ArtAtlas.lua"] ~= nil)
check("load: learned copied", files["v2/data/learned.lua"] == "return { hover = 7.1 }")
check("load: slot now the loaded ship", files["v2/data/slot"] == "ArtAtlas")
check("load: replaced files kept", files["v2/data/before_disk/v2/data/learned.lua"] == "return { hover = 5.0 }"
    and files["v2/data/before_disk/v2/data/slot"] == "Other")

-- full floppy
cap = 300
for k in pairs(files) do if k:sub(1, 5) == "disk/" then files[k] = nil end end
n, why = SD.save("ArtAtlas", { ship = "ArtAtlas" })
check("full floppy: refused", not n and tostring(why):find("DISK FULL") ~= nil, why)

_G.fs, _G.peripheral, _G.disk, _G.textutils = saved.fs, saved.peripheral, saved.disk, saved.textutils
_G.loadfile = saved.loadfile
package.loaded["shipdisk"], package.loaded["util"] = nil, nil
print(string.format("v2_disk_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_disk_test FAILED", 0) end
