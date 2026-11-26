# ArtCorp Flight OS v2

The ship's flight OS. It reads the ship's wiring from `config/<slot>.lua` +
`config/assignments_<slot>.lua`, so a ship that was already set up needs
nothing rewired.

## Running it

`install.lua` installs it and makes it the ship computer's `startup`, so the
ship boots straight into it: tap **START ENGINES** on the cockpit monitor.
The keyboard computer works with it unchanged.

On a computer with no wired ship yet (no slot in `config/`, or the chosen
slot has no assignments file) the monitor shows a first-launch setup:
**IMPORT FROM DISK** (a ship saved with SAVE DISK; the computer restarts on
it) or **SET UP THIS SHIP**, which copies `config/atlas.lua` to a new slot
and asks for each relay/monitor in turn from the ones on the network (TEST
flips one of its faces for 2 s, DETECT watches for a typewriter key), then
shows a short first-flight guide. The first time the normal screen comes up
on the ground a tour explains its main controls; **?** in the top bar
replays it.

The ship computer is never needed in flight. If the OS stops on an error,
the launcher shows the error on the monitor and restarts it 2 s later; if
the ship is in the air at that moment the OS takes control straight away
(clutch kept in, props driven) and the error is listed on the ALERT tab.
Ctrl+T on the ship computer itself (maintenance) stops it.

v2 keeps its own state in `v2/data/`:

| File | Contents |
| --- | --- |
| `waypoints.lua` | Waypoints. An older `config/wp_<slot>.lua` list is imported on first run; headings are converted to compass degrees. |
| `learned.lua` | What the controller learned in flight. Saved at power-off. |
| `slot` | Which ship config was used. |
| `tour_done` | The tour was seen (or skipped): it is not shown again by itself. |
| `tune_local.lua` | Optional overrides for anything in `v2/tune.lua`. |

## Controls

| Input | Hover | Cruise |
| --- | --- | --- |
| W / S | Tilt forward / back while held. Let go: the rear thruster cancels fore/aft drift (AUTO BRAKE). | Rear thrust level +1 / −1, repeating while held. |
| Q / E | Turn left / right. Let go: the rotation is braked to a stop, then the tilts are left alone. | Steer the heading (banked turn). |
| SPACE / CTRL | Tap: altitude goal +5 / −5 m. Hold: climb / descend smoothly. | Same. |
| SHIFT | Switch HOVER ↔ CRUISE. | Same. |
| SPACE while parked | Take off (to 6 m). | – |
| START ENGINES (screen) | Engine start + clutch, from the splash screen. | – |
| SPACE in e-stop | Clear the e-stop and hold where the ship is. | – |
| OFF button | In the air: land, then power off. Press again within 3 s: off now. | Same. |
| UP / DOWN | Change tab. | Same. |

Any stick or altitude input during an autopilot run cancels the run
(**PILOT OVERRIDE**) and holds position.

## The screen (tabs along the bottom)

- **FLY**: attitude indicator, heading tape, altitude, climb, speed, heading,
  target altitude, **lift left** (prop units still free on the busiest prop),
  and bars for each prop (with tilt) and the rear thruster.
- **NAV**: map (north up, auto-zoom, tap to cycle zoom), waypoint list,
  **FLY >**, **DELETE** (tap twice), **SAVE HERE** (asks for a name on the
  keyboard if it's online, otherwise numbers it), **NEW (KBD)** (X, Z,
  heading, name).
- **AUTO**: route progress (DEPART → CRUISE → STOP + ALIGN → LAND), distance,
  ETA, speed against target, altitude against goal, course error, cancel.
- **SHIP**: hardware state, loop timing, disk, and everything learned in
  flight, with a reset button.
- **ALERT**: only what is active right now.
- **CTRL**: TAKE OFF / AUTO-LAND, GEAR, MODE, E-STOP, AUTO BRAKE, RECORD, PRINT LOG,
  LAND + OFF, POWER OFF. In the air, POWER OFF needs a second tap.

## How it flies (and what is different from the original)

