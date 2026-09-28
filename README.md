# ArtCorpOS

A ComputerCraft flight stabilization and control system for Create:Aeronautics ships.

## Requirements

- Minecraft with the Create:Aeronautics mod
- CC:Tweaked
- CC:Sable addon
- CC:Graphics (pixel HUD)

## Quick Install

In a ComputerCraft terminal:

```
wget run https://raw.githubusercontent.com/Artmoby7674/aeronautics_artcorp_os/master/install.lua
```

Also drop in the ship identity file for your hull (Atlas example ships with the repo as `ship.lua`):

```
ship.lua   -- return { id="Atlas", name="Atlas", profile="atlas" }
```

Then run:

```
startup
```

### First-time setup flow

1. Build the ship  
2. Install the OS + `ship.lua` (identifies the computer as that ship)  
3. `startup` — shows **which ship** you are on  
4. Save-slot menu: load a config, or create a new save in an empty slot  
5. Setup wizard: plug each relay **one at a time** (includes **engine relay**), then the optional network steps: **[3c] printer** (connect it → wizard pins its network name, or skip → runtime auto-find) and **[3d] keyboard computer** (run `kbd` on the second computer — the ship waits for its hello to pair, or skip)  
6. Attach a **wired modem** to the ship computer for that network (printer + keyboard are found over it)  
7. Jump in the pilot seat → splash → **boot** button  

### Save-slot menu (setup phase only)

| Key | Action |
|-----|--------|
| W/S | Move cursor |
| Space | Load slot / create new save in empty slot |
| D | Delete (D again confirms, Space cancels) |

Config `version` is stamped into `config/assignments_*.lua`. If you bump the config version (or a required peripheral is missing), the **full re-wizard** runs again so you can redo wiring.

## Boot sequence (Atlas, when `engine_auto_start` + `clutch` features are on)

Loading bar = **5s** (config `engine.boot_seconds`):

| Time | Action |
|------|--------|
| 0–3s | Engine **starter** high (relay **left**) |
| 3–4s | Starter off, wait |
| 4s | **Clutch** couples (relay **right**), stays on while OS is on |
| 5s | Flight HUD ready |

**Shutdown** (circle, top-left): allowed landed or airborne — decouples clutch (right→0), cuts all outputs (e-stop), returns to splash. In the air the ship loses all thrust, so expect it to drop.

`fuel_level` feature + `fuel` config block are reserved for a future fuel-container readout (not wired yet).

## Manual Install

Copy all files from this repo into a CC:Tweaked computer's filesystem:

```
aeronautics_ship_os/
  startup
  ship.lua
  config/atlas.lua
  lib/pid.lua
  lib/hardware.lua
  lib/flight.lua
  lib/os_main.lua
  lib/hud.lua
  lib/gfx.lua
  lib/font.lua
  lib/record.lua
  lib/report.lua
  lib/kbd.lua
  lib/waypoints.lua
  kbd.lua          -- install on the KEYBOARD computer, not the ship
  install.lua
  mkconfig.lua
```

## Physical Setup

### Peripherals

| Device | Count | Purpose |
|--------|-------|---------|
| Computer | 1 | Runs the OS |
| Wired Modem | 9+ | One on computer, one per relay/monitor |
| Networking Cable | - | Connects all modems in a chain |
| Redstone Relay | 8 | Bridges computer to redstone links |
| Monitor (optional) | 1 | HUD display |

### Relay placement (Atlas)

**Input Relay 1** (WASD): Front=W, Back=S, Left=A, Right=D  

**Input Relay 2** (yaw + altitude): Left=Q, Right=E, Front=Space, Back=Ctrl  
(Relays face east; front/back are the east/west-facing link sides on that body.)

**Aux relay**: Left=shift receiver, Front=gear emitter, Back=proximity receiver  

**Engine relay** (new):  
- **Left** → engine start link (pulsed 3s on boot)  
- **Right** → clutch link (held while OS on; off on shutdown)  

**Output Relays** (one per prop): Front=tilt fwd, Back=tilt bwd  
**Slow-down link** (inverted redstone): FL/RL → relay **Left** face, FR/RR → relay **Right** face  
- Engine runs ~256 RPM always; higher redstone = more braking  
- Landed / stopped = signal **15**; full thrust = signal **0**  

**Rear Thruster Relay**: Front=fw, Back=bw (inverted slow-down: 15 = stopped, 0 = full speed), **Top=rev** (reverse: 15 = reversed — used by the auto-land fore/aft hold)  

