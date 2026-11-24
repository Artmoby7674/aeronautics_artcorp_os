-- ArtCorp Flight OS v2 launcher. From the ship computer's shell:   v2/start
-- (the original OS stays the default `startup`; this runs v2 instead, once).
package.path = "/v2/lib/?.lua;/v2/lib/ui/?.lua;" .. package.path
local ok, err = pcall(function() require("main").run() end)
if not ok then
    printError("v2 crashed: " .. tostring(err))
    pcall(function() require("draw").shutdown() end)
end
