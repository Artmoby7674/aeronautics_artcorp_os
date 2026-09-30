-- HUD layout regression test: the REAL lib/hud.lua, driven headlessly.
--
-- WHY THIS EXISTS
-- The HUD is drawn for a fixed 348x216 panel and nothing in the compile or
-- unit-test path notices a control that has been pushed one row too far. A
-- layout bug here is invisible until someone flies with it, so this harness
-- records every draw call the HUD makes and checks the geometry:
--   * no content escapes the body rect (bottom edge or tab strip)
--   * no text collides with the CANCEL button
--   * no string is silently clipped by the font (Font.fit truncates quietly)
--   * CANCEL A/P appears on the A/P screen and on no other
--   * the phase indicator lights the cell matching the reported autopilot
--     phase, for every phase the state machine can produce
--
-- HOW IT WORKS
-- CC:Graphics is stubbed with a monitor that records drawPixels rects instead
-- of painting them, and Font.render/Font.fit are wrapped to capture the
-- strings. Two ordering details matter and are easy to get wrong:
--   * Font.render runs BEFORE the drawPixels that positions the glyph, so
--     glyphs are queued and paired with the following text op. A naive
--     "current op" pointer attributes every string to the PREVIOUS op.
--   * HUD.render hijacks the active tab when a run starts or stops, so each
--     scenario asserts the tab that was ACTUALLY rendered.
--
-- Run from repo root: lua5.4 tests/hud_test.lua

package.path = "./?.lua;" .. package.path

local W, H = 348, 216