**Proximity / gear**: sensor is on the **bottom of the front landing gear**. Any active proximity forces gear **down** (G cannot retract while prox &gt; 0). Gear deploy briefly reads closer (~6 blocks) before settle. The sensor feeds the aux relay **back** face as **analog** — CC redstone relays read analog fine (`getAnalogInput`, 0–15); the flight-tab gear line shows the live value (`DN <n>`). A **latched landed** requires **4 consecutive ticks** at `landed_threshold` (spike filter).

## Controls

| Input | Function |
|-------|----------|
| W/S | Hover: tilt collective fw/bw · Cruise: step rear goal bar ±1 (hold repeats every 0.2 s) |
| Q/E | Yaw left/right (hover only — cruise rear is W/S speed level only) |
| Space / Ctrl | Altitude target +/− (any mode; in cruise the ship also pitches up to ±15° toward the goal) |
| Shift redstone | Hover ↔ Cruise (if ship has `cruise_mode`) |
| Engine relay front/back (UP/DOWN) · keyboard ↑/↓ | Switch monitor tab ↑/↓ (one step per press; the relay is wired to the typewriter links on the engine relay, the arrow keys mirror it and both stay live during autopilot) |
| NAV tab touch buttons | **REC** (flight recorder), **PRINT** (3-page report), **QUICK WP** / **NEW WP** (waypoint entry via the keyboard computer) |

### ACTIONS tab

Actions are **monitor-only** (no keyboard shortcuts): **AUTO-LAND**, **GEAR**, **E-STOP**, **AUTO-TUNE**, **AUTOPILOT** (waypoint window — see below) and **CANCEL A/P** (aborts a running autopilot; highlighted green while one is active). Features the ship lacks are dimmed. The red **stop button** (top-left) powers off back to the boot splash and resets session state (HOVER mode, default tab, closed waypoint window, stopped recorder) so the next boot matches a first-time start.

### NAV tab: recorder & printer report

- **REC / STOP**: records the ship's world position every **10 s** (up to 3600 samples = 10 h, memory only — a reboot clears it, so print before shutting down). The status line under the buttons shows `REC m:ss | n SAMP` while recording.
- **PRINT**: prints a **3-page report** on the network printer: page 1 = header (title, date, duration, sample count, 3D path length, X/Y/Z min..max) + **X(t) graph**, page 2 = **Y(t)**, page 3 = **Z(t)**. Graph time axis has a tick every **5 s** (labels auto-thin to fit); points are `*`, column-connected. The button dims when no printer is found; printer = `config.peripherals.printer` if pinned, otherwise `peripheral.find("printer")` (auto-found on the wired network). Errors: no recording, out of paper/ink, tray full.

### Waypoints & AUTOPILOT

