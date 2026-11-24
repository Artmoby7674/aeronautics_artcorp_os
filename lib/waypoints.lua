-- Waypoint storage: config/wp_<slot>.lua next to the config it belongs to.
-- Entries: { name = "...", x = <number>, z = <number>, heading = <deg>,
--           alt = <number|nil> }. alt is optional: when omitted, the autopilot
-- climbs to the operating ceiling (y250 minimum flight height, then as high as the lift props
-- stay above 13) and cruises the whole leg there. Give alt to pin an exact
-- height instead -- an explicit value is honoured and is not treated as a
-- ceiling request.

local WP = {}

WP.list = {}
local path = nil

local function buildPath(slot)
    return "config/wp_" .. tostring(slot or "ship") .. ".lua"
end

local function fmtNum(v)
    return tostring(tonumber(v) or 0)
end

local function wrapHeading(h)
    return ((tonumber(h) or 0) % 360 + 360) % 360
end

function WP.load(slot)
    path = buildPath(slot)
    WP.list = {}
    if fs.exists(path) then
        local ok, data = pcall(function()
            local fn = loadfile(path)
            if fn then return fn() end
        end)
        if ok and type(data) == "table" then
            for _, w in ipairs(data) do
                if type(w) == "table" and w.name and w.x and w.z then
                    local alt = tonumber(w.alt)
                    if alt ~= alt then alt = nil end   -- NaN guard
                    WP.list[#WP.list + 1] = {
                        name = tostring(w.name),
                        x = tonumber(w.x) or 0,
                        z = tonumber(w.z) or 0,
                        heading = wrapHeading(w.heading),
                        alt = alt,
                    }
                end
            end
        end
    end
    return #WP.list
end

-- Writes the whole list. Returns false if the file could not be written
-- (most often: the computer's disk is full), so callers can roll back
-- instead of reporting a save that never happened.
function WP.save()
    if not path then return false end
    local lines = { "return {" }
    for _, w in ipairs(WP.list) do
        local alt = w.alt and (", alt = " .. fmtNum(w.alt)) or ""
        lines[#lines + 1] = string.format("  { name = %q, x = %s, z = %s, heading = %s%s },",
            tostring(w.name), fmtNum(w.x), fmtNum(w.z), tostring(wrapHeading(w.heading)), alt)
    end
    lines[#lines + 1] = "}"
    local ok = pcall(function()
        local f = fs.open(path, "w")
        if not f then error("open failed") end
        f.write(table.concat(lines, "\n") .. "\n")
        f.close()
    end)
    return ok
end

function WP.add(wp)
    if type(wp) ~= "table" or not wp.name or not wp.x or not wp.z then
        return nil, "BAD WAYPOINT"
    end
    local alt = tonumber(wp.alt)
    if alt ~= alt then alt = nil end       -- NaN guard
    WP.list[#WP.list + 1] = {
        name = tostring(wp.name),
        x = tonumber(wp.x) or 0,
        z = tonumber(wp.z) or 0,
        heading = wrapHeading(wp.heading),
        alt = alt,
    }
    if not WP.save() then
        table.remove(WP.list) -- keep memory in step with the file
        return nil, "SAVE FAILED"
    end
    return #WP.list
end

function WP.remove(i)
    if type(i) ~= "number" or not WP.list[i] then return false end
    local removed = table.remove(WP.list, i)
    if not WP.save() then
        table.insert(WP.list, i, removed)
        return false
    end
    return true
end

return WP