local Font = dofile("lib/font.lua")
local origRender, origFit = Font.render, Font.fit
local queue, ops, texts = {}, {}, {}
Font.render = function(str, color, bg)
    queue[#queue + 1] = { str = str, truncated = false }
    return origRender(str, color, bg)
end
Font.fit = function(str, maxw)
    local fitted = origFit(str, maxw)
    if fitted ~= str and queue[#queue] then queue[#queue].truncated = true end
    return fitted
end
package.loaded["lib.font"] = Font

local mon = {}
function mon.setTextScale() end
function mon.setGraphicsMode() return true end
function mon.setFrozen() end
function mon.getSize() return math.floor(W / 6), math.floor(H / 9) end
function mon.drawPixels(px, py, a, b, c)
    if b == nil then -- (x, y, rows): a glyph
        local rec = table.remove(queue, 1) or { str = "<unpaired>", truncated = false }
        rec.x, rec.y = px, py
        rec.w, rec.h = Font.textWidth(rec.str), Font.height
        ops[#ops + 1] = { x = px, y = py, w = rec.w, h = rec.h, text = true }
        texts[#texts + 1] = rec
    else -- (x, y, color, w, h): a filled rect
        ops[#ops + 1] = { x = px, y = py, w = b, h = c, text = false }
    end
end
term = {}

local HUD = dofile("lib/hud.lua")
HUD.init(mon)

-- geometry, mirroring applyLayout() in lib/hud.lua
local BORDER, HEADER_H, STRIP_W = 2, 20, 72
local BODY_Y = BORDER + HEADER_H + 4
local BODY_H = H - BODY_Y - BORDER - 2
local BODY_END = BODY_Y + BODY_H
local STRIP_X = W - BORDER - STRIP_W
local CONTENT_X = BORDER + 4
local CONTENT_W = STRIP_X - CONTENT_X - 4
local CANCEL_W = math.min(150, CONTENT_W - 8)
local CANCEL_H = 22
local CANCEL_Y = BODY_Y + BODY_H - 26
local CELL_W, CELL_H, CELL_GAP = 20, 22, 4
local CELL_Y = BODY_Y + 14
local CELL_1_X = CONTENT_X

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL: %s%s", name,
            detail ~= nil and (" -- " .. tostring(detail)) or ""))
    end
end

-- The frame, header and tab strip legitimately touch the screen edges. The
-- strip whitelist is CONTAINMENT-based on purpose: an op that merely crosses
-- into the strip from the content side is content bleeding into the tabs and
-- must be reported, so only ops wholly inside the strip count as chrome.
local STRIP_X0 = STRIP_X - 3 -- drawChrome paints a 3px edge sliver at strip_x-3
local function isChrome(r)
    if r.y + r.h <= BODY_Y then return true end
    if r.x >= STRIP_X0 and r.x + r.w <= W - BORDER then return true end
    if r.x <= BORDER or r.x + r.w >= W - BORDER then return true end
    if r.y <= BORDER or r.y + r.h >= H - BORDER then return true end
    return false
end

local AP_BASE = {
    name = "NORTH FIELD", phase = "cruise", step = "turn", dist = 1247.3,
    progress = 0.42, eta = 204, speed = 6.1, paused = false,
    err = -4.1, heading = 95, alt = 280, goal_alt = 250, ceil = 450,
}

local function ap(over)
    local t = {}
    for k, v in pairs(AP_BASE) do t[k] = v end
    for k, v in pairs(over or {}) do t[k] = v end
    return t
end

local function status(o)
    o = o or {}
    return {
        mode = o.mode or "CRUISE", altitude = o.alt or 270, target_altitude = o.tgt or 280,
        pitch = 1.2, roll = 0.4, yaw = 92.3, heading_target = 95, heading_valid = true,
        speed = o.spd or 6.1, target_speed = 8, climb_rate = o.climb or 0.8,
        landed = false, gear_down = false, auto_land = false, proximity = 3,
        estop = false, unflip = false,
        position = { x = 120.5, y = 270, z = -43.2 },
        outputs = { speed = 13.7, FL_speed = 13.7, FR_speed = 13.7,
                    RL_speed = 13.7, RR_speed = 13.7 },
        ap = o.ap,
    }
end

local function frame(tab, st)
    HUD.setTab(tab)
    ops, texts, queue = {}, {}, {}
    HUD.render(mon, status(st), { features = {} }, "")
    return HUD.getTab()
end

-- The HUD keeps two pieces of module state that a test must account for:
--   * an AP transition latch (ap_shown) that only fires on nil<->table edges,
--     so a frame is needed with no run before the next start is a transition
--   * a static/content layer cache, so switching away and back (or forcing a
--     chrome redraw) is needed before the once-drawn numbers reappear
local function reset()
    HUD.setTab("flight")
    ops, texts, queue = {}, {}, {}
    HUD.render(mon, status({ ap = nil }), { features = {} }, "")
    HUD.markChromeDirty()
end

local function findText(str)
    for _, g in ipairs(texts) do
        if g.str == str then return g end
    end
    return nil
end

-- --- 1. layout fits, nothing collides, nothing clipped -----------------
local function audit(label, wantTab, reqTab, st, wantCancel)
    local got = frame(reqTab, st)
    check(label .. ": lands on the " .. wantTab .. " tab", got == wantTab,
        string.format("rendered %q", tostring(got)))

    local maxy, maxx = 0, 0
    for _, r in ipairs(ops) do
        if not isChrome(r) then
            maxy = math.max(maxy, r.y + r.h)
            maxx = math.max(maxx, r.x + r.w)
        end
    end
    check(label .. ": content stays above the bottom edge",
        maxy <= BODY_END, string.format("max y=%d, body ends %d", maxy, BODY_END))
    check(label .. ": content stays clear of the tab strip",
        maxx <= STRIP_X, string.format("max x=%d, content ends %d", maxx, STRIP_X))

    local cancel = findText("CANCEL A/P")
    if wantCancel then
        check(label .. ": has a CANCEL A/P button", cancel ~= nil)
        if cancel then
            local ex = CONTENT_X + math.floor((CANCEL_W - cancel.w) / 2)
            local ey = CANCEL_Y + math.floor((CANCEL_H - Font.height) / 2)
            check(label .. ": cancel glyph is centred in its button",
                math.abs(cancel.x - ex) <= 1 and math.abs(cancel.y - ey) <= 1,
                string.format("at (%d,%d), expected (~%d,~%d)",
                    cancel.x, cancel.y, ex, ey))
            check(label .. ": cancel button is on screen",
                CANCEL_Y + CANCEL_H <= BODY_END,
                string.format("ends %d, body ends %d", CANCEL_Y + CANCEL_H, BODY_END))
            local overlap
            for _, g in ipairs(texts) do
                if g ~= cancel and g.x < CONTENT_X + CANCEL_W and g.x + g.w > CONTENT_X
                   and g.y < CANCEL_Y + CANCEL_H and g.y + g.h > CANCEL_Y then
                    overlap = overlap or g.str
                end
            end
            check(label .. ": nothing overlaps the cancel button", overlap == nil, overlap)
        end
    else
        check(label .. ": no CANCEL A/P button", cancel == nil)
    end

    for _, g in ipairs(texts) do
        check(label .. ": " .. string.format("%q fits its slot", g.str),
            not g.truncated, string.format("at (%d,%d)", g.x, g.y))
        -- A glyph is content, so it must never reach into the tab strip even
        -- if some other check would have classified it as chrome.
        if g.x < STRIP_X and g.x + g.w > STRIP_X then
            check(label .. ": " .. string.format("%q stays clear of the tabs", g.str),
                false, string.format("spans %d..%d, strip starts %d",
                    g.x, g.x + g.w, STRIP_X))
        end
    end
end

audit("A/P cruise", "ap", "ap", { ap = ap() }, true)
audit("A/P climb", "ap", "ap", { ap = ap({ phase = "aim", step = "climb",
    dist = 3900, progress = 0.11, eta = 520, err = 41.2, speed = 0.4 }),
    mode = "HOVER", alt = 118, climb = 8.0, spd = 0.4 }, true)
audit("A/P align", "ap", "ap", { ap = ap({ phase = "align", step = nil,
    dist = 12, progress = 0.97, eta = 3, err = 0.2, paused = true }) }, true)
audit("A/P landing", "ap", "ap", { ap = ap({ phase = "land", dist = 3,
    progress = 1.0, eta = nil, err = 0 }), mode = "HOVER", alt = 0, tgt = 0 }, true)
reset() -- latch to "no run" so selecting A/P is not a run-end transition
audit("A/P idle", "ap", "ap", { ap = nil }, true)
audit("A/P extreme values", "ap", "ap", { ap = ap({ dist = 99999, progress = 0.0,
    eta = 99999, err = -180 }), mode = "HOVER" }, true)
audit("ACTIONS idle", "actions", "actions", { ap = nil }, false)
audit("FLIGHT idle", "flight", "flight", { ap = nil }, false)

-- --- 2. the screen follows the run --------------------------------------
-- Enabling the autopilot from another tab pulls the pilot to the A/P screen;
-- that is the point of the screen, so it is behaviour, not a side effect.
reset()
check("starting a run switches to the A/P screen",
    frame("flight", { ap = ap() }) == "ap")
reset()
check("starting a run from ACTIONS also switches to A/P",
    frame("actions", { ap = ap() }) == "ap")
-- Ending a run returns to FLIGHT, unless the pilot moved on deliberately.
reset()
check("finishing a run returns to FLIGHT",
    (function()
        frame("flight", { ap = ap() })          -- -> ap
        return frame("ap", { ap = nil }) == "flight"
    end)())
reset()
check("leaving A/P for NAV survives the run ending",
    (function()
        frame("flight", { ap = ap() })          -- -> ap
        HUD.setTab("nav")
        return frame("nav", { ap = nil }) == "nav"
    end)())

-- --- 3. the phase indicator ---------------------------------------------
-- The active cell is drawn as an inset fill; that inset is its signature.
local function litCell()
    for i = 1, 5 do
        local x = CELL_1_X + (i - 1) * (CELL_W + CELL_GAP)
        for _, r in ipairs(ops) do
            if not r.text and r.x == x + 1 and r.y == CELL_Y + 1
               and r.w == CELL_W - 2 and r.h == CELL_H - 2 then
                return i
            end
        end
    end
    return nil
end

local PHASE_CASES = {
    { "aim",     "climb", 1, "CLIMB TO ALT" },
    { "aim",     "turn",  2, "ROTATE" },
    { "cruise",  nil,     3, "FAST TRAVEL" },
    { "correct", nil,     3, "FAST TRAVEL" },
    { "arrive",  nil,     3, "FAST TRAVEL" },
    { "align",   nil,     4, "ROTATE" },
    { "land",    nil,     5, "LANDING" },
}
for _, c in ipairs(PHASE_CASES) do
    local phase, step, want, wantcap = c[1], c[2], c[3], c[4]
    frame("ap", { ap = ap({ phase = phase, step = step }) })
    local name = string.format("phase %s/%s", phase, tostring(step))
    check(name .. ": lights cell " .. want, litCell() == want,
        string.format("lit cell %s", tostring(litCell())))
    check(name .. ": captioned " .. wantcap, findText(wantcap) ~= nil)
end

-- An unrecognised phase must light nothing rather than the wrong cell: a
-- wrong number is worse than no number when you are reading it off a screen
-- at speed.
frame("ap", { ap = ap({ phase = "wibble", step = "spin" }) })
check("unknown phase lights no cell", litCell() == nil,
    string.format("lit cell %s", tostring(litCell())))
check("unknown phase shows a placeholder, not a wrong number", findText("?") ~= nil)

-- The waypoint name belongs next to the distance: "1247 M" is only useful
-- next to WHICH waypoint.
reset()
frame("ap", { ap = ap() })
check("the waypoint name is shown", findText("NORTH FIELD") ~= nil)
check("the screen is titled AUTOPILOT", findText("AUTOPILOT") ~= nil)
local wg = findText("NORTH FIELD")
local tg = findText("AUTOPILOT")
if wg and tg then
    check("the name does not collide with the title",
        wg.x >= tg.x + tg.w, string.format("name x=%d, title ends %d", wg.x, tg.x + tg.w))
end

-- All five numbers are always on screen, so the indicator reads as a sequence.
-- the five numbers live in the static layer, so redraw it before counting
reset()
frame("ap", { ap = ap() })
for i = 1, 5 do
    check(string.format("phase box %d is drawn", i), findText(tostring(i)) ~= nil)
end

-- --- 4. the tab strip ----------------------------------------------------
-- Tabs are a VERTICAL strip down the right edge (x >= strip_x), stacked from
-- tab_y0. The 7th tab is why the height is derived from the tab count: at the
-- old fixed 24px the last tab ran off the bottom of the monitor. The strip is
-- whitelisted as chrome by the bounds audit, so an overflowing tab would go
-- unnoticed there -- measure the labels directly.
local TABS = { "FLIGHT", "ENGINES", "SYSTEMS", "NAV", "ALARMS", "ACTIONS", "A/P" }
reset()
frame("ap", { ap = ap() })
for _, t in ipairs(TABS) do
    local g = findText(t)
    check("tab " .. t .. " is on screen", g ~= nil)
    if g then
        check("tab " .. t .. " sits in the right-hand strip",
            g.x >= STRIP_X, string.format("x=%d, strip starts %d", g.x, STRIP_X))
        check("tab " .. t .. " stays on the panel",
            g.x + g.w <= W - BORDER, string.format("ends %d, panel %d",
                g.x + g.w, W - BORDER))
        check("tab " .. t .. " does not run off the bottom",
            g.y + g.h <= BODY_END, string.format("ends %d, body ends %d",
                g.y + g.h, BODY_END))
    end
end
-- The active tab is the last one, and it must be the lowest without spilling.
check("the 7th tab fits below the other six",
    (function()
        local prev
        for _, t in ipairs(TABS) do
            local g = findText(t)
            if g then
                if prev and g.y < prev then return false end
                prev = g.y
            end
        end
        return prev ~= nil and prev + Font.height <= BODY_END
    end)())

-- --- 5. the cancel button is actually tappable ---------------------------
-- The button is drawn on the A/P screen; the thing that matters is that a
-- touch on it returns the action os_main already handles, and that no other
-- pixel on the screen does.
reset()
frame("ap", { ap = ap() })
local ccx = CONTENT_X + CANCEL_W / 2
local ccy = CANCEL_Y + CANCEL_H / 2
check("tapping CANCEL A/P returns the apcancel action",
    HUD.handleTouch(ccx, ccy) == "act:apcancel",
    tostring(HUD.handleTouch(ccx, ccy)))
check("the cancel button's top-left corner also hits",
    HUD.handleTouch(CONTENT_X + 1, CANCEL_Y + 1) == "act:apcancel")
check("the cancel button's bottom-right corner also hits",
    HUD.handleTouch(CONTENT_X + CANCEL_W - 1, CANCEL_Y + CANCEL_H - 1) == "act:apcancel")
check("a pixel just above the cancel button does not hit it",
    HUD.handleTouch(ccx, CANCEL_Y - 2) ~= "act:apcancel")
check("a pixel just left of the cancel button does not hit it",
    HUD.handleTouch(CONTENT_X - 2, ccy) ~= "act:apcancel")
check("a data row on the A/P screen does not hit cancel",
    HUD.handleTouch(ccx, BODY_Y + 96) ~= "act:apcancel")

-- The rect is only live on the A/P tab. A touch there on another tab must not
-- reach the cancel path, or a run could be aborted by a stray tap.
for _, t in ipairs({ "flight", "engines", "systems", "nav", "alarms", "actions" }) do
    reset()
    frame(t, { ap = nil })
    check("the cancel rect is inert on the " .. t .. " tab",
        HUD.handleTouch(ccx, ccy) ~= "act:apcancel",
        tostring(HUD.handleTouch(ccx, ccy)))
end

-- The old home of the button: the fifth slot of the actions grid. It must be
-- inert now, or cancelling a run would be reachable from two places.
reset()
frame("actions", { ap = nil })
check("the old actions cancel slot no longer aborts a run",
    HUD.handleTouch(CONTENT_X + 60, BODY_Y + 16 + 38) ~= "act:apcancel",
    "still live on the ACTIONS tab")

-- The 450 m guard must never be readable as the target altitude. The vertical
-- law commands it during the ceiling discovery climb, so a screen fed from
-- targets.altitude shows y450 exactly when the pilot is least sure why.
reset()
frame("ap", { ap = ap({ goal_alt = 250, ceil = 450, alt = 300 }) })
local shown = nil
for _, g in ipairs(texts) do
    if g.str:find("^%d+/%d+$") then shown = g.str end
end
check("A/P shows the plan, not the 450 discovery climb",
    shown ~= nil and shown:find("450") == nil,
    string.format("readout %q", tostring(shown)))
check("A/P shows the planned 250 while still seeking",
    shown ~= nil and shown:find("/250") ~= nil,
    string.format("readout %q", tostring(shown)))
-- Once a ceiling is measured the plan moves to it, and that is what is shown.
reset()
frame("ap", { ap = ap({ goal_alt = 388, ceil = 388, alt = 380 }) })
shown = nil
for _, g in ipairs(texts) do
    if g.str:find("^%d+/%d+$") then shown = g.str end
end
check("A/P shows the measured ceiling once discovered",
    shown ~= nil and shown:find("/388") ~= nil,
    string.format("readout %q", tostring(shown)))

-- PAUSED is a state, not decoration: it must appear only while held.
check("PAUSED is hidden while running", (function()
    frame("ap", { ap = ap() })
    return findText("PAUSED") == nil
end)())
check("PAUSED is shown while held", (function()
    frame("ap", { ap = ap({ paused = true }) })
    return findText("PAUSED") ~= nil
end)())

print(string.format("hud_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("hud_test FAILED", 0) end