- **QUICK WP** (NAV tab): captures the current **X, Z and heading**, then asks for a **name** on the keyboard computer. Names: **one word, max 10 characters, letters/digits only** (digits allowed — `Base2` is fine).
- **NEW WP** (NAV tab): keyboard prompts in sequence **X → Z → Heading → Name** for planning a location you're not at yet. Numbers are validated; heading is normalized to 0–359°.
- Tapping the active button again **cancels** the keyboard prompt (also on timeout/shutdown). Status line shows `KBD: enter <field> (tap to cancel)`.
- Waypoints persist in **`config/wp_<slot>.lua`** (same slot as `pid_<slot>.lua`).
- **AUTOPILOT** (ACTIONS tab) opens a full-screen **waypoint window**: list of saved waypoints → tap one for a popup (name, X/Z/heading) with a **blue arrow `>>>` = fly there (auto-pilot)** and a **red cross = delete** (confirmation screen), plus a **grey cross** to go back. The list scrolls with `^`/`v` when there are more entries than fit.
- **`>>>` starts the AUTOPILOT**, a full sequence that flies, lands and powers the ship down by itself: **aim** (HOVER — **two steps; the climb always runs first, even for short hops**): ① **climb** — the altitude goal rises **+35 m/s** (`AP_CLIMB_GOAL_RATE`) until prop demand hits **13** (`AP_CLIMB_TOP` = slow-down signal 2, a little under max rpm); the goal then **freezes** and a velocity-profile law (`v_des = 0.6 × height error`, no drag means a fixed-thrust climb would sail past) **settles the ship exactly at the frozen goal** (goal hard-capped at `max_altitude − AP_CEIL_MARGIN`; **stall failsafe** — if the ship gains **less than 5 m within 3 s** of the climb, the goal freezes at the current altitude and the run moves straight to the turn step; the turn starts the moment **vertical motion stops at the goal band** (one-sided check — fires at the first stop, including an overshoot peak) and the altitude captured at that moment is **held** through the rotation, never re-captured); ② **turn** — rotate onto the bearing via a **PD yaw command** (angle error + turn-rate damping, so the ship brakes onto the bearing instead of coasting through it), Q/E assist live; leaves only once heading **and** rotation have settled) → **cruise** (CRUISE — sustained **roll-bank** steers the heading with a **rate lead** (`bank = KP × (err − 0.6 × yaw_rate)` — the command eases off before the bearing is reached, killing turn overshoot), rear level tapers with distance for anti-overshoot) → **correct** (if heading error > 10°: *stay in cruise*, reverse-brake to ~10 m/s, bank back onto the bearing, re-accelerate) → **arrive** (speed-controlled brake down onto the waypoint XZ) → **align** (HOVER — rotate onto the stored heading within 2°, same PD + rotation-settled gate) → **land** (auto-land → full `powerOff` on touchdown). An **unflip** that fires mid-run **pauses** the sequence and resumes it when upright. **Short hop / final approach**: once inside **500 m** (`AP_HOVER_RANGE`) — at enable or **at any later moment, including mid-cruise** — the travel legs run on **hover controls only**: the ship steers with the yaw stick and moves with the binary W/S tilt drive (`apHoverDrive`: speed capped at `AP_HOVER_SPEED`, braking curve `v² ≤ 2·a·room`), **the rear never spins up and cruise mode is never entered from that point on**.
- **While the autopilot runs most manual flight controls are inert**: WASD, Space/Ctrl (and shift/mode, land/gear/tune) do nothing — the only ways out are the **CANCEL A/P** button (ACTIONS tab), **E-STOP** or shutdown. **The manual Q/E yaw stick is the exception: it stays live in the autopilot's two rotation phases — aim (not facing the goal yet) and align (above the waypoint) — where it adds to the automatic yaw command; cruise/correct/arrive ignore it** (bank-to-turn owns the heading there with the rear at full speed). **Tab switching (UP/DOWN relays or the keyboard arrow keys) stays live**, and the chrome/tab outlines turn **light green** so you can see the ship is flying itself. The NAV tab's autopilot row shows **objective distance, route progress % and ETA** (`--` when nearly stopped).
- Knobs at the top of `lib/flight.lua`: geometry/timing (`AP_AIM_TOL`, `AP_OFFCOURSE`, `AP_CORRECT_SPEED`, `AP_BRAKE_R`, `AP_ARRIVE_R`, `AP_ALIGN_TOL`, `AP_LEVEL_PER`, `AP_PHASE_TIMEOUT`) and the two **signs you may need to flip in-game**: `AP_YAW_SIGN` (aim/align turn direction) and `AP_BANK_SIGN` (which way cruise banking turns). Yaw PD tuning: `AP_YAW_LEAD` (P multiplier — turn-rate speed), `AP_YAW_RATE_DAMP` (braking strength, deg/s per full stick), `AP_YAW_STILL`/`AP_YAW_EXIT_RATE` (settle gates). Bank rate lead: `AP_BANK_RATE_LEAD`. Aim climb: `AP_CLIMB_GOAL_RATE` (goal rise rate, b/s), `AP_CLIMB_TOP` (prop demand cap and goal-freeze trigger — 13 = slow-down signal 2), `AP_CLIMB_KP`/`AP_CLIMB_APPROACH`/`AP_CLIMB_MAX_V` (velocity-profile law: how hard it chases the goal and how it brakes to a stop at it), `AP_CLIMB_TOL`/`AP_CLIMB_STILL` (settle gates to finish the climb), `AP_CLIMB_MIN_GAIN`/`AP_CLIMB_MIN_PT` (stall failsafe: < gain within pt → hold altitude, skip to turn), `AP_CEIL_MARGIN` (goal hard-cap = `max_altitude − margin`). Short-hop hover travel: `AP_HOVER_RANGE` (500 m: distance that switches to hover-only travel — at enable or any time later), `AP_HOVER_SPEED` (tilt-travel speed cap), `AP_HOVER_ACCEL` (assumed full-tilt braking for the curve — **lower it if the ship overshoots the waypoint when braking**, raise it if it brakes too early), `AP_HOVER_BAND` (hysteresis band). Requires airborne, no e-stop/auto-land/unflip at start.

### Network keyboard (kbd)

