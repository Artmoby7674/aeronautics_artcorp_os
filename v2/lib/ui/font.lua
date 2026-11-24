-- v2 5x7 bitmap font. Each glyph = 7 rows of 5 bits as hex pairs (bit 4 is
-- the leftmost pixel). '^' draws a degree sign, '{' '}' are up/down arrows,
-- '@' a bullet. Rendered glyph strips are cached.
local Font = { w = 5, h = 7, adv = 6 }

local G = {
    ["0"] = "0E11131519110E", ["1"] = "040C040404040E", ["2"] = "0E11010204081F", ["3"] = "1F02040201110E",
    ["4"] = "02060A121F0202", ["5"] = "1F101E0101110E", ["6"] = "0608101E11110E", ["7"] = "1F010204080808",
    ["8"] = "0E11110E11110E", ["9"] = "0E11110F01020C", A = "0E1111111F1111", B = "1E11111E11111E",
    C = "0E11101010110E", D = "1C12111111121C", E = "1F10101E10101F", F = "1F10101E101010",
    G = "0E11101711110F", H = "1111111F111111", I = "0E04040404040E", J = "0702020202120C",
    K = "11121418141211", L = "1010101010101F", M = "111B1515111111", N = "11111915131111",
    O = "0E11111111110E", P = "1E11111E101010", Q = "0E11111115120D", R = "1E11111E141211",
    S = "0F10100E01011E", T = "1F040404040404", U = "1111111111110E", V = "11111111110A04",
    W = "1111111515150A", X = "11110A040A1111", Y = "1111110A040404", Z = "1F01020408101F",
    [" "] = "00000000000000", ["."] = "00000000000C0C", [","] = "000000000C0408", [":"] = "000C0C000C0C00",
    ["-"] = "0000001F000000", ["+"] = "0004041F040400", ["/"] = "00010204081000", ["%"] = "18190204081303",
    ["("] = "02040808080402", [")"] = "08040202020408", ["!"] = "04040404040004", ["?"] = "0E110102040004",
    [">"] = "08040201020408", ["<"] = "02040810080402", ["="] = "00001F001F0000", ["_"] = "0000000000001F",
    ["'"] = "0C040800000000", ["#"] = "0A0A1F0A1F0A0A", ["*"] = "0004150E150400", ["^"] = "0C12120C000000",
    ["|"] = "04040404040404", ["["] = "0E08080808080E", ["]"] = "0E02020202020E", ["{"] = "040E1504040404",
    ["}"] = "04040404150E04", ["@"] = "00000E0E0E0000",
}

local rows = {}
for ch, hex in pairs(G) do
    local r = {}
    for i = 1, 7 do r[i] = tonumber(hex:sub(i * 2 - 1, i * 2), 16) or 0 end
    rows[ch] = r
end
Font.rows = rows

function Font.width(str, scale)
    local n = #str
    if n == 0 then return 0 end
    return (n * Font.adv - 1) * (scale or 1)
end

local cache, cache_n = {}, 0

-- Dense pixel rows for drawPixels: { {c,c,...}, ... } with fg/bg colours.
function Font.render(str, fg, bg, scale)
    scale = scale or 1
    local key = str .. "\0" .. fg .. "\0" .. bg .. "\0" .. scale
    local hit = cache[key]
    if hit then return hit end
    local w = Font.width(str, scale)
    local out = {}
    for y = 1, 7 * scale do
        local line = {}
        for x = 1, w do line[x] = bg end
        out[y] = line
    end
    local x0 = 0
    for i = 1, #str do
        local g = rows[str:sub(i, i):upper()] or rows["?"]
        for gy = 1, 7 do
            local bits = g[gy]
            if bits ~= 0 then
                for gx = 0, 4 do
                    if bits % (2 ^ (5 - gx)) >= 2 ^ (4 - gx) then
                        for sy = 1, scale do
                            local line = out[(gy - 1) * scale + sy]
                            for sx = 1, scale do
                                line[x0 + gx * scale + sx] = fg
                            end
                        end
                    end
                end
            end
        end
        x0 = x0 + Font.adv * scale
    end
    if cache_n > 400 then cache, cache_n = {}, 0 end
    cache[key] = out
    cache_n = cache_n + 1
    return out
end

return Font
