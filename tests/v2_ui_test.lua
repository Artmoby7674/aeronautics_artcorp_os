-- v2 UI tests: every screen renders without drawing errors, touches land on
-- the right actions, nothing overlaps the tab bar, quiet frames are cheap.
package.path = "./tests/v2/?.lua;" .. package.path
package.loaded.scene = nil
local SC = dofile("tests/v2/scene.lua").new()
local UI = require("ui")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

local W, H = SC.mon.W, SC.mon.H
local TAB_Y = H - 20
local worlds = { cruise = SC.cruise(), hover = SC.hover(), parked = SC.parked() }

local function frame(world, tab, extra)
    SC.ui:setTab(tab)
    SC.ui:invalidate()
    SC.ui:render(SC.base(world, extra))
end

-- splash + boot
SC.ui:render({ power = "off", name = "Atlas", fl = worlds.parked.fl, missing = { "aux_relay" } })
check("splash: START button", SC.ui:touch(W / 2, 128) == "boot", SC.ui:touch(W / 2, 128))
SC.ui:render({ power = "booting", boot_frac = 0.4, boot_step = "STARTER", name = "Atlas", fl = worlds.parked.fl, missing = {} })
check("booting: no touch targets", SC.ui:touch(W / 2, 128) == nil)
SC.ui.screen = nil

