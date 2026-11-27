-- ArtCorpOS - Installer
-- Paste this into CC terminal: edit install
-- Then run: install
--
-- After install: reboot. The ship starts the flight OS by itself.
-- On the KEYBOARD computer run: install kbd

-- Pinned ref (commit SHA on origin/master). NEVER install from "master":
-- a moving branch silently changes what ships get, and a half-updated
-- install is a broken ship. Bump REF deliberately when releasing, and only
-- to a commit that is already pushed (an unpushed SHA 404s every file).
local REF = "01e4b6bb5de4bd0b6406a3bdcb9698b9a6beafab"
local BASE_URL = "https://raw.githubusercontent.com/Artmoby7674/aeronautics_artcorp_os/" .. REF

-- { repo path, path on the computer }. The launcher (boot.lua) becomes
-- `startup`: the ship boots straight into the flight OS after install.
local files = {
    { "boot.lua", "startup" },
    { "config/atlas.lua", "config/atlas.lua" },
    { "v2/start.lua", "v2/start.lua" },
    { "v2/tune.lua", "v2/tune.lua" },
    { "v2/lib/ap.lua", "v2/lib/ap.lua" },
    { "v2/lib/config.lua", "v2/lib/config.lua" },
    { "v2/lib/ctl.lua", "v2/lib/ctl.lua" },
    { "v2/lib/est.lua", "v2/lib/est.lua" },
    { "v2/lib/atmos.lua", "v2/lib/atmos.lua" },
    { "v2/lib/shipdisk.lua", "v2/lib/shipdisk.lua" },
    { "v2/lib/onboard.lua", "v2/lib/onboard.lua" },
    { "v2/lib/remote.lua", "v2/lib/remote.lua" },
    { "v2/lib/flight.lua", "v2/lib/flight.lua" },
    { "v2/lib/hw.lua", "v2/lib/hw.lua" },
    { "v2/lib/link.lua", "v2/lib/link.lua" },
    { "v2/lib/main.lua", "v2/lib/main.lua" },
    { "v2/lib/nav.lua", "v2/lib/nav.lua" },
    { "v2/lib/rec.lua", "v2/lib/rec.lua" },
    { "v2/lib/util.lua", "v2/lib/util.lua" },
    { "v2/lib/version.lua", "v2/lib/version.lua" },
    { "v2/lib/ui/draw.lua", "v2/lib/ui/draw.lua" },
    { "v2/lib/ui/font.lua", "v2/lib/ui/font.lua" },
    { "v2/lib/ui/ui.lua", "v2/lib/ui/ui.lua" },
}

-- Program files left behind by earlier releases. Removed after a successful
-- install. Ship data in config/ (wiring, saves, waypoints) is never touched.
local leftovers = {
    "startup_v1", "boot", "ship.lua", "mkconfig.lua", "gfxcheck", "stab_log.txt",
    "lib/pid.lua", "lib/hardware.lua", "lib/flight.lua", "lib/os_main.lua", "lib/hud.lua",
    "lib/gfx.lua", "lib/font.lua", "lib/record.lua", "lib/report.lua", "lib/kbd.lua",
    "lib/waypoints.lua",
}

-- The KEYBOARD computer (on top of the cockpit screen) only needs kbd.lua:
-- `install kbd` installs just that.
local kbd_only = ({ ... })[1] == "kbd"
if kbd_only then
    files = { { "kbd.lua", "kbd.lua" } }
    leftovers = {}
end

-- config/atlas.lua is the TEMPLATE new save slots are copied from. If a save
-- slot is itself called "atlas" (it has wizard assignments), that file is a
-- live ship config with its own edits: never overwrite it.
local function isLiveConfig(path)
    return path == "config/atlas.lua" and fs.exists("config/assignments_atlas.lua")
end

print("=============================")
print("   ArtCorp Flight OS Installer")
print("   Flight Stabilization")
print("=============================")
print("")
print("This will install the following files:")
for _, f in ipairs(files) do
    local note = isLiveConfig(f[2]) and "  (kept: live ship config)" or ""
    if f[1] ~= f[2] then note = " (from " .. f[1] .. ")" .. note end
    print("  " .. f[2] .. note)
