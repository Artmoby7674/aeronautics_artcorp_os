-- ArtCorpOS boot launcher. Installed as the computer's `startup`.
--
-- Boots ArtCorp Flight OS v2 by default. For 2 seconds it waits for a key:
--   1  start the original OS (startup_v1) this time
--   2  start v2 now (skip the wait)
-- The default is stored in config/boot ("v1" or "v2"); `boot v1` / `boot v2`
-- from the shell changes it permanently.
--
-- v2 has no setup wizard: it flies with the wiring the original OS's wizard
-- saved (config/assignments_<ship>.lua). Until such a save exists, the
-- original OS runs so the wizard can set the ship up.
local args = { ... }
local CHOICE = "config/boot"

local function readChoice()
    if not fs.exists(CHOICE) then return "v2" end
    local f = fs.open(CHOICE, "r")
    local v = f and f.readAll() or ""
    if f then f.close() end
    v = v:gsub("%s", "")
    return (v == "v1") and "v1" or "v2"
end

local function writeChoice(v)
    if not fs.exists("config") then fs.makeDir("config") end
    local f = fs.open(CHOICE, "w")
    if f then f.write(v) f.close() end
end

if args[1] == "v1" or args[1] == "v2" then
    writeChoice(args[1])
    print("Default OS is now " .. args[1] .. ". Reboot to use it.")
    return
end

local function hasWiring()
    if not fs.isDir("config") then return false end
    for _, f in ipairs(fs.list("config")) do
        if f:match("^assignments_.+%.lua$") then return true end
    end
    return false
end

local function run(which)
    if which == "v2" then
        shell.run("/v2/start.lua")
    else
        shell.run("/startup_v1")
    end
end

local default = readChoice()
if default == "v2" and not hasWiring() then
    print("No ship wiring saved yet: starting the original OS setup.")
    print("Next boot starts v2.")
    run("v1")
    return
end
if default == "v2" and not fs.exists("/v2/start.lua") then default = "v1" end

term.clear()
term.setCursorPos(1, 1)
print("ArtCorpOS launcher")
print("Starting " .. (default == "v2" and "v2" or "the original OS") .. " in 2 s")
print("  1 = original OS   2 = v2")
local timer = os.startTimer(2)
local pick = default
while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then break end
    if ev == "char" and (a == "1" or a == "2") then
        pick = (a == "1") and "v1" or "v2"
        break
    end
end
run(pick)
