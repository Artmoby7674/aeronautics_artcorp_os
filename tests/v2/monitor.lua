-- Mock CC:Graphics monitor (mode 2, 256 colours): a 348x216 indexed framebuffer that also records
-- out-of-bounds and malformed drawPixels calls (they are errors on the real
-- peripheral or silently lost pixels).
local M = {}

function M.new(W, H)
    W, H = W or 348, H or 216
    local mon = { W = W, H = H, fb = {}, errors = {}, calls = 0, palette = {} }
    for i = 0, W * H - 1 do mon.fb[i] = 15 end
    local function put(x, y, c)
        if x < 0 or y < 0 or x >= W or y >= H then
            mon.errors[#mon.errors + 1] = string.format("pixel out of bounds %d,%d", x, y)
            return
        end
        if type(c) ~= "number" or c < -1 or c > 255 or c ~= math.floor(c) then
            mon.errors[#mon.errors + 1] = "bad colour " .. tostring(c)
            return
        end
        if c >= 0 then mon.fb[y * W + x] = c end
    end
    function mon.setTextScale() end
    function mon.setGraphicsMode() return true end
    function mon.setFrozen() end
    -- mode 2 has 256 palette slots (the tour's dimmed colours live in 16-31)
    function mon.setPaletteColor(i, r, g, b) mon.palette[i] = { r, g, b } end
    function mon.getPaletteColor(i)
        local p = mon.palette[i]
        if p then return p[1], p[2], p[3] end
        return 0, 0, 0
    end
    function mon.getSize(mode)
        if mode then return W, H end
        return math.floor(W / 6), math.floor(H / 9)
    end
    function mon.drawPixels(x, y, a, w, h)
        mon.calls = mon.calls + 1
        if x ~= math.floor(x) or y ~= math.floor(y) then
            mon.errors[#mon.errors + 1] = "non-integer origin " .. x .. "," .. y
        end
        if type(a) == "table" then
            for r, row in ipairs(a) do
                for c = 1, #row do put(x + c - 1, y + r - 1, row[c]) end
            end
        else
            for yy = y, y + h - 1 do for xx = x, x + w - 1 do put(xx, yy, a) end end
        end
    end
    return mon
end

return M