for _, wname in ipairs({ "cruise", "hover", "parked" }) do
    for _, t in ipairs(UI.TABS) do
        SC.mon.errors = {}
        local ok, err = pcall(frame, worlds[wname], t.id, { rec = true, rec_t = 61, rec_n = 12,
            alerts = { { level = "warn", text = "LOW LIFT MARGIN", hint = "1.0/15" } } })
        check("render " .. wname .. "/" .. t.id, ok, err)
        check("no draw errors " .. wname .. "/" .. t.id, #SC.mon.errors == 0, SC.mon.errors[1])
        for _, h in ipairs(SC.ui.hits) do
            if not h.action:match("^tab:") or t.id == "auto" then
                local inside = h.x >= 0 and h.y >= 0 and h.x + h.w <= W and (h.y + h.h <= TAB_Y or h.action:match("^tab:"))
                check("hit area clear of the tab bar " .. t.id .. " " .. h.action, inside,
                    string.format("%d,%d %dx%d", h.x, h.y, h.w, h.h))
            end
        end
        -- quiet frame: nothing changed, almost nothing redrawn
        local before = SC.mon.calls
        SC.ui:render(SC.base(worlds[wname], { rec = true, rec_t = 61, rec_n = 12,
            alerts = { { level = "warn", text = "LOW LIFT MARGIN", hint = "1.0/15" } } }))
        check("retained redraw " .. wname .. "/" .. t.id, SC.mon.calls - before <= 3, SC.mon.calls - before)
    end
end

-- tab bar touches
local tw = math.floor(W / #UI.TABS)
for i, t in ipairs(UI.TABS) do
    check("tab touch " .. t.id, SC.ui:touch((i - 1) * tw + tw / 2, H - 8) == "tab:" .. t.id)
end

-- touch coordinates from monitor cells (6x9 px) reach every CTRL button
frame(worlds.hover, "ctrl")
local seen = {}
for cy = 1, math.floor(H / 9) do
    for cx = 1, math.floor(W / 6) do
        local a = SC.ui:touch((cx - 1) * 6 + 3, (cy - 1) * 9 + 4)
        if a then seen[a] = true end
    end
end
for _, a in ipairs({ "ctl:land", "ctl:gear", "ctl:mode", "ctl:estop", "ctl:hold", "ctl:rec", "ctl:print", "ctl:landoff", "ctl:power" }) do
    check("ctrl reachable by cell touch: " .. a, seen[a])
end

-- SHIP tab opens the SLOTS sub-screen; it lists the slots and keeps SHIP lit
frame(worlds.parked, "ship")
local slotsBtn
for _, h in ipairs(SC.ui.hits) do if h.action == "ship:slots" then slotsBtn = h end end
check("ship: SLOTS button", slotsBtn ~= nil)
check("ship: RESET still there", (function()
    for _, h in ipairs(SC.ui.hits) do if h.action == "ship:reset" then return true end end
end)())
do
    local SLOTS = { { id = "atlas", wired = true }, { id = "ship2", wired = false } }
    for i = 3, 9 do SLOTS[i] = { id = "spare" .. i, wired = true } end
    SC.ui.slot_sel, SC.ui.slot_scroll = 2, 0
    SC.mon.errors = {}
    local ok, err = pcall(frame, worlds.parked, "slots", { slots = SLOTS, slot = "atlas", confirm = "slot:del:ship2" })
    check("slots: renders", ok, err)
    check("slots: no draw errors", #SC.mon.errors == 0, SC.mon.errors[1])
    local acts = {}
    for _, h in ipairs(SC.ui.hits) do
        acts[h.action] = h
        if not h.action:match("^tab:") then
            check("slots: hit clear of the tab bar " .. h.action, h.x >= 0 and h.x + h.w <= W and h.y + h.h <= TAB_Y,
                string.format("%d,%d %dx%d", h.x, h.y, h.w, h.h))
        end
    end
    for _, a in ipairs({ "slot:back", "slot:use", "slot:new", "slot:del", "slot:up", "slot:down", "slot:row:0", "slot:row:6" }) do
        local h = acts[a]
        check("slots: touch " .. a, h and SC.ui:touch(h.x + h.w / 2, h.y + h.h / 2) == a)
    end
    check("slots: SHIP stays lit in the tab bar", SC.ui:barTab() == "ship")
    check("slots: not in the bottom tab bar", (function()
        for _, t in ipairs(UI.TABS) do if t.id == "slots" then return false end end
        return true
    end)())
    local before = SC.mon.calls
    SC.ui:render(SC.base(worlds.parked, { slots = SLOTS, slot = "atlas", confirm = "slot:del:ship2" }))
    check("slots: retained redraw", SC.mon.calls - before <= 3, SC.mon.calls - before)
    -- no list (main never opened it): still draws
    SC.mon.errors = {}
    local ok2 = pcall(frame, worlds.parked, "slots", {})
    check("slots: renders without a list", ok2 and #SC.mon.errors == 0, SC.mon.errors[1])
    SC.ui.slot_sel, SC.ui.slot_scroll = nil, nil
end

-- the "?" in the top bar replays the tour
frame(worlds.parked, "fly")
check("top bar: ? starts the tour", SC.ui:touch(W - 6, 6) == "tour:start", SC.ui:touch(W - 6, 6))

-- the tour: every step on the engines-off ship (where it first shows)
do
    local ui = SC.ui
    local D = SC.D
    local m = SC.base(worlds.parked, { power = "off" })
    ui:setTab("nav")
    ui:tourStart()
    check("tour: no taps before it is drawn", ui:touch(W / 2, 128) == nil)
    local overlap = function(a, b)
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
    end
    for i, st in ipairs(UI.TOUR) do
        SC.mon.errors = {}
        local ok, err = pcall(ui.render, ui, m)
        check("tour " .. i .. ": renders", ok, err)
        check("tour " .. i .. ": no draw errors", #SC.mon.errors == 0, SC.mon.errors[1])
        local t = ui.tour
        local r = t and t.rect
        check("tour " .. i .. ": element found on screen", r and r.w > 0 and r.h > 0 and r.x >= 0 and r.x + r.w <= W
            and r.y >= 0 and r.y + r.h <= H and r.h < H - 40, r and string.format("%d,%d %dx%d", r.x, r.y, r.w, r.h))
        local acts, pop = {}, nil
        for _, h in ipairs(t and t.hits or {}) do
            acts[h.action] = h
            check("tour " .. i .. ": button on screen " .. h.action, h.x >= 0 and h.y >= 0 and h.x + h.w <= W and h.y + h.h <= H)
            check("tour " .. i .. ": button clear of the element " .. h.action, not overlap(h, r))
        end
        check("tour " .. i .. ": NEXT and SKIP only", acts["tour:next"] and acts["tour:skip"] and #t.hits == 2)
        -- dimmed around the element, bright inside it
        local fb = SC.mon.fb
        local inside = fb[(r.y + math.floor(r.h / 2)) * W + r.x + math.floor(r.w / 2)]
        check("tour " .. i .. ": element stays bright", inside < 16, inside)
        local dimmed, total = 0, 0
        for y = 0, H - 1, 7 do
            for x = 0, W - 1, 7 do
                local p = { x = x, y = y, w = 1, h = 1 }
                if not overlap(p, { x = r.x - 3, y = r.y - 3, w = r.w + 6, h = r.h + 6 }) then
                    local hitPop = false
                    for _, h in ipairs(t.hits) do if overlap(p, h) then hitPop = true end end
                    if not hitPop then
                        total = total + 1
                        if fb[y * W + x] >= 16 then dimmed = dimmed + 1 end
                    end
                end
            end
        end
        check("tour " .. i .. ": the rest is dimmed", dimmed / total > 0.6, string.format("%d/%d", dimmed, total))
        -- a tap on the element itself (or anywhere off the popup) does nothing
        check("tour " .. i .. ": tap on the element blocked", ui:touch(r.x + 1, r.y + 1) == nil)
        local before = SC.mon.calls
        ui:render(m)
        check("tour " .. i .. ": quiet frame cheap", SC.mon.calls - before <= 3, SC.mon.calls - before)
        local h = acts["tour:next"]
        check("tour " .. i .. ": NEXT reachable", h and ui:touch(h.x + 2, h.y + 2) == "tour:next")
        local done = ui:tourNext()
        check("tour " .. i .. ": last NEXT ends it", done == (i == #UI.TOUR))
    end
    check("tour: over, back on the tab it started from", ui.tour == nil and ui.tab == "nav", ui.tab)
    ui:invalidate()
    ui:render(SC.base(worlds.parked))
    check("tour: normal taps back", ui:touch(W - 6, 6) == "tour:start")
    -- SKIP ends it on any step; the splash comes back when the engines are off
    ui:tourStart()
    ui:render(m)
    ui:tourNext()
    ui:render(m)
    ui:tourEnd()
    ui:render(m)
    check("tour: after it the splash is back", ui:touch(W / 2, 128) == "boot", ui:touch(W / 2, 128))
    -- 16-colour monitors: dimming falls back to darker colours of the 16
    check("dim colours: every colour has a darker one", (function()
        for _, c in pairs(D.C) do if D.dim_map[c] == nil then return false end end
        return true
    end)())
end

-- first-launch setup screens
do
    local ui = SC.ui
    local roleOb = { screen = "role", rev = 1, idx = 3, total = 10, scroll = 0, sel = 2, msg = "TESTING RELAY_AUX",
        role = { key = "aux_relay", label = "AUX RELAY", type = "redstone_relay", optional = true, test_label = "TEST",
            desc = "MOVES THE LANDING GEAR, READS THE GROUND SENSOR AND THE SHIFT KEY." },
        cands = { { name = "relay_1", used = true, tag = "USED: KEYS W A S D" }, { name = "relay_aux" }, { name = "relay_eng" } } }
    local screens = {
        welcome = { screen = "welcome", rev = 1, msg = "NO DISK DRIVE FOUND" },
        role = roleOb,
        empty = { screen = "role", rev = 1, idx = 10, total = 10, scroll = 0, cands = {},
            role = { key = "main_monitor", label = "COCKPIT SCREEN", type = "monitor", test_label = "SHOW", desc = "X" } },
        guide = { screen = "guide", rev = 1, gi = 4, gn = 4, card = { title = "HOVER HANDS-OFF", text = string.rep("WORDS ", 40) } },
        busy = { screen = "busy", rev = 1, title = "SHIP LOADED", msg = "RESTARTING ON CARGO..." },
    }
    local want = {
        welcome = { "ob:import", "ob:setup" },
        role = { "ob:back", "ob:test", "ob:skip", "ob:next", "ob:up", "ob:down", "ob:row:0", "ob:row:5" },
        empty = { "ob:back", "ob:test" },
        guide = { "ob:gskip", "ob:gback", "ob:gnext" },
        busy = {},
    }
    for name, ob in pairs(screens) do
        SC.mon.errors = {}
        ui.screen = nil
        local ok, err = pcall(ui.render, ui, { ob = ob })
        check("setup " .. name .. ": renders", ok, err)
        check("setup " .. name .. ": no draw errors", #SC.mon.errors == 0, SC.mon.errors[1])
        local acts = {}
        for _, h in ipairs(ui.hits) do
            acts[h.action] = true
            check("setup " .. name .. ": on screen " .. h.action, h.x >= 0 and h.y >= 0 and h.x + h.w <= W and h.y + h.h <= H)
            check("setup " .. name .. ": no tab under it " .. h.action, not h.action:match("^tab:"))
        end
        for _, a in ipairs(want[name]) do check("setup " .. name .. ": has " .. a, acts[a]) end
        local before = SC.mon.calls
        ui:render({ ob = ob })
        check("setup " .. name .. ": quiet frame free", SC.mon.calls == before)
    end
    check("wrap: lines fit", (function()
        for _, l in ipairs(UI.wrap(string.rep("ABCDEFG ", 30), 20)) do if #l > 20 then return false end end
        return #UI.wrap("A VERYVERYVERYLONGWORDINDEED", 10) == 4
    end)())
    ui.screen = nil
end

-- the palette is set on init
check("palette applied", SC.mon.palette[0] ~= nil and SC.mon.palette[15] ~= nil)

-- monitor WITHOUT CC:Graphics methods: drawing must go through term.redirect
do
    local D = SC.D
    local real = SC.mon
    local plain = {
        setTextScale = function() end,
        getSize = real.getSize,
        setBackgroundColor = function() end, clear = function() end,
        setCursorPos = function() end, setTextColor = function() end, write = function() end,
    }
    local target = nil
    local savedTerm = term
    term = {
        redirect = function(t) local o = target target = t return o end,
        setGraphicsMode = function(m) assert(target == plain, "not redirected") return real.setGraphicsMode(m) end,
        drawPixels = function(...) assert(target == plain, "not redirected") return real.drawPixels(...) end,
        setFrozen = function(...) return real.setFrozen(...) end,
        setPaletteColor = function(...) return real.setPaletteColor(...) end,
        nativePaletteColour = function() return 0, 0, 0 end,
    }
    real.errors = {}
    local ok = D.init(plain, true)
    check("redirect path: init ok", ok and D.path == "redirect", tostring(D.path))
    local before = real.calls
    local rok, rerr = pcall(frame, worlds.hover, "ctrl")
    check("redirect path: renders", rok and real.calls > before, rerr)
    check("redirect path: no draw errors", #real.errors == 0, real.errors[1])
    check("redirect path: taps work", SC.ui:touch(W / 2, H - 8) ~= nil)
    check("redirect path: terminal restored", target == nil)
    -- no graphics at all: init reports failure (and v2 runs headless)
    term = { redirect = function(t) return nil end, nativePaletteColour = term.nativePaletteColour }
    _G.colors = { black = 32768, red = 16384, white = 1 }
    check("no graphics: init fails cleanly", D.init(plain, true) == false)
    term = savedTerm
    D.init(real, true)
end

print(string.format("v2_ui_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_ui_test FAILED", 0) end
