-- ArtCorpOS - Installer
-- Paste this into CC terminal: edit install
-- Then run: install
--
-- After install, run: startup

-- Pinned ref (commit SHA on origin/master). NEVER install from "master":
-- a moving branch silently changes what ships get, and a half-updated
-- install is a broken ship. Bump REF deliberately when releasing.
local REF = "bbb5123ec3a60dca00046761adf0dcd5b146afdd"
local BASE_URL = "https://raw.githubusercontent.com/Artmoby7674/aeronautics_artcorp_os/" .. REF

local files = {
    "startup",
    "ship.lua",
    "config/atlas.lua",
    "lib/pid.lua",
    "lib/hardware.lua",
    "lib/flight.lua",
    "lib/os_main.lua",
    "lib/hud.lua",
    "lib/gfx.lua",
    "lib/font.lua",
    "lib/record.lua",
    "lib/report.lua",
    "lib/kbd.lua",
    "lib/waypoints.lua",
    "kbd.lua",
    "mkconfig.lua",
}

print("=============================")
print("   ArtCorpOS Installer")
print("   Flight Stabilization")
print("=============================")
print("")
print("This will install the following files:")
for _, f in ipairs(files) do
    print("  " .. f)
end
print("")
print("Files will be downloaded from:")
print("  ref " .. REF)
print("")
write("Continue? [Y/n] ")
local answer = read()
if answer ~= "" and answer:lower() ~= "y" then
    print("Installation cancelled.")
    return
end
print("")

local ok_http, http = pcall(require, "http")
if not ok_http then
    print("ERROR: HTTP API not available.")
    print("Make sure 'http' is enabled in ComputerCraft config.")
    print("Alternatively, copy files manually from the repo.")
    return
end

-- Phase 1: download EVERYTHING into memory first. Nothing is written
-- until every file is verified, so a network failure can never leave a
-- half-updated install (the classic "one stale lib among new ones" boot).
local downloaded = {}
local failures = {}

for _, filepath in ipairs(files) do
    local url = BASE_URL .. "/" .. filepath
    io.write("  Downloading " .. filepath:sub(1, 40) .. "... ")

    local response, err = http.get(url)
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

        -- Integrity: HTTP 200, non-empty, and not an error page. CC never
        -- returns HTML from raw.githubusercontent, so "<" at the start is
        -- always a CDN/proxy error page.
        local bad = nil
        if code and code ~= 200 then
            bad = "HTTP " .. tostring(code)
        elseif not content or #content == 0 then
            bad = "empty response"
        elseif #content < 40 then
            bad = "suspiciously short (" .. #content .. " bytes)"
        elseif content:sub(1, 1) == "<" then
            bad = "got HTML instead of Lua"
        end
        if bad then
            print("REJECTED (" .. bad .. ")")
            table.insert(failures, filepath .. ": " .. bad)
        else
            print("OK (" .. #content .. " bytes)")
            downloaded[filepath] = content
        end
    end
    sleep(0.2)
end

-- Phase 2: any failure at all = abort loudly with NOTHING written.
-- Re-run install after the connection is fixed; a partial install is
-- worse than none (mismatched libs fail in confusing ways mid-boot).
print("")
print("=============================")
if #failures > 0 then
    print("  INSTALL ABORTED - " .. #failures .. " of " .. #files .. " files failed:")
    for _, f in ipairs(failures) do
        print("    " .. f)
    end
    print("")
    print("  NO files were written. Check the connection / ref, then")
    print("  re-run install. Do NOT run startup on a partial install.")
    print("=============================")
    return
end

local written = 0
local write_failures = {}
for _, filepath in ipairs(files) do
    local dir = filepath:match("(.*/)")
    if dir then
        pcall(fs.makeDir, dir)
    end
    local f = io.open(filepath, "w")
    if not f then
        table.insert(write_failures, filepath)
    else
        f:write(downloaded[filepath])
        f:close()
        written = written + 1
    end
end

print("  Installed " .. written .. "/" .. #files .. " files from ref " .. REF:sub(1, 8) .. ".")
if #write_failures > 0 then
    print("  WRITE FAILURES (disk full / permissions?):")
    for _, f in ipairs(write_failures) do
        print("    " .. f)
    end
    print("  Partial write - re-run install before starting.")
else
    print("")
    print("  Run 'startup' to begin.")
end
print("=============================")