| | Original | v2 |
| --- | --- | --- |
| Attitude corrections | Only slow props down, so every correction costs lift. | Move props in pairs (one up, one down), so lift stays the same. The mean only shifts when a prop would pass 0 or 15. |
| Tilt | Lift loss paid back on the average. | Paid back per prop, following the tilt mechanism's travel. Turning doesn't sink the ship. |
| Altitude | PID on altitude plus several special laws (climb law, handover slews, landing walk). | One law everywhere: altitude error → climb-rate target (with a braking curve) → PI on the measured climb rate. |
| Tilt as on/off | Treated as proportional (the comments note it isn't). | Treated as on/off: long pulses with hysteresis (on ≥ 0.8 s, rest ≥ 1.5 s), coasting on momentum in between. |
| Rotation rates | Angular velocity read on assumed body axes. | Derived from the attitude itself, so they're right whichever frame Sable reports in. |
| Steady disturbances | Some trims. | Learned: pitch, roll and yaw trims, hover throttle, and feedforwards that scale with rear power (rear pitch and rear yaw). The last one cancels a "keeps turning right in cruise" torque in proportion to thrust. |
| Rear thruster vs pitch | Rear pitch torque could pin the props: lift and pitch both run out (the step 2→3 drop). | A rear cap backs the thrust off whenever the stabiliser saturates. |
| Autopilot | Climb first, then turn, at a ceiling learned where props reach 13/15. | Straight lines and turns made while stopped: turn at the current (low) altitude, climb, fly straight on the rear thruster with a speed profile that plans its stop (no steering in the last 40 m), brake to rest, re-aim and creep back if more than 10 m off, turn in place onto the saved heading, descend. Lands within roughly 5–15 m of the waypoint. |
| Landing | Walking target down to the ground. | Sink-rate profile on the gear sensor; level, rear thruster cancels fore/aft drift; no position or heading hold. |
| Hover hands-off | Coasts. | Stays level; the rear thruster cancels fore/aft drift. No position or heading hold: the ship cannot strafe, and rolling to slide makes the tail fin turn it (a correction loop). |
| OFF in the air | Ship falls. | Lands, then powers off. A second press forces it. |
| Screen | Tabbed, 16 stock colours. | Tabbed, its own 16-colour palette (falls back to stock if the monitor refuses), attitude indicator, map. |

## Tuning

Every knob is in `v2/tune.lua`, grouped and commented. These are the ones
that depend on how the real ship behaves:

- `tilt.on / off / min_on / min_off`: how the on/off prop tilt is pulsed.
  The props are large, so every tilt flip is a big torque kick. Tilts
  engage only on a clear demand, stay on at least `min_on` (0.8 s), and rest
  at least `min_off` (1.5 s); in between, the ship coasts on its momentum.
  Raise `min_off` for an even calmer ship. Lower it for more precise
  positioning: with long pulses, autopilot landings end within about 10 m
  of the waypoint.
- `attitude.slew`: how fast a prop's speed may change (units/s).
- **Direction check:** on the first take-off (and after RESET LEARNED
  VALUES) the ship nudges itself a little in roll, then pitch, to measure
  which way a correction really moves the hull, and fixes the direction if
  the wiring is the other way round (a reversed correction makes a steady
  hull swing wider and wider). The result is in the log and on the SHIP tab
  (DIRECTIONS). Flight data, one line a second, goes to
  `v2/data/flight.txt`.
- `yaw.sign`: flip it if Q and E turn the wrong way.
- `hover.tilt_sign`: flip it if W moves the ship backwards.
- `attitude.kp / kd`: lower `kp` if the hull rocks; raise `kd` if it overshoots.
- `physics.tilt_lag`: how long the tilt mechanism takes to swing.
- `autopilot.cruise_alt`, `lift_margin`: travel altitude and spare lift.
- `hover.rear_on / rear_off / rear_gain / rear_max`: when and how hard the rear thruster cancels fore/aft drift.
- `autopilot.hop_range / hop_speed`: trips shorter than this fly at the slow hop speed.
- `autopilot.face_r / retry_r`: no steering inside this distance; stopping further than `retry_r` from the waypoint re-aims and creeps back.

## Tested in simulation only

`tests/v2_test.lua`, `tests/v2_ui_test.lua` and `tests/v2_main_test.lua` fly
the real v2 code against `tests/v2/sim.lua`. The simulator is a 3-D rigid
body with prop spin-up lag, tilt servo travel, one tick of telemetry delay,
an off-centre rear thruster and a gear sensor. The suite covers:

- takeoff, hover and trim
- turning at 230 m (sank under 0.5 m)
- auto-land (touchdown about 0.4 m/s)
- a 1.4 km trip with an off-centre rear thruster (landed 2 m from the
  waypoint, attitude under 5°)
- a hover hop, e-stop, unflip, and a sweep of inertia × prop lag × delay
- the full main loop: boot, clutch, touch, takeoff, an autopilot hop,
  power-off

What the simulator can't know: the real ship's inertia, prop and tilt lag,
and how far the rear thruster sits from the centre of mass. The tests sweep
those instead of trusting one value.

**Known limit:** auto-unflip rights the hull, but in the simulator rolling
through 90° (no vertical lift) loses more height than the ship has. Expect
the same unless the real ship rolls much faster.

`python3 tests/render_v2.py` writes PNGs of every screen to `hud_shots/v2/`.
