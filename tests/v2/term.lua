-- A fake CC terminal (51x19 like a ship computer) that keeps what is on
-- screen, for the setup wizard tests. T.text() = the screen as one string,
-- T.seen = every screen drawn so far (one string per clear),
-- T.overflow = text written past the right edge (nil if none).
local T = {}

function T.new(w, h)
    local t = { W = w or 51, H = h or 19, x = 1, y = 1, fg = 1, bg = 32768, seen = {}, colour_at = {}, bg_at = {} }
    local rows = {}
    local function blank()
        rows = {}
        for i = 1, t.H do rows[i] = string.rep(" ", t.W) end
        t.colour_at, t.bg_at = {}, {}
        for y = 1, t.H do for x = 1, t.W do t.bg_at[y * 100 + x] = t.bg end end
    end
    blank()
    function t.text() return table.concat(rows, "\n") end
    function t.row(i) return rows[i] end
    local function snap() t.seen[#t.seen] = t.text() end
    t.api = {
        getSize = function() return t.W, t.H end,
        isColor = function() return true end,
        isColour = function() return true end,
        clear = function() blank() t.seen[#t.seen + 1] = t.text() end,
        setCursorPos = function(x, y) t.x, t.y = x, y end,
        getCursorPos = function() return t.x, t.y end,
        setTextColor = function(c) t.fg = c end,
        setTextColour = function(c) t.fg = c end,
        setBackgroundColor = function(c) t.bg = c end,
        setBackgroundColour = function(c) t.bg = c end,
        write = function(s)
            s = tostring(s)
            if t.x + #s - 1 > t.W then t.overflow = (t.overflow or "") .. "[" .. s .. "]" end
            if t.y >= 1 and t.y <= t.H then
                for i = 1, #s do
                    local x = t.x + i - 1
                    if x >= 1 and x <= t.W then
                        rows[t.y] = rows[t.y]:sub(1, x - 1) .. s:sub(i, i) .. rows[t.y]:sub(x + 1)
                        t.colour_at[t.y * 100 + x] = t.fg
                        t.bg_at[t.y * 100 + x] = t.bg
                    end
                end
            end
            t.x = t.x + #s
            if #t.seen == 0 then t.seen[1] = "" end
            snap()
        end,
        nativePaletteColour = function() return 0, 0, 0 end,
    }
    -- a copy of the screen: { rows = { "..." }, fg = { [y*100+x] = c }, bg = {...} }
    function t.cells()
        local c = { rows = {}, fg = {}, bg = {}, W = t.W, H = t.H }
        for y = 1, t.H do c.rows[y] = rows[y] end
        for k, v in pairs(t.colour_at) do c.fg[k] = v end
        for k, v in pairs(t.bg_at) do c.bg[k] = v end
        return c
    end
    -- the text colour a string was written in (first character), or nil
    function t.colourOf(str)
        for y = 1, t.H do
            local x = rows[y]:find(str, 1, true)
            if x then return t.colour_at[y * 100 + x] end
        end
    end
    return t
end

return T