The waypoint prompts are typed on a **plain computer on the same wired network** as the ship (the ship needs a modem too):

1. Copy **`kbd.lua`** from the repo root to the keyboard computer.
2. Run `kbd` (or rename it to `startup` for auto-run).
3. It announces presence every 3 s; the ship **auto-pairs on first contact** (no IDs to configure) and shows the prompt on both screens. The keyboard validates input locally too (numbers, name rules) and shows `Waiting for the ship computer...` between requests.

Traffic **keyboard → ship** runs on a dedicated raw modem channel (39999), not rednet: rednet's receive side dedups by an unseeded `math.random` message id that is identical across computers, so the ship could silently reject the keyboard's packets as duplicates (seen as a permanent one-way link). **Ship → keyboard** stays on rednet (that direction is proven working). Every answer is **confirmed by the ship** (`ack`/`nack`) — the keyboard shows `Confirmed by ship.` in green, or a red `Ship did NOT confirm (3 tries)` / `Ship rejected: <why>` if not. The keyboard's header line shows the live link state: `ship: online` (both directions), `ONE-WAY link: kbd->ship NOT working?` or `ship NOT heard for Ns`. On the ship, `Kbd link: rx rednet=… raw=… modem=… raw_ch=…` in the boot print and `kbd:`/`raw op=` lines on the terminal show exactly which packets arrive.

### Flight laws (drone-style)

