-- v2 waypoints: v2/data/waypoints.lua, list of { name, x, z, heading }.
-- Headings are COMPASS degrees (0 = north, 90 = east). On first run the
-- original OS's config/wp_<slot>.lua is imported; it stored the Sable yaw
-- (0 = nose east, + = turned left), which is converted as 90 - yaw.
local U = require("util")

local Nav = { list = {} }

local path

function Nav.init(root, slot)
    path = root .. "/data/waypoints.lua"
    local t = U.loadTable(path)
    if t then
        Nav.list = t
        return
    end
    Nav.list = {}
    local old = U.loadTable("config/wp_" .. slot .. ".lua")
    for _, w in ipairs(old or {}) do
        if type(w.x) == "number" and type(w.z) == "number" then
            Nav.list[#Nav.list + 1] = {
                name = tostring(w.name or "WP"):upper():sub(1, 10),
                x = w.x, z = w.z,
                heading = U.wrap360(90 - (w.heading or 90)),
            }
        end
    end
    Nav.save()
end

function Nav.save()
    return U.saveTable(path, Nav.list)
end

function Nav.add(name, x, z, heading)
    name = tostring(name or ""):upper():gsub("[^%w]", ""):sub(1, 10)
    if name == "" then return false, "BAD NAME" end
    for _, w in ipairs(Nav.list) do
        if w.name == name then return false, "NAME TAKEN" end
    end
    local w = { name = name, x = x, z = z, heading = U.wrap360(heading or 0) }
    Nav.list[#Nav.list + 1] = w
    if not Nav.save() then
        table.remove(Nav.list)
        return false, "SAVE FAILED (DISK FULL?)"
    end
    return true, w
end

function Nav.remove(i)
    local w = table.remove(Nav.list, i)
    if not w then return false end
    if not Nav.save() then
        table.insert(Nav.list, i, w)
        return false, "SAVE FAILED"
    end
    return true
end

return Nav
