# ArtCorpOS

A ComputerCraft flight stabilization and control OS for my Create:Aeronautics ships.

## Minecraft Requirements

- Create:Aeronautics
- CC:Tweaked
- CC:Sable
- CC:Graphics

## Quick Install

On the main computer located inside the ship's brain:

```
wget run https://raw.githubusercontent.com/Artmoby7674/aeronautics_artcorp_os/master/install.lua
reboot
```

The ship will then boot straight into the flight OS: the cockpit monitor shows the
**START ENGINES** button. Everything after that is done from the touchscreen,
the typewriter, and the basic computer that serves as a text input. The
ship computer itself is never needed in flight: if the OS ever stops on an
error it shows the error on the monitor and restarts on its own, and an
airborne restart takes control immediately.

On the **keyboard computer** (the small one on top of the cockpit screen):

```
wget run https://raw.githubusercontent.com/Artmoby7674/aeronautics_artcorp_os/master/install.lua kbd
```

The installer stages every file before swapping it in (a failed download or
a full disk leaves the existing install untouched), removes program files
left by earlier releases, and never touches `config/` (ship wiring, saves)
or `v2/data/` (what the ship has learned, waypoints, logs).

## First Launch

A computer with no ship set up starts on a **WELCOME ABOARD** screen instead
of the cockpit. Two ways in:

- **IMPORT FROM DISK**: put a floppy with a saved ship in any disk drive on
  the network. The ship loads and the OS restarts on it. Nothing else to do.
- **SET UP THIS SHIP**: the OS walks through the wiring one part at a time
  (the four props, the rear thruster, the engine, the gear and ground sensor,
  the two keyboard relays and the monitor). Each step says what that part
  does and lists the relays it found on the network; tap the right one.
  **TEST** flips a face for 2 seconds so you can see which relay it is,
  **DETECT** finds a keyboard relay when you press one of its keys. Nothing
  is saved until **FINISH**.

Then a short first-flight guide, and a tour of the screens: the rest of the
screen dims, one thing is highlighted, and a popup explains it (**NEXT** /
**SKIP**). The **?** at the top right replays the tour any time on the ground.

Before the first start: **open the steam engine's water input valve**. The OS
can't do that one for you.

## What It Does

- **Stays level on its own.** Hands off, the ship holds its altitude, keeps
  level and cancels fore/aft drift with the rear thrusters. It never tries to
  hold a position or a heading (it has no sideways thrust to do that with).
- **Calibrates itself.** After a reset, hover hands-off for a bit: the trims
  settle, then freeze. SHIP > CALIBRATION says **DONE (FROZEN)** when it's done.
- **Learns the air.** Every world is different, so the ship measures how much
  thrust it needs at each height while it flies, and works out its own ceiling.
  It cruises at Y270 by default, or lower if the air runs out first.
- **Flies itself to a waypoint.** Pick one on the NAV tab and press FLY: it
  climbs straight up, turns to face it, cruises in a straight line (steering by
  banking, like a plane), slows down for the approach, turns to the saved
  heading and lands. The landing gear goes up once it's clear of the ground.
- **Saves and swaps ships.** SAVE DISK / LOAD DISK copy the whole ship to a
  floppy; SHIP > SLOTS keeps several ship configs on one computer.
- **Keeps a black box.** Every control tick is logged to `v2/data/bb.txt`, and
  events to `v2/data/log.txt`, so any weird flight can be looked at later.

## The Screen

| Tab | What's on it |
|-----|--------------|
| FLY | Altitude, climb, speed, heading, target altitude, and what every prop is doing |
| NAV | Map and waypoints: save the current spot, add one, FLY to one |
| AUTO | The autopilot's progress on its current trip |
| SHIP | Hardware status, what it learned in flight, disk and slots |
| ALERT | Anything that needs attention |
| CTRL | Take off / land, gear, hover/cruise, E-STOP, recorder, power |

The full controls (keys, hover vs cruise, every tab) are in `v2/README.md`.

## Physical Setup

### Peripherals

| Device | Count | Purpose |
|--------|-------|---------|
| Computer | 1 | Runs the OS |
| Wired Modem | 10+ | One on the computer, one per relay and monitor |
| Networking Cable | - | Connects all the modems |
| Redstone Relay | 9 | Bridges the computer to the ship's redstone links |
| Monitor (advanced) | 1 | The cockpit touchscreen |
| Disk Drive (optional) | 1 | SAVE DISK / LOAD DISK |
| Computer (optional) | 1 | Keyboard computer for typing names and coordinates |

### Relay Placement (Atlas)

This is how my Atlas is wired. The setup screen asks which relay is which, so
yours can be placed differently as long as the faces match.

- **Input relay 1** (W A S D): front = W, back = S, left = A, right = D
- **Input relay 2**: left = Q, right = E, front = Space, back = Ctrl
- **Aux relay**: left = Shift, front = landing gear, right = ground sensor
- **Engine relay**: left = engine starter (and the OFF button input), right =
  clutch, front / back = the UP / DOWN tab keys
- **Prop relays** (one per prop): front = tilt forward, back = tilt back,
  left (FL, RL) or right (FR, RR) = speed
- **Rear thruster relay**: front = forward, back = backward, top = reverse

Prop and rear speeds are slow-down links: **15 = stopped, 0 = full thrust**.
The ground sensor sits under the landing gear and gives an analog signal
(15 = touching the ground, 1 = 14 blocks below).

## Updating

Run the same install command again. It pulls the latest release and keeps the
ship's wiring, waypoints and everything it has learned.

## More Detail

`v2/README.md` covers the controls, how the flight laws work, the tuning
knobs in `v2/tune.lua`, and the data files.

## License

MIT