- **Altitude**: `thrust = hover_throttle + PID` (default hover **6**/15), applied **uniformly** to all four props. Create Aeronautics gravity is **g = 11 m/s²** (`physics.gravity`); default gains are derived for that plant (ωn≈0.8, ζ≈0.8). The D term uses **climb rate** (no kick on Space/Ctrl steps) and I only integrates near the target (anti-windup). At the target altitude props keep spinning — they do not cut to 0.
- **Pitch / roll**: automatic **stability** via **prop speed reductions only** (never tilt, never accelerating a prop above the altitude-PID base): `corr = clamp(PID(0 − attitude) − 0.25 × rate, ±cap)`, with a **stepped cap by attitude error**: **0** below 2° (deadband — larger and the ship leans/strafes off-course, smaller and the wobble loop returns), **2** at 2–6°, **4** at 6–12°, **6** above 12° (high-angle authority raised from the old 4 — "not strong enough at high angles"; rate damp raised 0.15→0.25). Strength is quantized, so **precision comes from time**: the capped correction fires as **short pulses** on a 0.6 s window with a **duty cycle growing with the error** (0 → 0.5 → 1.0 across the 2–10° band — floor raised from 0.3, the old train was off 70 % of the time at low error), giving small errors brief corrections instead of a continuous hold. Only the pair needing less lift slows down; the opposite pair stays at base, so the altitude PID absorbs the small mean-thrust loss. **Stability always wins under the autopilot** (AP-driven forward tilt does *not* fade it); only a **manual W/S stick** fades the pitch duty to zero — the pilot's angle-maneuver override. **During auto-landing the roll stabiliser is deliberately strengthened** (deadband 2°→1°, max cap 4→5, duty starts at 0.6; above 12° both axes get +2 units) so touchdown happens on a levelled hull — this is speed-diff only, because "A/D roll" here is really tilt (pitch/yaw), never a true roll. Gains come from `config/pid_<slot>.lua` (`pitch`, `roll`).
- **Auto-unflip**: if pitch **or** roll stays within 15° of 180° (**≥165°**) for **5 s** (airborne, not e-stopped), a recovery sequence runs: a black-on-red **AUTOMATIC UNFLIP SEQUENCE** banner (header content area + alarms row), the **left-of-computer redstone link** reverses all lift propellers, thrust goes **full**, and the pair on the **opposite side of the flip** is **cut** for a 1.5 s asymmetric kick; then **4 s of pure ascent** (uniform full reversed thrust, no cuts) to gain altitude while inverted; then a **violent righting drive** (P=6, D=1.5, no deadband, reduce-only from full speed, polarity inverted while reversed) runs until attitude ≤ 10°. The reverse link drops below 90° so reversed thrust can't press a levelled ship down; ≤ 10° ends the sequence (reverse off, PIDs reset, 5 s cooldown), and a **20 s hard timeout** aborts it (reverse off, normal law resumes). E-stop / landing / safety cut all kill the reverse link. Sign knobs at the top of `lib/flight.lua` (`UNFLIP_ROLL_CUT`, `UNFLIP_PITCH_CUT`, `UNFLIP_DRIVE_POL`) if a phase kicks the wrong way in-game.
- **Tilt** is **direct piloting only** (W/S collective, Q/E yaw stick). There is currently **no hands-off heading actuation** (the cruise rear differential / heading-hold drive was removed); the autopilot's aim/align steer through the **yaw-stick path** with a PD on heading error + turn rate. The ship **cannot strafe** (props don't tilt left/right) — A/D controls are removed.
- **Rear thrusters**: **off in hover** (signal 15 = stopped); entering **cruise** puts them at **speed level 1** (signal 14) automatically. They respond **only** to the W/S goal bar — no yaw differential, no other controls. Both relay faces receive the same level.
- **Cruise speed**: a **15-segment goal bar** (levels 1–15) — each W press steps **+1**, holding repeats **every 0.2 s** (S = −1, floor **level 1**). Signal = **15 − level**: level 1 → 14 … level 15 → **0 (no redstone = reduction off)**; level 0 (hover/e-stop) → signal 15 = stopped. Wiring is **inverted slow-down** (same as the main props' speed face). Reverse = the REAR relay's **top** face (`output_map.REAR.rev`, `features.rear_reverse`).
- **Auto-landing** (L / ACTIONS): gear down → ARMED (sensor settle) → DESCEND: the altitude target walks down at `limits.land_descent_rate` (**12.0 m/s** default), freezing once the sensor reaches `landed_threshold` so the debounced ground-contact latch (4 ticks) can finish. **Runaway-goal safety**: if the goal ends up **more than 20 m below the ship while it isn't falling** (ground latch never fired, goal still walking), the goal freezes and the OS **shuts down** — clutch decoupled (props free of the engines) and the monitor back to the splash screen (climb-rate guard keeps a fast mid-air catch-up from tripping it). The heading **recorded the moment auto-land fires** is held for the whole sequence (pilot Q/E ignored; if the ship rotates, the yaw hold drives it back to the recorded heading). During ARMED/DESCEND the ship **holds fore/aft position with the rear thrusters** (gentle pulsed P-damp on longitudinal velocity — nose-axis projection from the orientation quaternion, gain **2**, 0.3 m/s deadband; corrections fire as **short bursts on a 0.6 s window** with duty growing with the excess speed but capped at **50%**, so the rear only nudges instead of shoving; drifting forward = **reverse link ON + normal thrust** pushes backward, backward drift = thrust alone — set `features.rear_reverse = false` if the reverse face isn't wired, then only backward drift is countered). Flip `LAND_FA_SIGN` in `lib/flight.lua` if the rear push amplifies drift.
- **Landed idle**: OS on + grounded → uniform prop speed **1** (slow-down wire **14**, blades creep, no lift). Full stop on shutdown / e-stop.
- **Auto-tune**: if `config/pid_<slot>.lua` is missing (first boot or deleted), altitude auto-tune arms and runs on the first airborne HOVER; gains are saved back to that file. Delete the file to re-tune.
- **Coordinates**: the ship's world position (logical pose) is sampled **every control tick** into `state.position` and exposed via `getStatus().position` — the **NAV tab** shows live **X / Y / Z** (was `N/A`). Touchdown records `getStatus().land_position` (world coords at landing) as the first reference point for the upcoming autopilot work.

Keys that need a missing feature reply with `No … on this ship`.

## Ship builders: config wizard

On the CC computer, run:

```
mkconfig
```

It asks for identity, features, relay names, and limits, then writes `config/<slot>.lua`. Point `ship.lua` `profile` at the slot name and run `startup` to wire the relays.

## Ship features (multi-ship ready)

Configs declare what the hull actually has under `features`:

```lua
features = {
    engine_auto_start = true,
    clutch = true,
    auto_land = true,
    cruise_mode = true,
    auto_tune = true,
    fuel_level = false, -- reserved
}
```

Future flow: other players download the OS + a ship config pack + their own `ship.lua`, then run `mkconfig` / `startup` for their relays. Ships without engine auto-start just set those flags false and omit `engine_relay`.

## Configuration

Edit `config/atlas.lua` (or your ship’s config), or generate one with `mkconfig`:

- `ship` identity lives in root `ship.lua`
- `features`: which OS subsystems this hull enables
- `engine`: starter/clutch timing and sides
- `computer_offset`, `peripherals`, `limits`, `pid`, `fuel` (reserved)
- `config/pid_<slot>.lua` — auto-written tuned altitude/pitch/roll/yaw/speed gains; delete to re-run auto-tune

## License

MIT
