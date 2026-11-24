-- Launcher (boot.lua -> startup): never asks anything, restarts the OS after
-- an error with the error shown on the monitor, stops when the OS stops.
local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else
        failed = failed + 1
        print("FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
    end
end

local src = io.open("boot.lua"):read("a")
check("launcher never reads the terminal", not src:find("read%(") and not src:find("pullEvent"))

local function runLauncher(plan)
    local calls, shown, slept = {}, {}, 0
    local env = setmetatable({}, { __index = _G })
    env.package = { path = "", loaded = {}, preload = {} }
    env.require = function(name)
        if name == "main" then
            return { run = function(opts)
                calls[#calls + 1] = opts
                local step = plan[#calls]
                if step == "crash" then error("boom " .. #calls, 0) end
                return nil
            end }
        end
        if name == "draw" then return { shutdown = function() end } end
        error("unexpected require " .. name)
    end
    local mon = { setGraphicsMode = function() end, setTextScale = function() end,
        setBackgroundColor = function() end, clear = function() end, setCursorPos = function() end,
        setTextColor = function() end, write = function(s) shown[#shown + 1] = s end }
    env.peripheral = { find = function() return mon end }
    env.colors = { black = 1, red = 2, white = 3 }
    env.printError = function() end
    env.sleep = function(s) slept = slept + s end
    assert(load(src, "=boot", "t", env))()
    return calls, shown, slept
end

local calls, shown, slept = runLauncher({ "ok" })
check("clean stop: OS run once", #calls == 1, #calls)
check("clean stop: nothing shown", #shown == 0)

calls, shown, slept = runLauncher({ "crash", "crash", "ok" })
check("crash: OS restarted until it stops cleanly", #calls == 3, #calls)
check("crash: error passed to the restarted OS", calls[2].recovered == "boom 1", tostring(calls[2].recovered))
local text = table.concat(shown, " ")
check("crash: error shown on the monitor", text:find("boom 2") ~= nil, text)
check("crash: restart delay is short", slept <= 4, slept)

print(string.format("v2_boot_test: %d passed, %d failed", passed, failed))
if failed > 0 then error("v2_boot_test FAILED", 0) end
