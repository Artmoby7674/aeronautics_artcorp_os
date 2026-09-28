-- Flight report printer: 3 pages on a network printer (peripheral.find or
-- config.peripherals.printer).
--   page 1: header + stats + X(t) graph
--   page 2: Y(t) graph
--   page 3: Z(t) graph
-- Graphs plot each coordinate against time; the t axis has a tick every
-- TICK_S seconds (labels every few ticks so they fit).
-- Page geometry comes from printer.getPageSize() and adapts.

local Report = {}

local TICK_S = 5 -- seconds between time-axis ticks

local function fmtDur(sec)
    sec = math.floor(sec or 0)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function trunc(str, w)
    str = tostring(str or "")
    if #str <= w then return str end
    if w <= 1 then return str:sub(1, w) end
    return str:sub(1, w - 1) .. "~"
end

local function put(pr, x, y, str)
    pr.setCursorPos(x, y)
    pr.write(str)
end

local function safeNum(fn, def)
    local ok, v = pcall(fn)
    if ok and type(v) == "number" then return v end
    return def
end

local function beginPage(pr, title)
    local ok = pr.newPage()
    if not ok then return nil, "Cannot start page (ink/paper?)" end
    pcall(function() pr.setPageTitle(title) end)
    local w, h = pr.getPageSize()
    if type(w) ~= "number" or type(h) ~= "number" or w < 8 or h < 6 then
        pcall(pr.endPage)
        return nil, "Page too small: " .. tostring(w) .. "x" .. tostring(h)
    end
    return { w = w, h = h }
end

