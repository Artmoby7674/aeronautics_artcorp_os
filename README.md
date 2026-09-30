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

Actions are **monitor-only** (no keyboard shortcuts): **AUTO-LAND**, **GEAR**, **E-STOP**, **AUTOPILOT** (waypoint window — see below) and **CANCEL A/P** (aborts a running autopilot; highlighted green while one is active). Features the ship lacks are dimmed. The red **stop button** (top-left) powers off back to the boot splash and resets session state (HOVER mode, default tab, closed waypoint window, stopped recorder) so the next boot matches a first-time start.

### NAV tab: recorder & printer report

- **REC / STOP**: records the ship's world position every **10 s** (up to 3600 samples = 10 h, memory only — a reboot clears it, so print before shutting down). The status line under the buttons shows `REC m:ss | n SAMP` while recording.
- **PRINT**: prints a **3-page report** on the network printer: page 1 = header (title, date, duration, sample count, 3D path length, X/Y/Z min..max) + **X(t) graph**, page 2 = **Y(t)**, page 3 = **Z(t)**. Graph time axis has a tick every **5 s** (labels auto-thin to fit); points are `*`, column-connected. The button dims when no printer is found; printer = `config.peripherals.printer` if pinned, otherwise `peripheral.find("printer")` (auto-found on the wired network). Errors: no recording, out of paper/ink, tray full.

### Waypoints & AUTOPILOT

