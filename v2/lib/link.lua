-- v2 keyboard link: talks to the unchanged kbd.lua on the keyboard computer.
-- Protocol (shared with the original OS):
--   kbd -> ship  raw modem channel 39999, serialized { proto="artkbd", op, src, ... }
--                op = hello | progress | answers
--   ship -> kbd  rednet protocol "artkbd": ping | hi | ask | ack | nack
local Link = { id = nil, pending = nil, rid = 0, opened = {} }

local PROTO, RAW = "artkbd", 39999
local TIMEOUT = 300

function Link.open()
    for _, n in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(n) or ""
        if ty:find("modem") and not Link.opened[n] then
            if pcall(rednet.open, n) then
                pcall(peripheral.call, n, "open", RAW)
                Link.opened[n] = true
            end
        end
    end
    return next(Link.opened) ~= nil
end

function Link.online()
    return Link.id ~= nil and Link.seen and os.clock() - Link.seen < 20
end

-- fields: { {label, kind}, ... }; cb(values) or cb(nil, why)
function Link.ask(fields, cb)
    if not Link.open() then return false, "NO MODEM" end
    if not Link.id then return false, "NO KEYBOARD" end
    if Link.pending then return false, "KEYBOARD BUSY" end
    Link.rid = Link.rid + 1
    local prompts = {}
    for i, f in ipairs(fields) do prompts[i] = { label = f[1], kind = f[2] } end
    Link.pending = { rid = Link.rid, labels = fields, idx = 1, t = os.clock(), cb = cb }
    if not rednet.send(Link.id, { proto = PROTO, op = "ask", rid = Link.rid, prompts = prompts }, PROTO) then
        Link.pending = nil
        return false, "SEND FAILED"
    end
    return true
end

function Link.prompt()
    local p = Link.pending
    if not p then return nil end
    return "KEYBOARD: " .. tostring(p.labels[p.idx] and p.labels[p.idx][1] or "?")
end

function Link.cancel(why)
    local p = Link.pending
    if not p then return end
    Link.pending = nil
    pcall(p.cb, nil, why or "CANCELLED")
end

function Link.tick(now)
    if Link.pending and now - Link.pending.t > TIMEOUT then Link.cancel("TIMEOUT") end
    if not Link.ping or now - Link.ping >= 5 then
        Link.ping = now
        if Link.open() then rednet.broadcast({ proto = PROTO, op = "ping" }, PROTO) end
    end
end

local function handle(sender, m)
    if type(m) ~= "table" or m.proto ~= PROTO then return end
    Link.seen = os.clock()
    if m.op == "hello" then
        Link.id = sender
        rednet.send(sender, { proto = PROTO, op = "hi" }, PROTO)
    elseif m.op == "progress" then
        local p = Link.pending
        if p and m.rid == p.rid then p.idx = tonumber(m.idx) or p.idx end
    elseif m.op == "answers" then
        local p = Link.pending
        if not p or m.rid ~= p.rid then
            rednet.send(sender, { proto = PROTO, op = "nack", rid = m.rid, why = "no matching ask" }, PROTO)
            return
        end
        Link.pending = nil
        rednet.send(sender, { proto = PROTO, op = "ack", rid = p.rid }, PROTO)
        pcall(p.cb, m.values)
    end
end

function Link.onRednet(sender, msg) handle(sender, msg) end

function Link.onModem(channel, reply, msg)
    if channel ~= RAW then return end
    if type(msg) == "string" then
        local ok, t = pcall(textutils.unserialize, msg)
        if ok then msg = t end
    end
    if type(msg) == "table" then handle(tonumber(msg.src) or reply, msg) end
end

return Link
