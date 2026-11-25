-- Flight OS version. Numbering: 2.8, 2.9, 2.20, 2.21 ... 2.99, 2.100 (the part
-- after the dot is a plain counter, never "3.0"). Bumped with EVERY change that reaches the ship, with a
-- short keyword saying what the change aimed at, so the pilot can tell at a
-- glance which build is running. The keyword shows on the ship terminal at
-- start-up, in the log and on the error screen; the cockpit screen (start
-- screen, SHIP tab) shows the number only. Newest first.
local history = {
    { "2.34", "DISPATCH", "ArtCorp remote can send the ship to any of its waypoints; full waypoint list on request" },
    { "2.33", "GEAR UP", "autopilot raises the gear once the ground is out of sensor range" },
    { "2.32", "NO ESCAPE", "pilot can't cancel, land, E-STOP or switch off a summoned ship, or clear an ArtCorp E-STOP" },
    { "2.31", "NUDGE", "level-1 rear nudges when stalled short of the waypoint; re-aim no longer waits on altitude" },
    { "2.30", "FLEET LINK", "ArtCorp remote can scan, E-STOP, force-land, summon and lock this ship over rednet" },
    { "2.29", "TAKE OFF", "TAKE OFF button: title only (no stale \"LIFT TO 6 M\")" },
    { "2.28", "SHIP DISK", "save / load the ship (wiring, learned, air, waypoints) to a floppy" },
    { "2.27", "QUICK START", "A/P climbs at once (no wait for the direction check); take-off +20 m" },
    { "2.26", "W FORWARD", "hover W/S tilt direction matches the ship (W was going backwards)" },
    { "2.25", "AIR SENSE", "measures the air it flies in: ceiling + altitude hold adapt to any world; cruise Y270" },
    { "2.24", "SIDE LEAN", "lean against sideways drift when stopping/landing; turns aim at a fixed heading" },
    { "2.23", "GLIDE", "fixed prop speed holds altitude (air settles it); cruise steers by banking, no tilt" },
    { "2.22", "YAW FLIP", "yaw direction reversed to match the ship; A/P climbs first, then turns" },
    { "2.21", "REAL TIME", "uses the real control tick (~0.2 s, not 0.05 s); black box + call timing logs" },
    { "2.20", "CALM ROLL", "gains for a strong, 1 s late hull; fine prop steps; lag-proof direction check" },
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
    -- "v2.34 DISPATCH"
    label = "v" .. latest[1] .. " " .. latest[2],
}