- **QUICK WP** (NAV tab): captures the current **X, Z and heading**, then asks for a **name** on the keyboard computer. Names: **one word, max 10 characters, letters/digits only** (digits allowed — `Base2` is fine).
- **NEW WP** (NAV tab): keyboard prompts in sequence **X → Z → Heading → Name** for planning a location you're not at yet. Numbers are validated; heading is normalized to 0–359°.
- Tapping the active button again **cancels** the keyboard prompt (also on timeout/shutdown). Status line shows `KBD: enter <field> (tap to cancel)`.
- Waypoints persist in **`config/wp_<slot>.lua`** (same slot as `pid_<slot>.lua`).
- **AUTOPILOT** (ACTIONS tab) opens a full-screen **waypoint window**: list of saved waypoints → tap one for a popup (name, X/Z/heading) with a **blue arrow `>>>` = fly there (auto-pilot)** and a **red cross = delete** (confirmation screen), plus a **grey cross** to go back. The list scrolls with `^`/`v` when there are more entries than fit.
- **`>>>` starts the AUTOPILOT**, a full sequence that flies, lands and powers the ship down by itself: **aim** (HOVER — **two steps; the climb always runs first, even for short hops**): ① **climb** — the **target altitude is fixed** and the ship flies to it on a **velocity PID** closed on the *measured* climb rate (`sublevel.getLinearVelocity`) — see **Climb law** below. In short: a **constant-rate transit** (linear altitude gain, steady moderate collective) then a **braking profile** (`v_des = min(AP_CLIMB_V, √(2·a_brake·remaining))`) so the ship arrives at the goal with ~zero vertical speed and **never sails over it** (at/above the goal the setpoint is pinned at 0 and the collective is capped at hover, so the ship can coast to a stop *on* the goal but is never pushed back over). The demand is a **prop-physics feedforward** (`hover × e^(0.004×(H−63)) / (1 − rate/25)` — air pressure halves thrust by y260 and a fast climb eats more, so a fixed feedforward under-thrusters at altitude and the old 0..13 clip could not even hover up there) plus the velocity PID, run through a **slew limiter** (`AP_CLIMB_SLEW_ATTACK`/**RELEASE** prop/s) so the collective can no longer jump 0↔15 in a tick — the old bang-bang (props slammed to max, then cut to zero, ship fell like a brick and overshot again) is exactly what the fixed target + brake profile + slew limit remove (**y280 is a floor, not a ceiling** — see **Ceiling discovery** below; **stall failsafe** — if the ship gains **less than 5 m within 3 s** of the climb, the goal freezes at the current altitude and the run moves straight to the turn step; the turn starts once the ship is at/above the goal band (`AP_CLIMB_TOL`) **and** its vertical speed is at rest (`AP_CLIMB_STILL`) for `AP_CLIMB_SETTLE_HOLD` seconds — the braked arrival leaves no momentum, so this is a short clean confirmation; the altitude captured at that moment is **held** through the rotation, never re-captured); ② **turn** — rotate onto the bearing via a **PD yaw command** (angle error + turn-rate damping, so the ship brakes onto the bearing instead of coasting through it), Q/E assist live; leaves only once heading **and** rotation have settled) → **cruise** (CRUISE — sustained **roll-bank** steers the heading with a **rate lead** (`bank = KP × (err − 0.6 × yaw_rate)` — the command eases off before the bearing is reached, killing turn overshoot), rear level tapers with distance for anti-overshoot; on entry (and every rear re-acceleration) the level **ramps at `cruise_ramp` (8/s)** instead of jumping 0→15 — the instant kick pitched the nose into the entry dive **Banking at altitude**: a bank is reduce-only, so it is paid for out of the mean thrust, and near the ceiling there is little left to give. The bank **is not** switched off for that reason — an earlier revision gated it on `hmax − hover`, which is **0.0 at the ceiling by construction**, so heading control was disabled exactly where the ship spends the whole leg and the run fell back onto hover tilt-yaw for **83%** of the cruise (the "cruise still uses hover yaw control" report). Its justification was fabricated: the "8° of bank → 44°/s of yaw" figure was read off a correlation, not a cause, and the test plant has **no bank→yaw coupling at all** (cruise zeroes prop tilt, so `fz = 0` and the yaw couple is identically zero; a pure roll differential held for 100 ticks moves yaw rate by 0.000°/s). The thrust cost of a bank is paid for by `AP_BANK_ALT_FADE` and by the adaptive stabiliser taper, neither of which disables the heading controller) → **correct** (if heading error > 10°: *stay in cruise*, reverse-brake to ~10 m/s, bank back onto the bearing, re-accelerate) → **arrive** (speed-controlled brake down onto the waypoint XZ) → **align** (HOVER — rotate onto the stored heading within 2°, same PD + rotation-settled gate) → **land** (auto-land → full `powerOff` on touchdown). An **unflip** that fires mid-run **pauses** the sequence and resumes it when upright. **Short hop / final approach**: once inside **500 m** (`AP_HOVER_RANGE`) — at enable or **at any later moment, including mid-cruise** — the travel legs run on **hover controls only**: the ship steers with the yaw stick and moves with the binary W/S tilt drive (`apHoverDrive`: speed capped at `AP_HOVER_SPEED`, braking curve `v² ≤ 2·a·room`), **the rear never spins up and cruise mode is never entered from that point on**.
- **While the autopilot runs most manual flight controls are inert**: WASD, Space/Ctrl (and shift/mode, land/gear) do nothing — the only ways out are the **CANCEL A/P** button (ACTIONS tab), **E-STOP** or shutdown. **The manual Q/E yaw stick is the exception: it stays live in the autopilot's two rotation phases — aim (not facing the goal yet) and align (above the waypoint) — where it adds to the automatic yaw command; cruise/correct/arrive ignore it** (bank-to-turn owns the heading there with the rear at full speed). **Tab switching (UP/DOWN relays or the keyboard arrow keys) stays live**, and the chrome/tab outlines turn **light green** so you can see the ship is flying itself. The NAV tab's autopilot row shows **objective distance, route progress % and ETA** (`--` when nearly stopped).
- Knobs at the top of `lib/flight.lua`: geometry/timing (`AP_AIM_TOL`, `AP_OFFCOURSE`, `AP_CORRECT_SPEED`, `AP_BRAKE_R`, `AP_ARRIVE_R`, `AP_ALIGN_TOL`, `AP_LEVEL_PER`, `AP_PHASE_TIMEOUT`) and the two **signs you may need to flip in-game**: `AP_YAW_SIGN` (aim/align turn direction) and `AP_BANK_SIGN` (which way cruise banking turns). Yaw PD tuning: `AP_YAW_LEAD` (P multiplier — turn-rate speed), `AP_YAW_RATE_DAMP` (braking strength, deg/s per full stick), `AP_YAW_STILL`/`AP_YAW_EXIT_RATE` (settle gates). Bank rate lead: `AP_BANK_RATE_LEAD`. **Climb law** (see **Climb law** section): `AP_CLIMB_V` (**8 m/s** — constant transit climb rate; raise for a faster ascent, lower for a gentler one), `AP_CLIMB_BRAKE` (**0.9 m/s²** — assumed braking capability, only shapes the brake profile; the velocity PID absorbs the error, so keep it safe/conservative), `AP_CLIMB_KP`/`AP_CLIMB_KI` (velocity PI on measured climb rate), `AP_CLIMB_VLIM` (hard clamp on |v_des|), `AP_CLIMB_TOL`/`AP_CLIMB_STILL`/`AP_CLIMB_SETTLE_HOLD` (arrival gates: at/above goal, speed at rest, held this long), `AP_CLIMB_STALL_GAIN`/`AP_CLIMB_STALL_PT` (stall failsafe: < gain within pt → hold altitude, skip to turn), `AP_CLIMB_TIMEOUT` (dedicated climb failsafe; the generic `AP_PHASE_TIMEOUT` is a *turn* failsafe and is too short for a long climb), `AP_CLIMB_SLEW_ATTACK`/`AP_CLIMB_SLEW_RELEASE` (collective slew limit, prop/s — attack fast, release slow so the lift is never cut in one tick), Ceiling discovery: `AP_CEIL_FLOOR` (**280** — cruise never goes below it, and it is not a stopping point), `AP_CEIL_LIFT` (**13** — prop speed at which the climb stops; the 2 units still in hand are the safety margin, so no extra subtraction is applied), `AP_CEIL_HARD` (**450** — absolute guard, only catches a mis-tuned `hover_throttle`), `AP_BANK_ALT_FADE` (4° — altitude error over which the cruise bank fades to zero so a recovery climb is flown level instead of banked). **Adaptive stabiliser gain**: `AP_STAB_ADAPT_KNEE` (0.5 — headroom fraction below which attitude authority starts tapering) and `AP_STAB_ADAPT_MIN` (0.2 — taper floor, so a leaning hull is still caught); the net authority **shrinks as the props speed up**, which is what damps the high-altitude wiggle. **Stabiliser damping**: `AP_STAB_RATE_K` (0.25 — rate feedback gain, shared by hover and cruise) and `AP_STAB_RATE` (1.5 — max hover authority for that rate term). The rate term is deliberately **outside** the 2° attitude deadband and outside the duty schedule: the deadband exists so the *proportional* term leaves a trimmed hull alone, but the one moment a hull needs damping is the moment it passes back through level carrying the momentum its own correction just gave it. With the rate term inside the deadband the hull coasts straight through and out the far side — the "PID doesn't dampen the momentum it gave, so it wiggles again" report. (The former headroom gate `AP_BANK_HEADROOM`/`AP_BANK_AFFORD` was **removed** — see Banking at altitude.) Yaw-compensation trim: `limits.yaw_roll_coupling`/`yaw_pitch_coupling` (**default 0 = disabled**) and `AP_YAW_FF_MAX` (3° ceiling on it). Prop-physics feedforward: `AP_PRESS_K`/`AP_PRESS_REF` (air-pressure curve `e^(-0.004(H-63))` from Create's DimensionPhysics — rarely touched), `AP_AIRFLOW` (m/s through the prop for the `1 − v/airflow` climb-rate term, default 25 ≈ 4 sails @ 256 rpm — **raise it if a fast climb still sags, lower it if the climb overshoots**). The rear ramp uses the ship's `limits.cruise_ramp` (default 8 level/s). Short-hop hover travel: `AP_HOVER_RANGE` (500 m: distance that switches to hover-only travel — at enable or any time later), `AP_HOVER_SPEED` (tilt-travel speed cap), `AP_HOVER_ACCEL` (assumed full-tilt braking for the curve — **lower it if the ship overshoots the waypoint when braking**, raise it if it brakes too early), `AP_HOVER_BAND` (hysteresis band). Requires airborne, no e-stop/auto-land/unflip at start.

### Climb law (smooth, never overshoots)

The climb is a **velocity PID** on the *measured* vertical speed (`sublevel.getLinearVelocity`, exposed as `state.climb_rate`). You do **not** need a separate velocity sensor: the computer already reads true vertical speed from the ship's physics.

The target altitude is **fixed** — it does not move while the ship flies to it. An earlier version chased a goal that *rose* at 60 m/s while the ship climbed at ~5 m/s, so the height error was always enormous, the demanded rate sat on its clamp, and the collective was pinned at 15/15 for the whole climb; at the end the error flipped and the collective collapsed to 0, dropping the ship to fall like a brick. The law is now the standard, boring version:

1. **Linear transit.** Far from the goal the ship holds one modest climb rate (`AP_CLIMB_V`, 8 m/s), so altitude gain is linear and the collective sits at a steady moderate value.
2. **Braking profile.** As the goal approaches, the rate setpoint becomes `v = √(2·a_brake·remaining)` — the fastest rate from which the ship can still decelerate to zero exactly at the goal. Arrival is therefore smooth and overshoot is structurally prevented, not merely hoped for.
3. **Never over the goal.** At or above the target the rate setpoint is pinned at 0 (never positive) and the collective is capped at hover, so the ship coasts to a stop *on* the goal and is never given more lift than holding station. This is asymmetric on purpose: braking is authoritative, climbing is not.
4. **Smooth collective.** The demand runs through a slew limiter (fast to rise, slow to fall) so the props can no longer jump 0↔15 in a single tick — the lurching is gone.

The velocity PID's I term is a *leaky* integrator, so it cannot wind up during the long cruise and fire on arrival. The climb is bounded by the ceiling probe (physical limit) and a stall failsafe, not by the turn-phase timeout.

### Ceiling discovery (dynamic)

The autopilot does **not** assume a hardcoded ceiling. Instead it:

- Requires at least **y280** (`AP_CEIL_FLOOR`). The ship never cruises below this for a waypoint that has no explicit altitude.
- Climbs past y280 while the lift props are turning **faster than 13** of 15 (`AP_CEIL_LIFT`). It stops the climb when the demand reaches 13.
- The 2 prop units still in hand are the safety margin — no separate margin is subtracted, so the discovered altitude is itself the safe cruise altitude. This means: on a flat world the props are already near 15 at y280 and the ship cruises on the floor; in a world where the air is denser up high (terrain/builds well above sea level) the props may still be at ~5 when reaching y280 and the ship **keeps climbing for thousands of blocks** until they drop to 13.

When a waypoint has no `alt`, the cruise leg targets the discovered ceiling. When a waypoint has an explicit `alt`, that value is honoured as-is (it is not treated as a ceiling request).

The yaw-compensation trim (`limits.yaw_roll_coupling`, `limits.yaw_pitch_coupling`, `AP_YAW_FF_MAX`) is **disabled by default (0)**. It is meant to be calibrated per ship from `stab_log.txt` if your hull yaws with a predictable pitch/roll coupling — leaving it at 0 avoids the turn fight observed with a wrong guess.

### Network keyboard (kbd)

The waypoint prompts are typed on a **plain computer on the same wired network** as the ship (the ship needs a modem too):

1. Copy **`kbd.lua`** from the repo root to the keyboard computer.
2. Run `kbd` (or rename it to `startup` for auto-run).
3. It announces presence every 3 s; the ship **auto-pairs on first contact** (no IDs to configure) and shows the prompt on both screens. The keyboard validates input locally too (numbers, name rules) and shows `Waiting for the ship computer...` between requests.

Traffic **keyboard → ship** runs on a dedicated raw modem channel (39999), not rednet: rednet's receive side dedups by an unseeded `math.random` message id that is identical across computers, so the ship could silently reject the keyboard's packets as duplicates (seen as a permanent one-way link). **Ship → keyboard** stays on rednet (that direction is proven working). Every answer is **confirmed by the ship** (`ack`/`nack`) — the keyboard shows `Confirmed by ship.` in green, or a red `Ship did NOT confirm (3 tries)` / `Ship rejected: <why>` if not. The keyboard's header line shows the live link state: `ship: online` (both directions), `ONE-WAY link: kbd->ship NOT working?` or `ship NOT heard for Ns`. On the ship, `Kbd link: rx rednet=… raw=… modem=… raw_ch=…` in the boot print and `kbd:`/`raw op=` lines on the terminal show exactly which packets arrive.

### Flight laws (drone-style)

- **Altitude**: `thrust = hoverFF(height, climb_rate) + PID`, applied **uniformly** to all four props. `hoverFF = hover_throttle × e^(0.004×(H−63)) / (1 − climb_rate/25)` is a **prop-physics feedforward**: Create Aeronautics air pressure (`DimensionPhysics.java`) is `e^(−0.004(H−63))`, so at y260 the props make only **45% thrust**, and the wiki thrust formula `∝ (1 − velocity/airflow)` means a fast climb eats another chunk — a fixed feedforward (the old `hover_throttle = 6`) can no longer hold its altitude up there (it settles ~18 m low even in simulation, and with a rear-kick tilt on top the entry sank y260→y160 in-game). With the scaled feedforward the PID only trims transients, so the same gains hold at any height (the height ceiling is **not** a constant — see **Ceiling discovery** below). Create Aeronautics gravity is **g = 11 m/s²** (`physics.gravity`); default gains are derived for that plant (ωn≈0.8, ζ≈0.8). The D term uses **climb rate** (no kick on Space/Ctrl steps) and I only integrates near the target (anti-windup). At the target altitude props keep spinning — they do not cut to 0.
- **Pitch / roll**: automatic **stability** via **prop speed reductions only** (never tilt, never accelerating a prop above the altitude-PID base): `corr = clamp((PID(0 − attitude) − 0.25 × rate) × kh/den, ±cap × kh/den)`, with a **stepped cap by attitude error**: **0** below 2° (deadband — larger and the ship leans/strafes off-course, smaller and the wobble loop returns), **2** at 2–6°, **4** at 6–12°, **6** above 12° (high-angle authority raised from the old 4 — "not strong enough at high angles"; rate damp raised 0.15→0.25). **`kh/den` is the authority schedule** (`kh = e^(0.004(H−63))` air pressure, `den = clamp(1 − climb_rate/25, 0.3, 3)` the climb-rate thrust factor): speed *differences* lose thrust with altitude **and while the ship climbs**, while the disturbance (gravity on an off-centre hull) does neither — at y260 the caps delivered only 45% of their sea-level moment, and a fast climb cut the correction again (the hull noses up on the climb and the weak diff never arrives). Multiplying corr+cap by `kh/den` restores ground-equivalent authority at any height **and** climb rate (both factors ≈1 near the ground and in level flight, so takeoff/landing/level behaviour is unchanged; the cruise AP block is scheduled the same way). **Adaptive gain (`stabAdapt`)** then scales that back by the headroom left above hover, so the correction **shrinks the faster the props have to spin** — the reported high-altitude wiggle. `kh` is itself proportional to prop speed (both go as `1/pressure`), so on its own it makes corrections *grow* with altitude; the taper has to be strong enough to turn that over, which is why `AP_STAB_ADAPT_MIN` is 0.2 and not 0.4 (at 0.4 the net scale still rose, 1.15 at y270 vs 1.07 at y80). Measured: the differential at a fixed 4° roll error is **27% smaller at y270 than at y80**, with the floor keeping real authority. The headroom is keyed on the **static** hover (`hover·den`), not the live feedforward — the live value carries the `1/den` climb term, and keying on it tied attitude gain to climb rate and broke climb moment invariance (vertical test caught ratio 0.652). This is a **gain taper with a floor, not the hard lift-budget cap** that was tried and reverted (that pinned mean thrust at 7 against a 13.5 hover demand and collapsed pitch to 23°). Strength is quantized, so **precision comes from time**: in **manual flight** the capped correction fires as **short pulses** on a 0.6 s window with a **duty cycle growing with the error** (0 → 0.5 → 1.0 across the 2–10° band — floor raised from 0.3, the old train was off 70 % of the time at low error), giving small errors brief corrections instead of a continuous hold; **under the autopilot the pulse train is OFF — corrections hold continuously** (duty 0.5–1.0 halved the authority and rang the hull through long climbs; cruise already ran continuous and was called perfect; manual flight keeps the pulse). Only the pair needing less lift slows down; the opposite pair stays at base, so the altitude PID absorbs the small mean-thrust loss. **Stability always wins under the autopilot** (AP-driven forward tilt does *not* fade it); only a **manual W/S stick** fades the pitch duty to zero — the pilot's angle-maneuver override. **During auto-landing the roll stabiliser is deliberately strengthened** (deadband 2°→1°, max cap 4→5, duty starts at 0.6; above 12° both axes get +2 units) so touchdown happens on a levelled hull — this is speed-diff only, because "A/D roll" here is really tilt (pitch/yaw), never a true roll. Gains come from `config.pid` (`pitch`, `roll`), overridable per ship in `config/pid_<slot>.lua`.
- **Auto-unflip**: if pitch **or** roll stays within 15° of 180° (**≥165°**) for **5 s** (airborne, not e-stopped), a recovery sequence runs: a black-on-red **AUTOMATIC UNFLIP SEQUENCE** banner (header content area + alarms row), the **left-of-computer redstone link** reverses all lift propellers, thrust goes **full**, and the pair on the **opposite side of the flip** is **cut** for a 1.5 s asymmetric kick; then **4 s of pure ascent** (uniform full reversed thrust, no cuts) to gain altitude while inverted; then a **violent righting drive** (P=6, D=1.5, no deadband, reduce-only from full speed, polarity inverted while reversed) runs until attitude ≤ 10°. The reverse link drops below 90° so reversed thrust can't press a levelled ship down; ≤ 10° ends the sequence (reverse off, PIDs reset, 5 s cooldown), and a **20 s hard timeout** aborts it (reverse off, normal law resumes). E-stop / landing / safety cut all kill the reverse link. Sign knobs at the top of `lib/flight.lua` (`UNFLIP_ROLL_CUT`, `UNFLIP_PITCH_CUT`, `UNFLIP_DRIVE_POL`) if a phase kicks the wrong way in-game.
- **Tilt** is **direct piloting only** (W/S collective, Q/E yaw stick). There is currently **no hands-off heading actuation** (the cruise rear differential / heading-hold drive was removed); the autopilot's aim/align steer through the **yaw-stick path** with a PD on heading error + turn rate. The ship **cannot strafe** (props don't tilt left/right) — A/D controls are removed.
- **Rear thrusters**: **off in hover** (signal 15 = stopped); entering **cruise** puts them at **speed level 1** (signal 14) automatically (autopilot entries then **ramp up at `cruise_ramp`** instead of jumping to full — an instant 0→15 kick pitches the ship over before the pitch stab can answer). They respond **only** to the W/S goal bar — no yaw differential, no other controls. Both relay faces receive the same level.
- **Cruise speed**: a **15-segment goal bar** (levels 1–15) — each W press steps **+1**, holding repeats **every 0.2 s** (S = −1, floor **level 1**). Signal = **15 − level**: level 1 → 14 … level 15 → **0 (no redstone = reduction off)**; level 0 (hover/e-stop) → signal 15 = stopped. Wiring is **inverted slow-down** (same as the main props' speed face). Reverse = the REAR relay's **top** face (`output_map.REAR.rev`, `features.rear_reverse`).
- **Auto-landing** (L / ACTIONS): gear down → ARMED (sensor settle) → DESCEND: the altitude target walks down at `limits.land_descent_rate` (**12.0 m/s** default), freezing once the sensor reaches `landed_threshold` so the debounced ground-contact latch (4 ticks) can finish. **Runaway-goal safety**: if the goal ends up **more than 20 m below the ship while it isn't falling** (ground latch never fired, goal still walking), the goal freezes and the OS **shuts down** — clutch decoupled (props free of the engines) and the monitor back to the splash screen (climb-rate guard keeps a fast mid-air catch-up from tripping it). The heading **recorded the moment auto-land fires** is held for the whole sequence (pilot Q/E ignored; if the ship rotates, the yaw hold drives it back to the recorded heading). During ARMED/DESCEND the ship **holds fore/aft position with the rear thrusters** (gentle pulsed P-damp on longitudinal velocity — nose-axis projection from the orientation quaternion, gain **2**, 0.3 m/s deadband; corrections fire as **short bursts on a 0.6 s window** with duty growing with the excess speed but capped at **50%**, so the rear only nudges instead of shoving; drifting forward = **reverse link ON + normal thrust** pushes backward, backward drift = thrust alone — set `features.rear_reverse = false` if the reverse face isn't wired, then only backward drift is countered). Flip `LAND_FA_SIGN` in `lib/flight.lua` if the rear push amplifies drift.
- **Landed idle**: OS on + grounded → uniform prop speed **1** (slow-down wire **14**, blades creep, no lift). Full stop on shutdown / e-stop.
- **Coordinates**: the ship's world position (logical pose) is sampled **every control tick** into `state.position` and exposed via `getStatus().position` — the **NAV tab** shows live **X / Y / Z** (was `N/A`). Touchdown records `getStatus().land_position` (world coords at landing) as the first reference point for the upcoming autopilot work.
- **Control loop**: everything above runs on a fixed **20 Hz** tick (`os.startTimer(0.05)` — CC:T rounds timers up to world ticks, so 50 ms is the hard ceiling; timers fire late, never early). The tick order is **state → autopilot (position check, targets, phase) → mode law (apply the correction) → auto-land → rear brake → outputs**, so the waypoint autopilot **checks the position and applies the correction in the same tick** (the old AP-last order deferred every correction by one tick). `dt` is the fixed 50 ms, not a measured delta: P/D terms are memoryless and timers only fire late, so a slow tick detunes the controller but can never destabilise it. Each tick's real period and CPU work time are measured live: the **SYSTEMS tab `LOOP` row** shows the average period (green ≈50 ms = on the 20 Hz timer, red = starved), the ALARMS tab raises **`CONTROL LOOP SLOW`** when it stays late, and the terminal prints a `[LOOP]` warning. Redstone writes to the relays are **skipped when the pin value is unchanged** (per-pin cache, invalidated whenever peripherals re-wrap), keeping the per-tick main-thread peripheral task count well inside CC:T's 5 ms/computer budget.

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
- `config/pid_<slot>.lua` — optional manual gain override (altitude/pitch/roll/yaw); when absent the `pid` values in the ship config apply

## License

MIT
