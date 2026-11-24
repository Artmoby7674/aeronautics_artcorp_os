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

-- the palette is set on init
check("palette applied", SC.mon.palette[0] ~= nil and SC.mon.palette[15] ~= nil)

print(string.format("v2_ui_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_ui_test FAILED", 0) end
