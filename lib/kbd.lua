-- Ship-side client for the network keyboard computer (kbd.lua runs on a
-- plain computer attached to the same modem network).
--
-- keyboard -> ship travels on a RAW modem channel (RAW_CH) that rednet
-- never touches: rednet's receive side dedups by a math.random message id
-- that is generated from an UNSEEDED rng - identical across computers -
-- and every send() pre-registers its own id, so the ship could reject the
-- keyboard's packets as duplicates it "already received" (observed as a
-- permanent one-way link). Raw channel = no dedup, no rednet filter.
--
-- ship -> keyboard stays on rednet (that direction is proven working):
--   ship -> keyboard: { op = "ping" }                (every few seconds)
--   ship -> keyboard: { op = "hi" }                  (reply to hello)
--   ship -> keyboard: { op = "ask", rid, prompts }   (prompts = {label, kind})
--   ship -> keyboard: { op = "ack"|"nack", rid }     (answers confirmed or
--                                                     rejected, with why)
-- keyboard -> ship (raw): { op = "hello" | "progress" | "answers", ... }

local PROTO = "artkbd"
local RAW_CH = 39999 -- dedicated kbd->ship channel (not a rednet channel)
local TIMEOUT = 300 -- seconds before an ask gives up (typing can be slow)

local Kbd = {
    id = nil,      -- paired keyboard computer id
    pending = nil, -- { rid, labels, idx, started, cb }
    _rid = 0,
    _opened = {},  -- modem names already opened
    _last = nil,   -- { text, t } last event for the HUD status line
    _notice = nil, -- { text, t } drop/reject note appended to the prompt
    rx_rednet = 0, -- artkbd packets received over rednet
    rx_raw = 0,    -- artkbd packets received on RAW_CH
    rx_modem = 0,  -- ALL modem_message events seen (any channel)
}

local function log(msg)
    print(string.format("[%02.0f] kbd: %s", os.clock(), msg))
end

local function setLast(text)
    Kbd._last = { text = text, t = os.clock() }
end

local function setNotice(text)
    Kbd._notice = { text = text, t = os.clock() }
end

-- HUD line shown while no ask is pending; only fresh events (<= 15 s).
function Kbd.lastInfo()
    local l = Kbd._last
    if l and os.clock() - l.t <= 15 then return l.text end
    return nil
end

-- Open every modem we can find (wired or wireless); idempotent, also
-- retried when peripherals attach later. Also opens RAW_CH so the raw
-- kbd->ship channel delivers modem_message events.
function Kbd.openNet()
    local found = false
    for _, name in ipairs(peripheral.getNames()) do
        local t = peripheral.getType(name) or ""
        if t:find("modem") and not Kbd._opened[name] then
            local ok = pcall(rednet.open, name)
            if ok then
                local rok = pcall(peripheral.call, name, "open", RAW_CH)
                if rok then Kbd._raw_ok = true end
                Kbd._opened[name] = true
                found = true
            else
                Kbd._opened[name] = nil -- retry next call; never store false
            end
        end
    end
    return found or next(Kbd._opened) ~= nil
end

-- receive counters for the boot print / diagnostics
function Kbd.stats()
    return string.format("rx rednet=%d raw=%d modem=%d raw_ch=%s",
        Kbd.rx_rednet, Kbd.rx_raw, Kbd.rx_modem,
        Kbd._raw_ok and "open" or "FAILED")
end

-- modem_message dispatcher (called from the os_main event loop).
-- Counts ALL modem traffic, then feeds raw-channel artkbd packets into
-- the normal message handler. Payloads are plain serialized strings
-- (texting-app style) but tables are accepted too.
function Kbd.onModemRaw(modem, channel, reply, message)
    Kbd.rx_modem = Kbd.rx_modem + 1
    if channel ~= RAW_CH then return end
    Kbd.rx_raw = Kbd.rx_raw + 1
    if type(message) == "string" then
        local ok, m = pcall(textutils.unserialize, message)
        if ok and type(m) == "table" then message = m end
    end
    if type(message) ~= "table" or message.proto ~= PROTO then
        local preview = type(message) == "string"
            and message:sub(1, 40) or type(message)
        log("raw unparseable (" .. type(message) .. "): " .. tostring(preview))
        setLast("KBD: raw garbage received")
        return
    end
    local sender = tonumber(message.src) or tonumber(reply) or -1
    log("raw op=" .. tostring(message.op) .. " from #" .. tostring(sender))
    Kbd.onMessage(sender, message, "raw")
end

function Kbd.available()
    Kbd.openNet()
    return Kbd.id ~= nil
end

