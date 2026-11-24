-- Flight OS version. Bumped with EVERY change that reaches the ship, with a
-- short keyword saying what the change aimed at, so the pilot can tell at a
-- glance which build is running. The keyword shows on the ship terminal at
-- start-up, in the log and on the error screen; the cockpit screen (start
-- screen, SHIP tab) shows the number only. Newest first.
local history = {
    { "3.0", "CALM ROLL", "gains for a strong, 1 s late hull; fine prop steps; lag-proof direction check" },
    { "2.9", "DIR CHECK", "take-off check of which way pitch/roll corrections move the hull" },
    { "2.8", "GENTLE STAB", "gentler stabiliser for a naturally steady hull" },
    { "2.7", "ROLL GAINS", "separate roll gains: no roll swinging on a narrow hull" },
    { "2.6", "NO HOLD", "level + rear-thruster braking only; straight-line autopilot" },
    { "2.5", "PARK START", "engine start parks the ship (no tilt on the ground)" },
    { "2.4", "SMOOTH TILT", "long tilt pulses, coast on momentum (no vibration)" },
    { "2.3", "TOUCH FIX", "taps read as pixels; screen, control and input loops split" },
    { "2.2", "SHIP LOG", "diagnostics log on the ship's disk" },
    { "2.1", "AUTOBOOT", "boots straight into v2, restarts itself after an error" },
    { "2.0", "REWRITE", "new flight OS written from scratch" },
}

local latest = history[1]
return {
    number = latest[1],
    keyword = latest[2],
    note = latest[3],
    date = "2026-11-24",
    history = history,
    -- "v3.0 CALM ROLL"
    label = "v" .. latest[1] .. " " .. latest[2],
}
