-- ArtCorpOS network keyboard
-- Run this on a plain computer that is on the same (modem) network as the
-- ship computer. It pairs automatically: the ship asks, this computer shows
-- the prompts, answers go straight back and the ship CONFIRMS them (ack) -
-- retries + a loud message if no confirmation arrives.

local PROTO = "artkbd"
local RAW_CH = 39999 -- kbd->ship raw channel (rednet's dedup can eat
                     -- packets - see lib/kbd.lua header for why)

local modems = {}
for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name) or ""
    if t:find("modem") then
        modems[#modems + 1] = name
    end
end
if #modems == 0 then
    print("No modem found - attach one to this computer and re-run kbd.")
    return
end
for _, name in ipairs(modems) do
    rednet.open(name)
end

-- send on the raw channel over every modem we have; payload is a plain
-- serialized string (the "texting app" approach - simplest possible form)
local function rawSend(msg)
    msg.proto = PROTO
    msg.src = os.getComputerID()
    local payload = textutils.serialize(msg)
    local sent = false
    for _, name in ipairs(modems) do
        if pcall(peripheral.call, name, "transmit", RAW_CH, RAW_CH, payload) then
            sent = true
        end
    end
    return sent
end

local ship_out = nil -- last packet FROM the ship (ping/ask/hi)
local ship_in = nil  -- last proof our packets REACHED the ship (hi/ack/nack)
local busy = false
local error_shown = false -- keep ASK ERROR on screen (pings must not wipe it)

local function drawHeader()
    if busy then return end
    term.setCursorPos(1, 1)
    term.clear() -- wipe stale result lines too (avoids appended garbage)
    if term.isColor() then term.setTextColor(colors.white) end
    write("ArtCorpOS keyboard   ")
    local out_age = ship_out and (os.clock() - ship_out)
    local in_age = ship_in and (os.clock() - ship_in)
    if not out_age then
        if term.isColor() then term.setTextColor(colors.yellow) end
        write("waiting for ship...")
    elseif out_age > 15 then
        if term.isColor() then term.setTextColor(colors.red) end
        write("ship NOT heard for " .. math.floor(out_age) ..
            "s (modem/cable?)")
    elseif in_age and in_age <= 15 then
        if term.isColor() then term.setTextColor(colors.green) end
        write("ship: online")
    else
        -- ship->kbd works (pings arrive) but nothing we sent got a reply
        if term.isColor() then term.setTextColor(colors.red) end
        write("ONE-WAY link: kbd->ship NOT working?")
    end
    if term.isColor() then term.setTextColor(colors.white) end
    print("")
end

local function validate(kind, v)
    if kind == "number" then
        if not tonumber(v) then return false, "not a number" end
    elseif kind == "name" then
        if v == "" or #v > 10 or not v:match("^%w+$") then
            return false, "1-10 letters/digits"
        end
    end
    return true
end

-- Wait for the ship to confirm our answers. Returns "ack" | "nack", why |
-- nil (timeout) | "interrupt" (a new ask arrived - caller must stop).
local function waitConfirm(rid, secs)
    local t = os.startTimer(secs)
    while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "timer" and a == t then
            os.cancelTimer(t)
            return nil
        elseif ev == "rednet_message" and type(b) == "table"
            and b.proto == PROTO then
            if b.op == "ping" or b.op == "hi" or b.op == "ask" then
                ship_out = os.clock()
            end
            if b.op == "hi" then
                ship_in = os.clock()
            end
            if (b.op == "ack" or b.op == "nack") and b.rid == rid then
                ship_out = os.clock()
                ship_in = os.clock()
                os.cancelTimer(t)
                if b.op == "ack" then return "ack" end
                return "nack", tostring(b.why or "?")
            elseif b.op == "ask" then
                os.queueEvent(ev, a, b, c) -- let the main loop handle it
                os.cancelTimer(t)
                return "interrupt"
            end
        end
    end
end

local function handleAsk(sender, msg)
    ship_out = os.clock()
    term.clear()
    term.setCursorPos(1, 1)
    print("SHIP REQUEST")
    print("")
    local values = {}
    for i, f in ipairs(msg.prompts or {}) do
        -- tell the ship which field we are on (status line on the monitor)
        rawSend({ op = "progress", rid = msg.rid, idx = i })
        while true do
            write(tostring(f.label or "?") .. ": ")
            local v = tostring(read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
            print("  (got '" .. v .. "')") -- breadcrumb: read() returned
            local ok, err = validate(f.kind, v)
            if ok then
                values[i] = v
                break
            end
            print(err)
        end
    end

    -- visible breadcrumbs: the screen must say something the moment the
    -- last field is confirmed, so we always know how far the flow got
    print("")
    print("Sending to ship...")
    local result, why
    for attempt = 1, 3 do
        if attempt > 1 then
            print("No confirmation - retry " .. attempt .. "/3 ...")
        end
        local sent = rawSend({ op = "answers", rid = msg.rid,
            values = values })
        if not sent then
            result = "sendfail"
            break
        end
        result, why = waitConfirm(msg.rid, attempt == 1 and 3 or 1.5)
        if result then break end
    end

    term.clear()
    term.setCursorPos(1, 1)
    drawHeader()
    if result == "ack" then
        if term.isColor() then term.setTextColor(colors.green) end
        print("Confirmed by ship.")
        if term.isColor() then term.setTextColor(colors.white) end
    elseif result == "nack" then
        if term.isColor() then term.setTextColor(colors.red) end
        print("Ship rejected: " .. tostring(why))
        print("Tap QUICK WP on the monitor to try again.")
        if term.isColor() then term.setTextColor(colors.white) end
    elseif result == "sendfail" then
        if term.isColor() then term.setTextColor(colors.red) end
        print("SEND FAILED (modem not open?) - check the modem.")
        if term.isColor() then term.setTextColor(colors.white) end
    elseif result == "interrupt" then
        print("New request incoming...")
    else
        if term.isColor() then term.setTextColor(colors.red) end
        print("Ship did NOT confirm (3 tries).")
        print("Check the ship's terminal kbd log / modem cable.")
        if term.isColor() then term.setTextColor(colors.white) end
    end
end

term.clear()
term.setCursorPos(1, 1)
drawHeader()
print("Waiting for the ship computer...")
rawSend({ op = "hello" })
rednet.broadcast({ proto = PROTO, op = "hello" }, PROTO)
local hello_timer = os.startTimer(3)

while true do
    local ev, a, b = os.pullEvent()
    if ev == "timer" and a == hello_timer then
        rawSend({ op = "hello" })
        rednet.broadcast({ proto = PROTO, op = "hello" }, PROTO)
        hello_timer = os.startTimer(3)
        if not error_shown then drawHeader() end -- refresh link status
    elseif ev == "rednet_message" then
        local sender, msg = a, b
        if type(msg) == "table" and msg.proto == PROTO then
            if msg.op == "ping" or msg.op == "ask" or msg.op == "hi" then
                ship_out = os.clock()
            end
            if msg.op == "hi" or msg.op == "ack" or msg.op == "nack" then
                ship_in = os.clock()
            end
            if msg.op == "ping" or msg.op == "hi"
                or msg.op == "ack" or msg.op == "nack" then
                if not error_shown then drawHeader() end
            elseif msg.op == "ask" and not busy then
                busy = true
                error_shown = false
                local hok, herr = pcall(handleAsk, sender, msg)
                busy = false
                if not hok then
                    -- never swallow the failure silently again
                    error_shown = true
                    term.setCursorPos(1, 1)
                    term.clear()
                    if term.isColor() then term.setTextColor(colors.red) end
                    print("ASK ERROR (please report this):")
                    print(tostring(herr))
                    if term.isColor() then term.setTextColor(colors.white) end
                end
                -- read()/waitConfirm may have swallowed the hello timer
                hello_timer = os.startTimer(3)
            end
        end
    end
end