-- fields: { { label, kind }, ... } with kind = "number" | "name".
-- cb(values, err): values = { ... } on success, err on cancel/timeout.
function Kbd.ask(fields, cb)
    if not Kbd.openNet() then return false, "NO MODEM" end
    if not Kbd.id then return false, "NO KEYBOARD FOUND" end
    if Kbd.pending then return false, "KEYBOARD BUSY" end

    local prompts, labels = {}, {}
    for i, f in ipairs(fields or {}) do
        prompts[i] = { label = tostring(f[1] or "?"), kind = tostring(f[2] or "text") }
        labels[i] = prompts[i].label
    end
    if #prompts == 0 then return false, "NO FIELDS" end

    Kbd._rid = Kbd._rid + 1
    Kbd._notice = nil -- stale drop notes from a previous ask
    Kbd.pending = {
        rid = Kbd._rid,
        labels = labels,
        idx = 1,
        started = os.clock(),
        cb = cb,
    }
    local sent = rednet.send(Kbd.id, { proto = PROTO, op = "ask",
        rid = Kbd._rid, prompts = prompts }, PROTO)
    if not sent then
        Kbd.pending = nil
        log("ask #" .. Kbd._rid .. " SEND FAILED (no open modem?)")
        setLast("KBD: send failed (modem?)")
        return false, "SEND FAILED (MODEM?)"
    end
    log("ask #" .. Kbd._rid .. " sent to #" .. tostring(Kbd.id))
    setLast("KBD: ask sent to #" .. tostring(Kbd.id))
    return true
end

function Kbd.promptText()
    local p = Kbd.pending
    if not p then return nil end
    local text = "KBD: enter " .. tostring(p.labels[p.idx] or "?") ..
        " (tap to cancel)"
    local n = Kbd._notice
    if n and os.clock() - n.t <= 15 then
        text = text .. " | " .. n.text -- e.g. a dropped reply: never hidden
    end
    return text
end

function Kbd.isPending()
    return Kbd.pending ~= nil
end

function Kbd.cancel(reason)
    local p = Kbd.pending
    if not p then return false end
    Kbd.pending = nil
    log("ask #" .. p.rid .. " cancelled: " .. tostring(reason))
    setLast("KBD: " .. tostring(reason))
    if p.cb then
        local ok, err = pcall(p.cb, nil, reason or "cancelled")
        if not ok then log("callback error: " .. tostring(err)) end
    end
    return true
end

function Kbd.tick(now)
    local p = Kbd.pending
    if p and now - p.started > TIMEOUT then
        Kbd.cancel("keyboard timeout")
    end
    -- Link heartbeat: lets the keyboard computer show Ship online/lost.
    Kbd._ping_t = Kbd._ping_t or 0
    if now - Kbd._ping_t >= 5 then
        Kbd._ping_t = now
        if Kbd.openNet() then
            Kbd._ping_warned = false
            rednet.broadcast({ proto = PROTO, op = "ping" }, PROTO)
        elseif not Kbd._ping_warned then
            Kbd._ping_warned = true
            log("ping SEND FAILED - no open modem?")
            setLast("KBD: no modem for ping")
        end
    end
end

function Kbd.onMessage(sender, msg, protocol)
    if type(msg) ~= "table" or msg.proto ~= PROTO then return end
    if protocol ~= "raw" then Kbd.rx_rednet = Kbd.rx_rednet + 1 end
    if msg.op == "hello" then
        if Kbd.id ~= sender then
            log("paired with computer #" .. tostring(sender))
            setLast("KBD: online #" .. tostring(sender))
            if Kbd.onPaired then pcall(Kbd.onPaired, sender) end
        end
        Kbd.id = sender
        -- reply so the keyboard can PROVE both link directions work
        rednet.send(sender, { proto = PROTO, op = "hi" }, PROTO)
    elseif msg.op == "ping" then
        -- our own heartbeat echoing back; nothing to do
    elseif msg.op == "progress" then
        local p = Kbd.pending
        if p and msg.rid == p.rid then
            p.idx = tonumber(msg.idx) or p.idx
        end
    elseif msg.op == "answers" then
        local p = Kbd.pending
        if not p then
            -- never drop silently: this is exactly the bug we are hunting
            log("answers from #" .. tostring(sender) .. " (rid " ..
                tostring(msg.rid) .. ") dropped: no pending ask")
            setLast("KBD: reply dropped - tap QUICK WP again")
            setNotice("REPLY DROPPED")
            rednet.send(sender, { proto = PROTO, op = "nack",
                rid = msg.rid, why = "no pending ask" }, PROTO)
            return
        end
        if msg.rid ~= p.rid then
            log("answers rid " .. tostring(msg.rid) .. " ~= pending #" ..
                p.rid .. " dropped")
            setLast("KBD: stale reply dropped - tap QUICK WP again")
            setNotice("STALE REPLY (tap again)")
            rednet.send(sender, { proto = PROTO, op = "nack",
                rid = msg.rid, why = "stale rid (ship has a newer ask)" }, PROTO)
            return
        end
        Kbd.pending = nil
        log("answers for ask #" .. p.rid .. " accepted")
        setLast("KBD: answers received")
        rednet.send(sender, { proto = PROTO, op = "ack", rid = p.rid }, PROTO)
        if p.cb then
            local ok, err = pcall(p.cb, msg.values)
            if not ok then
                log("callback error: " .. tostring(err))
                setLast("KBD: callback error (see terminal)")
            end
        end
    else
        log("unknown op from #" .. tostring(sender) .. ": " .. tostring(msg.op))
    end
end

function Kbd.reset()
    Kbd.id = nil
    Kbd.pending = nil
end

return Kbd