end
local present = {}
for _, f in ipairs(leftovers) do
    if fs.exists(f) then present[#present + 1] = f end
end
if #present > 0 then
    print("")
    print("Old program files that will be removed:")
    for _, f in ipairs(present) do print("  " .. f) end
end
print("")
print("Files will be downloaded from:")
print("  ref " .. REF:sub(1, 12))
print("")
write("Continue? [Y/n] ")
local answer = (read() or ""):gsub("%s", "")
if answer ~= "" and answer:lower() ~= "y" then
    print("Installation cancelled.")
    return
end
print("")

-- http is a CC global API, not a require()-able module.
local http = rawget(_G, "http")
if type(http) ~= "table" or type(http.get) ~= "function" then
    print("ERROR: HTTP API not available.")
    print("Make sure 'http' is enabled in ComputerCraft config.")
    print("Alternatively, copy files manually from the repo.")
    return
end

-- Phase 1: download EVERYTHING into memory first and verify it.
local downloaded = {}
local failures = {}

-- downloaded[dest] = content (a repo file may land at several paths)
local cache = {}
for _, pair in ipairs(files) do
    local src, filepath = pair[1], pair[2]
    if isLiveConfig(filepath) then
        -- kept as is
    elseif cache[src] then
        downloaded[filepath] = cache[src]
    else
        local url = BASE_URL .. "/" .. src
        io.write("  Downloading " .. filepath:sub(1, 40) .. "... ")

        local response, err, failResponse = http.get(url)
        if failResponse then pcall(failResponse.close) end -- e.g. a 404 body
        if not response then
            print("FAILED (" .. tostring(err) .. ")")
            table.insert(failures, filepath .. ": " .. tostring(err))
        else
            local code = nil
            if response.getResponseCode then
                local okc, c = pcall(response.getResponseCode)
                if okc then code = c end
            end
            local content = response.readAll()
            response.close()

            -- Integrity: HTTP 200, non-empty, not an error page, and the
            -- file must compile (catches truncated downloads).
            local bad = nil
            if code and code ~= 200 then
                bad = "HTTP " .. tostring(code)
            elseif not content or #content == 0 then
                bad = "empty response"
            elseif #content < 40 then
                bad = "suspiciously short (" .. #content .. " bytes)"
            elseif content:sub(1, 1) == "<" then
                bad = "got HTML instead of Lua"
            elseif not load(content, "=" .. filepath, "t", {}) then
                bad = "does not compile (truncated?)"
            end
            if bad then
                print("REJECTED (" .. bad .. ")")
                table.insert(failures, filepath .. ": " .. bad)
            else
                print("OK (" .. #content .. " bytes)")
                downloaded[filepath] = content
                cache[src] = content
            end
        end
        sleep(0.2)
    end
end

local function banner(lines)
    print("")
    print("=============================")
    for _, l in ipairs(lines) do print(l) end
    print("=============================")
end

if #failures > 0 then
    local lines = { "  INSTALL ABORTED - " .. #failures .. " file(s) failed:" }
    for _, f in ipairs(failures) do lines[#lines + 1] = "    " .. f end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  NO files were written. Check the connection / ref,"
    lines[#lines + 1] = "  then re-run install."
    return banner(lines)
end

-- Phase 2: enough disk to stage every new file next to the old one?
local need = 0
for _, content in pairs(downloaded) do need = need + #content end
local free = fs.getFreeSpace("/")
if need > free then
    return banner({
        "  INSTALL ABORTED - not enough disk space.",
        string.format("  Need %d KB free for staging, have %d KB.",
            math.ceil(need / 1024), math.floor(free / 1024)),
        "  Delete logs/old files (e.g. stab_log.txt), re-run.",
        "  NO files were written.",
    })
end

-- Phase 3: stage every file as <path>.new. Any failure removes the staged
-- copies and leaves the existing install exactly as it was.
local staged = {}
local function unstage()
    for _, p in ipairs(staged) do pcall(fs.delete, p .. ".new") end
end
for _, pair in ipairs(files) do
    local filepath = pair[2]
    local content = downloaded[filepath]
    if content then
        local dir = filepath:match("(.*)/")
        if dir then pcall(fs.makeDir, dir) end
        staged[#staged + 1] = filepath
        local ok = pcall(function()
            local f = fs.open(filepath .. ".new", "w")
            if not f then error("open failed") end
            f.write(content)
            f.close()
        end)
        if not (ok and fs.exists(filepath .. ".new") and fs.getSize(filepath .. ".new") == #content) then
            unstage()
            return banner({
                "  INSTALL ABORTED - could not write " .. filepath,
                "  (disk full / permissions?). The existing",
                "  install is unchanged.",
            })
        end
    end
end

-- Phase 4: swap the staged files in. Each swap is a delete + rename, which
-- needs no extra space; only a power cut mid-loop can leave a mix (then
-- just re-run install).
local swapped = 0
for _, filepath in ipairs(staged) do
    pcall(fs.delete, filepath)
    if pcall(fs.move, filepath .. ".new", filepath) then swapped = swapped + 1 end
end

local lines = { "  Installed " .. swapped .. "/" .. #staged .. " files from ref " .. REF:sub(1, 8) .. "." }
if swapped < #staged then
    lines[#lines + 1] = "  SOME FILES DID NOT SWAP IN - re-run install."
else
    local removed = 0
    for _, f in ipairs(present) do
        if pcall(fs.delete, f) and not fs.exists(f) then removed = removed + 1 end
    end
    if fs.isDir("lib") and #fs.list("lib") == 0 then pcall(fs.delete, "lib") end
    if removed > 0 then lines[#lines + 1] = "  Removed " .. removed .. " old program file(s)." end
    lines[#lines + 1] = ""
    if kbd_only then
        lines[#lines + 1] = "  Run 'kbd' (or rename it to startup)."
    else
        lines[#lines + 1] = "  Reboot: the ship starts the flight OS by itself."
    end
end
banner(lines)
