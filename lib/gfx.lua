-- ArtCorpOS graphics backend - CC:Graphics mode 2 (256 colors)
-- All coordinates are 0-based pixels. Direct monitor path preferred;
-- falls back to term.redirect(mon).

local function loadLib(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    local path = (name:gsub("%.", "/")) .. ".lua"
    local fn = loadfile(path)
    if fn then
        local ok2, res = pcall(fn)
        if ok2 then return res end
        error(res, 0)
    end
    error(mod, 0)
end

local Font = loadLib("lib.font")

local Gfx = {
    supported = false,
    mode = 2,
    W = 0,
    H = 0,
    _mon = nil,
    _path = nil,     -- "direct" | "redirect"
    _active = false, -- inside begin/finish frame (redirect path)
    _old = nil,
}

local function textSize(obj)
    local ok1, tw, th = pcall(function() return obj.getSize() end)
    local ok2, w2, h2 = pcall(function() return obj.getSize(2) end)
    if ok2 and ok1 and type(w2) == "number" and (w2 ~= tw or h2 ~= th) then
        return w2, h2
    end
    if ok1 and type(tw) == "number" and type(th) == "number" then
        return tw * 6, th * 9
    end
    if ok2 and type(w2) == "number" then
        return w2, h2
    end
    return 0, 0
end

local function call(fnName, ...)
    local args = { ... }
    local n = select("#", ...)
    if Gfx._path == "direct" then
        local f = Gfx._mon[fnName]
        if not f then
            error(fnName .. " not available on monitor", 2)
        end
        return f(table.unpack(args, 1, n))
    elseif Gfx._path == "redirect" then
        local function invoke()
            local f = term[fnName]
            if not f then
                error(fnName .. " not available on term", 2)
            end
            return f(table.unpack(args, 1, n))
        end
        if Gfx._active then
            return invoke()
        end
        local old = term.redirect(Gfx._mon)
        local res = table.pack(pcall(invoke))
        term.redirect(old)
        if not res[1] then
            error(res[2], 0)
        end
        return table.unpack(res, 2, res.n)
    else
        error("Gfx not initialized", 2)
    end
end

function Gfx.init(mon, textScale)
    Gfx._mon = mon
    pcall(function() mon.setTextScale(textScale or 0.5) end)

    if type(mon.setGraphicsMode) == "function" and type(mon.drawPixels) == "function" then
        local ok = pcall(mon.setGraphicsMode, 2)
        if ok then
            Gfx._path = "direct"
            Gfx.supported = true
            Gfx.W, Gfx.H = textSize(mon)
            return true
        end
    end

    if type(term.setGraphicsMode) == "function" and type(term.drawPixels) == "function" then
        local old = term.redirect(mon)
        local ok = pcall(term.setGraphicsMode, 2)
        if ok then
            Gfx._path = "redirect"
            Gfx.supported = true
            Gfx.W, Gfx.H = textSize(mon)
            term.redirect(old)
            return true
        end
        pcall(term.setGraphicsMode, 0)
        term.redirect(old)
    end

    return false
end

function Gfx.begin()
    if not Gfx.supported then
        error("Gfx not supported", 2)
    end
    if Gfx._path == "direct" then
        pcall(function() Gfx._mon.setFrozen(true) end)
    elseif Gfx._path == "redirect" and not Gfx._active then
        Gfx._old = term.redirect(Gfx._mon)
        pcall(term.setFrozen, true)
        Gfx._active = true
    end
end

function Gfx.finish()
    if not Gfx.supported then return end
    if Gfx._path == "direct" then
        pcall(function() Gfx._mon.setFrozen(false) end)
    elseif Gfx._path == "redirect" and Gfx._active then
        pcall(term.setFrozen, false)
        term.redirect(Gfx._old)
        Gfx._old = nil
        Gfx._active = false
    end
end

local function clipRect(x, y, w, h)
    if w < 1 or h < 1 then return nil end
    if x < 0 then
        w = w + x
        x = 0
    end
    if y < 0 then
        h = h + y
        y = 0
    end
    if x >= Gfx.W or y >= Gfx.H then return nil end
    if x + w > Gfx.W then w = Gfx.W - x end
    if y + h > Gfx.H then h = Gfx.H - y end
    if w < 1 or h < 1 then return nil end
    return x, y, w, h
end

function Gfx.clear(color)
    call("drawPixels", 0, 0, color or 15, Gfx.W, Gfx.H)
end

function Gfx.fillRect(x, y, w, h, color)
    local cx, cy, cw, ch = clipRect(x, y, w, h)
    if not cx then return end
    call("drawPixels", cx, cy, color, cw, ch)
end

function Gfx.text(x, y, str, color, bg)
    str = tostring(str or "")
    if str == "" then return end
    if not Gfx.supported then return end
    if y + Font.height <= 0 or y >= Gfx.H then return end
    if x >= Gfx.W then return end
    if x < 0 then return end -- glyph rows are not clipped on the left
    str = Font.fit(str, Gfx.W - x)
    if str == "" then return end
    local rows = Font.render(str, color or 0, bg)
    call("drawPixels", x, y, rows)
end

function Gfx.textScaled(x, y, str, color, bg, scale)
    scale = math.floor(scale or 1)
    if scale < 1 then scale = 1 end
    str = tostring(str or "")
    if str == "" or not Gfx.supported then return end
    local max_w = Gfx.W - x
    if max_w < 1 or y >= Gfx.H then return end
    if x < 0 then return end
    -- fit in scaled pixels
    while scale > 1 and Font.textWidthScaled(str, scale) > max_w do
        scale = scale - 1
    end
    if Font.textWidthScaled(str, scale) > max_w then
        str = Font.fit(str, math.floor(max_w / scale))
        if str == "" then return end
    end
    local rows, _, th = Font.renderScaled(str, color or 0, bg, scale)
    if y + th <= 0 then return end
    call("drawPixels", x, y, rows)
end

function Gfx.textWidth(str)
    return Font.textWidth(str)
end

function Gfx.setPaletteColor(idx, r, g, b)
    local rr = (r or 0) / 255
    local gg = (g or 0) / 255
    local bb = (b or 0) / 255
    if Gfx._path == "direct" then
        pcall(function() Gfx._mon.setPaletteColor(idx, rr, gg, bb) end)
    else
        pcall(function() call("setPaletteColor", idx, rr, gg, bb) end)
    end
end

function Gfx.shutdown()
    if not Gfx.supported then return end
    pcall(function() Gfx.finish() end)
    pcall(function() call("setGraphicsMode", 0) end)
    Gfx.supported = false
    Gfx._path = nil
end

return Gfx