-- Draw one value-vs-time graph into the current page.
-- rows y0..h-2 = plot, h-1 = time axis, h = tick labels. cols 1..lm = y labels.
local function drawGraph(pr, w, h, y0, samples, key, label)
    local n = #samples
    local t0 = samples[1][1]
    local dur = samples[n][1] - t0
    if dur <= 0 then dur = 1 end

    local vmin, vmax = samples[1][key], samples[1][key]
    for i = 2, n do
        local v = samples[i][key]
        if v < vmin then vmin = v end
        if v > vmax then vmax = v end
    end
    if vmax - vmin < 1 then
        vmin = vmin - 1
        vmax = vmax + 1
    end

    local ymin_s = string.format("%.0f", vmin)
    local ymax_s = string.format("%.0f", vmax)
    local lm = math.max(#ymin_s, #ymax_s, 2) + 1 -- left margin for y labels

    local ph = (h - 2) - y0 + 1 -- plot rows (y0 .. h-2); axis is h-1, labels h
    local plotw = w - lm
    if ph < 2 or plotw < 4 then
        put(pr, 1, y0, trunc(label .. " (no room for graph)", w))
        return
    end

    -- y labels (top = max, bottom = min), right-aligned in the margin
    put(pr, 1, y0, trunc(ymax_s, lm - 1))
    put(pr, 1, y0 + ph - 1, trunc(ymin_s, lm - 1))
    if ph >= 7 then
        put(pr, 1, y0 + math.floor(ph / 2),
            trunc(string.format("%.0f", (vmin + vmax) / 2), lm - 1))
    end

    -- time axis
    local axis_row = h - 1
    local label_row = h
    put(pr, lm, axis_row, string.rep("-", plotw))

    -- tick labels: choose a step so ~4 labels fit
    local max_labels = math.max(2, math.floor(plotw / 5))
    local step = TICK_S
    while dur / step > max_labels do
        step = step * 2
    end
    local prev_label_end = 0
    for tk = 0, math.floor(dur), TICK_S do
        local col = lm + math.floor((tk / dur) * (plotw - 1) + 0.5)
        if col < lm then col = lm end
        if col > lm + plotw - 1 then col = lm + plotw - 1 end
        put(pr, col, axis_row, "+")
        if tk % step == 0 then
            local txt = string.format("%.0f", tk)
            local tx = math.max(col, prev_label_end + 1)
            if tx + #txt - 1 <= w then
                put(pr, tx, label_row, txt)
                prev_label_end = tx + #txt
            end
        end
    end

    -- points: min/max row per column, connected column to column
    local cols = {} -- col -> { lo, hi }
    local order = {}
    for i = 1, n do
        local v = samples[i][key]
        local col = lm + math.floor(((samples[i][1] - t0) / dur) * (plotw - 1) + 0.5)
        if col < lm then col = lm end
        if col > lm + plotw - 1 then col = lm + plotw - 1 end
        local row = 1 + math.floor((1 - (v - vmin) / (vmax - vmin)) * (ph - 1) + 0.5)
        local c = cols[col]
        if not c then
            c = { lo = row, hi = row }
            cols[col] = c
            order[#order + 1] = col
        else
            if row < c.lo then c.lo = row end
            if row > c.hi then c.hi = row end
        end
    end
    table.sort(order)

    local prev_center = nil
    local prev_col = nil
    for _, col in ipairs(order) do
        local c = cols[col]
        local center = math.floor((c.lo + c.hi) / 2)
        if prev_col == col - 1 and prev_center then
            local a, b = prev_center, center
            if a > b then a, b = b, a end
            for r = a, b do
                put(pr, col, y0 + r - 1, "|")
            end
        end
        put(pr, col, y0 + c.lo - 1, "*")
        if c.hi ~= c.lo then
            put(pr, col, y0 + c.hi - 1, "*")
        end
        prev_center = center
        prev_col = col
    end
end

-- samples: { {t, x, y, z}, ... }; stats from lib/record.lua Rec.stats();
-- interval: sample period in seconds (displayed in the header).
function Report.print(pr, samples, ship_title, stats, interval)
    if type(samples) ~= "table" or #samples < 2 then
        return false, "Recording too short (need 2+ samples)"
    end

    local paper = safeNum(function() return pr.getPaperLevel() end, 99)
    local ink = safeNum(function() return pr.getInkLevel() end, 99)
    if paper < 3 then return false, "Printer out of paper" end
    if ink < 1 then return false, "Printer out of ink" end

    local st = stats or {
        count = #samples,
        duration = samples[#samples][1],
        path = 0,
        min = { x = 0, y = 0, z = 0 },
        max = { x = 0, y = 0, z = 0 },
    }
    local title = tostring(ship_title or "SHIP"):upper()

    -- page 1: header + stats + X(t)
    local pg, err = beginPage(pr, title .. " report")
    if not pg then return false, err end
    local row = 1
    local function wline(str)
        if row <= pg.h then
            put(pr, 1, row, trunc(str, pg.w))
            row = row + 1
        end
    end
    wline("ARTCORPOS FLIGHT REPORT")
    wline(title .. "  " .. os.date("%Y-%m-%d %H:%M"))
    wline("DURATION " .. fmtDur(st.duration) .. "  SAMPLES " ..
        st.count .. " (every " .. tostring(interval or 10) .. "s)")
    wline("PATH " .. string.format("%.0f", st.path) .. " M")
    wline(string.format("X %.0f..%.0f", st.min.x, st.max.x) ..
        string.format("  Y %.0f..%.0f", st.min.y, st.max.y))
    wline(string.format("Z %.0f..%.0f", st.min.z, st.max.z))
    row = row + 1 -- blank spacer
    drawGraph(pr, pg.w, pg.h, row, samples, 2, "X")
    if not pr.endPage() then return false, "Cannot end page 1 (tray full?)" end

    -- page 2: Y(t)
    pg, err = beginPage(pr, title .. " Y(t)")
    if not pg then return false, err end
    drawGraph(pr, pg.w, pg.h, 1, samples, 3, "Y")
    if not pr.endPage() then return false, "Cannot end page 2 (tray full?)" end

    -- page 3: Z(t)
    pg, err = beginPage(pr, title .. " Z(t)")
    if not pg then return false, err end
    drawGraph(pr, pg.w, pg.h, 1, samples, 4, "Z")
    if not pr.endPage() then return false, "Cannot end page 3 (tray full?)" end

    return true, "PRINTED 3 PAGES"
end

return Report
