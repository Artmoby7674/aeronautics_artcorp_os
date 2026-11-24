-- v2 ArtCorp fleet remote: lets an ArtCorp handheld remote find this ship
-- over rednet and take it over. NO authentication by design -- every ArtCorp
-- remote works on every ArtCorp ship (ArtCorp policy; a stolen OS is still
-- ArtCorp's to shut down). Rides on the modems Link already opens.
--
-- Protocol "artcorp":
--   remote -> ship   { op = "scan" }
--   ship   -> remote { op = "here", id, name, slot, phase, locked, x, y, z, os }
--   remote -> ship   { op = "cmd", cmd = <action>, x, z }
--        action: estop   cut all lift now (it falls)
--                land    forced auto-land where it is, then power off
--                summon  uncancelable autopilot to x,z (come to me)
--                unlock  release the ArtCorp lock
--   ship   -> remote { op = "ack", cmd, name, ok }
--
-- main.lua wires the two handlers via Remote.init.
local Remote = { proto = "artcorp" }

-- h = { snapshot = function() return {name,slot,phase,locked,x,y,z,os} end,
--       onCommand = function(cmd) ... return shipName end }
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
    elseif msg.op == "cmd" then
        local cmd = { cmd = tostring(msg.cmd), x = tonumber(msg.x), z = tonumber(msg.z), by = sender }
        local ok, name = pcall(Remote.h.onCommand, cmd)
        send(sender, { op = "ack", cmd = cmd.cmd, name = ok and name or "?", ok = ok and name ~= false })
    end
end

-- rednet_message event: (sender, message[, protocol])
function Remote.onRednet(sender, msg) Remote.handle(sender, msg) end

return Remote
