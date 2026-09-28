-- ArtCorpOS - Installer
-- Paste this into CC terminal: edit install
-- Then run: install
--
-- After install, run: startup

local BASE_URL = "https://raw.githubusercontent.com/Artmoby7674/aeronautics_artcorp_os/master"

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
print("  " .. BASE_URL)
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

local installed = 0
local failed = 0

for _, filepath in ipairs(files) do
    local url = BASE_URL .. "/" .. filepath
    io.write("  Downloading " .. filepath .. "... ")

    local response, err = http.get(url)
    if response then
        local content = response.readAll()
        response.close()

        if content then
            local dir = filepath:match("(.*/)")
            if dir then
                fs.makeDir(dir)
            end

            local f = io.open(filepath, "w")
            if f then
                f:write(content)
                f:close()
                print("OK")
                installed = installed + 1
            else
                print("FAILED (write error)")
                failed = failed + 1
            end
        else
            print("FAILED (empty response)")
            failed = failed + 1
        end
    else
        print("FAILED (" .. tostring(err) .. ")")
        failed = failed + 1
    end

    sleep(0.2)
end

print("")
print("=============================")
if installed > 0 then
    print("  Installed " .. installed .. " files!")
end
if failed > 0 then
    print("  " .. failed .. " files failed.")
end
print("")
print("  Run 'startup' to begin.")
print("=============================")
