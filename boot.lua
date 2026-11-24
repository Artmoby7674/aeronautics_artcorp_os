-- ArtCorp Flight OS launcher. Installed as the ship computer's `startup`.
--
-- The ship computer sits in a server room the pilot cannot reach in
-- flight, so this never waits for terminal input. It starts the OS, and if
-- the OS ever stops on an error it shows the error on the cockpit monitor
-- and starts it again 2 s later. If the ship is in the air at that point the
-- OS takes control straight away (no splash, engines kept running). Ctrl+T on the ship computer
-- itself (maintenance only) stops it for good.
local RESTART_DELAY = 2 -- short: in flight the props hold their last outputs meanwhile

package.path = "/v2/lib/?.lua;/v2/lib/ui/?.lua;" .. package.path

-- Show a message on the cockpit monitor in plain text (works even when the
-- graphics layer is what failed).
local function showOnMonitor(lines, color)
    pcall(function()
        local mon = peripheral.find("monitor")
        if not mon then return end
        pcall(mon.setGraphicsMode, 0)
        pcall(mon.setTextScale, 1)
        mon.setBackgroundColor(colors.black)
        mon.clear()
        for i, l in ipairs(lines) do
            mon.setCursorPos(2, i + 1)
            mon.setTextColor(i == 1 and (color or colors.red) or colors.white)
            mon.write(l)
        end
    end)
end

local function wrap(text, width)
    local out = {}
    text = tostring(text)
    while #text > width do
        out[#out + 1] = text:sub(1, width)
        text = text:sub(width + 1)
    end
    out[#out + 1] = text
    return out
end

local runs = 0
local last_err = nil
while true do
    runs = runs + 1
    -- reload the OS fresh on every start (only its own modules)
    for _, m in ipairs({ "main", "util", "config", "hw", "est", "ctl", "flight", "ap",
        "nav", "link", "rec", "draw", "font", "ui" }) do
        package.loaded[m] = nil
    end
    local ok, result = pcall(function() return require("main").run({ recovered = last_err, runs = runs }) end)
    if ok and result ~= "restart" then
        return -- stopped on purpose (Ctrl+T on the ship computer)
    end
    local err = ok and "restart requested" or tostring(result)
    last_err = err
    printError("OS stopped: " .. err)
    pcall(function() require("draw").shutdown() end) -- stock colours back
    local lines = { "FLIGHT OS ERROR - restarting in " .. RESTART_DELAY .. " s" }
    for _, l in ipairs(wrap(err, 48)) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Restart #" .. runs .. ". If this repeats, tell your engineer."
    showOnMonitor(lines)
    sleep(RESTART_DELAY)
end
