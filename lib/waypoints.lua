-- Waypoint storage: config/wp_<slot>.lua next to the config it belongs to.
-- Entries: { name = "...", x = <number>, z = <number>, heading = <deg> }.

local WP = {}

WP.list = {}
local path = nil

local function buildPath(slot)
    return "config/wp_" .. tostring(slot or "ship") .. ".lua"
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
                    WP.list[#WP.list + 1] = {
                        name = tostring(w.name),
                        x = tonumber(w.x) or 0,
                        z = tonumber(w.z) or 0,
                        heading = ((tonumber(w.heading) or 0) % 360 + 360) % 360,
                    }
                end
            end
        end
    end
    return #WP.list
end

function WP.save()
    if not path then return false end
    local f = fs.open(path, "w")
    if not f then return false end
    f.writeLine("return {")
    for _, w in ipairs(WP.list) do
        f.writeLine(string.format("  { name = %q, x = %s, z = %s, heading = %s },",
            tostring(w.name), tostring(tonumber(w.x) or 0),
            tostring(tonumber(w.z) or 0),
            tostring(((tonumber(w.heading) or 0) % 360 + 360) % 360)))
    end
    f.writeLine("}")
    f.close()
    return true
end

function WP.add(wp)
    if type(wp) ~= "table" or not wp.name or not wp.x or not wp.z then
        return nil, "BAD WAYPOINT"
    end
    WP.list[#WP.list + 1] = {
        name = tostring(wp.name),
        x = tonumber(wp.x) or 0,
        z = tonumber(wp.z) or 0,
        heading = ((tonumber(wp.heading) or 0) % 360 + 360) % 360,
    }
    WP.save()
    return #WP.list
end

function WP.remove(i)
    if type(i) ~= "number" or not WP.list[i] then return false end
    table.remove(WP.list, i)
    WP.save()
    return true
end

return WP
