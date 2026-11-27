-- Re-run the peripheral setup wizard by hand from the ship computer's shell:
-- v2/wizard. Stop the running OS first (hold Ctrl+T on the ship computer).
-- It asks for every relay and the cockpit monitor again, rewrites
-- config/assignments_<slot>.lua, then starts the flight OS (as `startup`).
package.path = "/v2/lib/?.lua;/v2/lib/ui/?.lua;" .. package.path
for _, m in ipairs({ "wizard", "config", "util", "version" }) do package.loaded[m] = nil end
local r = require("wizard").run("v2", { why = "asked for (v2/wizard)" })
if r == "ready" then shell.run("/startup") end
