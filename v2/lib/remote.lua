-- v2 ArtCorp fleet remote: lets an ArtCorp handheld remote find this ship
-- over rednet and take it over. NO authentication by design -- every ArtCorp
-- remote works on every ArtCorp ship (ArtCorp policy; a stolen OS is still
-- ArtCorp's to shut down). Rides on the modems Link already opens.
--
-- Protocol "artcorp":
--   remote -> ship   { op = "scan" }
--   ship   -> remote { op = "here", id, name, slot, phase, locked, x, y, z, os,
--                       heading, speed, gear, ap = {name, phase, dist}, wps }
--   remote -> ship   { op = "cmd", cmd = <action>, x, z, idx }
--        action: estop   cut all lift now (it falls)
--                land    forced auto-land where it is, then power off
--                summon  uncancelable autopilot to x,z (come to me)
--                unlock  release the ArtCorp lock
--                goto    normal (cancelable) autopilot to the ship's own
--                        waypoint number idx (scan lists them in `wps`)
--   ship   -> remote { op = "ack", cmd, name, ok, why }   (why = refusal reason)
--   remote -> ship   { op = "wps" }        the ship's FULL waypoint list
--   ship   -> remote { op = "wps", id, name, list = { {i, name, x, z, heading, alt}, ... } }
--                    (i = the index `goto` takes; the scan only carries the
--                    first 16 names and the total in `nwps`)
--
-- main.lua wires the two handlers via Remote.init.
local Remote = { proto = "artcorp" }

-- h = { snapshot = function() return {name,slot,phase,locked,x,y,z,os} end,
--       onCommand = function(cmd) ... return shipName end,
--       waypoints = function() return { {name, x, z, heading, alt}, ... } end }
function Remote.init(h) Remote.h = h end

local function send(to, m)
    m.proto = Remote.proto
    pcall(rednet.send, to, m, Remote.proto)
end

function Remote.handle(sender, msg)
    if type(msg) ~= "table" or msg.proto ~= Remote.proto or not Remote.h then return end
    if msg.op == "scan" then
        local ok, s = pcall(Remote.h.snapshot)
        if not ok or type(s) ~= "table" then return end
        s.op, s.id = "here", (os.getComputerID and os.getComputerID()) or 0
        send(sender, s)
    elseif msg.op == "wps" then
        local list = {}
        local ok, wps = pcall(Remote.h.waypoints or function() return {} end)
        if ok and type(wps) == "table" then
            for i, w in ipairs(wps) do
                list[i] = { i = i, name = tostring(w.name), x = tonumber(w.x), z = tonumber(w.z),
                    heading = tonumber(w.heading), alt = tonumber(w.alt) }
            end
        end
        local myname
        pcall(function() myname = Remote.h.snapshot().name end)
        send(sender, { op = "wps", id = (os.getComputerID and os.getComputerID()) or 0,
            name = myname or "?", list = list })
    elseif msg.op == "cmd" then
        local cmd = { cmd = tostring(msg.cmd), x = tonumber(msg.x), z = tonumber(msg.z),
            idx = tonumber(msg.idx), by = sender }
        local ok, name, why = pcall(Remote.h.onCommand, cmd)
        local done = ok and name ~= false and name ~= nil
        local myname
        pcall(function() myname = Remote.h.snapshot().name end)
        send(sender, { op = "ack", cmd = cmd.cmd, name = myname or "?", ok = done,
            why = (not ok) and "ERROR" or (not done and (why or "REFUSED")) or nil })
    end
end

-- rednet_message event: (sender, message[, protocol])
function Remote.onRednet(sender, msg) Remote.handle(sender, msg) end

return Remote
