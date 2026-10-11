# Level design reference: what the game can do

A designer's view of the game as it stands: every verb, surface, object and interaction, with the numbers and gotchas that matter when laying out a level. It is a summary: the topic files hold the detail and the reasoning, and where this file and the code disagree, the code wins. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first. The puzzle patterns built from these pieces are in a separate file.

Covers: Player verbs; Terrain and surfaces; Object catalogue (Movers: platforms, belts, pads, rails, barriers; Rotating bodies: see-saw and swing; Blocks: ice and metal; Liquids: water, slag, steam; Beams and projectiles: laser, arc, cannon, mirror; Hazards; Enemies; Power: sources, wiring, devices; Collectibles, checkpoints, finish); Interaction matrix; Gaps, limits and gotchas

**Units.** 1 tile = 16 px. The camera shows 512×288 px, which is **32×18 tiles**. Speeds are px/s; a walk is 150 px/s (about 9.4 tiles/s). Numbers are the documented defaults and may have been retuned.

## Player verbs

| Verb | How | Notes for design |
|---|---|---|
| Walk / jump | left/right, jump | Coyote time and jump buffering. Small step-downs are walked down, not fallen off. |
| Crouch / sneak | down; down + left/right | Crouch collider is shorter (fits low gaps). **Sneak** creeps at 50 px/s. Crouching on a button presses/cycles it. |
| Kick | kick | Hits enemies (`take_damage`), turns mirrors, shoves ice/metal blocks, boots mines. Ground kick roots you; **air kick** doesn't, and cancels upward speed (never slows a fall). No dash, no dodge. |
| Ladder | up/down at a ladder tile | Ladders are their own tile layer, sharing a cell with the catwalk they pass through. |
| Ledge hang + mantle | airborne beside a ledge | Works on ground, glass, catwalk tiles and on bodies in group `ground` (doors, blocks, see-saw ends, moving/drop platforms). **Not** on conveyors, button pedestals, receivers, barriers. |
| Catwalk underside hang | jump up into a catwalk, or crouch + jump while standing on one | Left/right **brachiates** hand-over-hand. Jump goes up through the catwalk. Blocked by terrain. Hands off onto a ladder with up/down. |
| Crust underside hang | same as catwalk, under a basin's crust | Only where a **drain has left a void** under the crust. Refused while liquid fills the space. |
| Swing hang | airborne near a swing bar | Left/right pumps; jump releases with the bar's velocity; crouch drops. |
| Rail hang | airborne near a grabbable rail | Flat rail: brachiate. Steep rail (>10°): slide. Jump or crouch to leave. |
| Swim | in water or slag | Slag is buoyant and hurts every frame. Electrified water hurts. Kick/crouch/grabs are disabled while swimming. |
| **Surf** | crouch + kick on the floor | The big one. See below. Kick again to dismount. |
| Jump pads | touch | Launch you (the surf survives a pad). |

**Surf in numbers.**

| Quantity | Value |
|---|---|
| Start speed | 240 |
| Top speed | 600 dry, 800 on wet floor |
| Ends below | 40 (or a wall) |
| Dry coasting on flat from start | about 5 tiles |
| Bowling (knocking enemies/barriers over) from | 300 |
| Skimming a still pool from | 180 |
| Default breakable-barrier speed | 450 |
| Default speed-trap threshold | 450 |

- **Tilt** (left/right relative to travel): match the slope (nose down downhill, nose up uphill, level on the flat) for free. Mismatches add drag; nose-up on the flat is a hard brake.
- **Launch/landing**: nose-up pops higher and shorter, nose-down flatter. A *clean landing after at least 0.6 s of air* is "earned": speed bonus on slopes, points (5/10/20 by air time), and downhill landings convert fall speed to forward speed.
- **Speed sources**: downhill slopes, wet floor (higher cap, less friction), a pad launch.
- **Speed sinks**: uphill (about 1,100 px/s² on a 1:1), friction, tilt mismatch, shoving blocks, landing sloppy.
- **A 1:1 ramp** needs about 320 px/s to launch over 1 tile and about 500 px/s over 2.5 tiles.
- **Surf ends on**: a hit, a wall, entering water too slowly, slag, a belt stall, or dismounting. A swing grab and a pad launch do *not* end it.

**Health and consequences.** 4 hit points, i-frames after a hit, no kill plane (only `take_hit` kills). Death respawns at the last checkpoint after about 3 s.


## Terrain and surfaces

| Surface | Solid | Hangable (ledge) | Laser | Water | Notes |
|---|---|---|---|---|---|
| **Ground** tile | yes | yes | blocks | blocks | The normal wall/floor. |
| **Glass** tile | yes | yes | **passes** | blocks | See through a wall of lasers. |
| **Catwalk** tile (or body in group `catwalk`) | one-way (jump up through, stand on top) | yes (side + underside) | **passes** | **passes** (falls through) | Keep on its own tile layer in group `catwalk`. |
| **Ladder** tile | none | n/a | passes | passes | Own tilemap layer. |
| **Spike** tile | none (hurts) | no | passes | passes | Four orientations. Damage polled every frame. A tile can't be powered: paint it on a **powered spike layer** to switch it. |
| **Crust** (basin) | yes, walkable | underside only (over a void) | blocks | blocks | Forms when water meets slag. |
| **High-friction / ice tile** (`surf_friction`) | yes | yes | blocks | blocks | Per-tile surf friction multiplier. A tile value above 1 is mud, below 1 is slick. |

**Tile-level tools to remember**
- Slopes and half tiles work (sloped floors give ramps, half-pipes, ledges).
- Basin sampling reads the actual tile collision, so shaped basins are possible.
- A ladder top flush with a floor lets you walk on and off cleanly.


## Object catalogue

Format: **what it is** → key knobs → reacts to / affects → design notes.

### Movers: platforms, belts, pads, rails, barriers

**Moving platform.** Looping tween, powered = running (unpowered pauses mid-path). Carries riders for free, and is hangable. Can carry a **mirror** (the beam sweeps with it). One-way platforms need thin end caps if they should be ledge-grabbable.

**Drop platform.** Drops 1 s (`hold_time`) after you stand on or hang from it, committed (leaving doesn't cancel). Reappears. A fast surf beats it.

**Conveyor belt.** `segments` (signed, total tile width; sign picks which side of the origin), `belt_speed`. Powered = running. Carries the player, blocks and sparks. **Not** hangable. A belt against a surfer can stall the surf (the surf ends if ground speed falls below 40). A belt launches the surf off its end with a small net boost.

**Jump pad.** `launch_speed` 500, aimed by the instance's rotation. Powered = live (unpowered is inert and dimmed). Launches the player (surf-safe) and blocks. **Heavier blocks fly less**: metal 1×1 gets about a quarter of the speed. Vertical speed on blocks is capped at 400. Enemies ignore it.

**Breakable barrier.** `size_tiles` (default 1×3), `break_speed` (default 450; behaves as 300 minimum and 800 maximum), `break_from` (either/left/right). A fast surf smashes it and keeps going; anything slower hits a wall. Blocks lasers and drillbots like a wall. Bullets pass through it. Stays broken after a checkpoint restore. Never ledge-grabbable.

**Rail.** A Path2D built from draggable `Marker2D`s. Grabbable by the player. A `RailBot` can ride it (see enemies). Steep rails are slides: gravity speeds you up, and you coast off the end with the slide's velocity.

**Door.** Powered = open. Recedes into the floor (open = a harmless 2 px foot). **Closing never crushes**: it waits while a player, enemy or block is in the way. Rotates in 90° steps. Hangable. Blocks lasers, arcs and water. `invert` makes it start open.

### Rotating bodies: see-saw and swing

**See-saw.** Torque from loads: player weight 2, ice 1 per tile, metal 4 per tile, water 1 per tile of volume, slag 3. Spring back to level; limit ±25°. Per-instance `length_tiles`.
- Powered = **motorized**: it oscillates between limits, and the motor must beat opposing loads. Unwired it's free.
- `mirror_surface` makes the whole top face reflect lasers, so tilting it aims the beam.
- Ends are ledge-hangable while tilted less than 15° and moving slowly. The underside is not.
- Read by the **angle sensor** (a power source).
- Raised end is a lip (see surf notes). Idle riders are gripped, so they don't slide off.
- A block or player on the plank shields the face from above, and a lit block melts onto it.

**Swing.** A rigid-rod pendulum, `length_tiles` (default 4), default ±80° limits. `free_rotation` allows full circles. The player pumps with left/right. Catching it transfers your momentum (`ω = r × v / |r|²`). Releasing hands the bar's tangential velocity to the player (jump adds jump speed). The bar is **not solid**. The arc must be clear of solid tiles (hanging bodies aren't physics-resolved). Powered = motor.

### Blocks: ice and metal

Both are rigid bodies, sized in tiles, with free rotation by default. They **topple off ledges, can be kicked, and can't be pushed by walking** (the shove guard discards actor pushes). They press buttons and weight plates, ride belts, get launched by pads, and are opaque to lasers.

| | Ice | Metal |
|---|---|---|
| Weight per tile | 1 | 4 |
| Melts to | water (2 s lit) | slag (3 s lit) |
| Cools/refreezes | yes (0.5/s) | yes (0.4/s) |
| In slag | melts fast, bursting water onto the slag (→ **crust**) | floats (60% submerged) but melts in about 8 s |
| In water | floats (about 80% submerged), small bob | **sinks** to the seabed |
| Slippery to stand on | **yes** (ice-rink acceleration) | no |
| Surf friction on top | 0.25× (about 4× the coast) | normal |
| Kick | shunts at 100 px/s, slides about 4 tiles; can slide off ledges | shunts at 50 px/s, about 1 tile |
| Crusher | **shatters** (melts to water on the spot) | **jams** the crusher |
| Surf shove | transfers speed; slides up to 18 tiles on ice | moves less (heavy), but still costs the surfer speed |

- **Melt progress is reversible**: a block lit then shaded refreezes or cools along its animation.
- Floating blocks ride a rising/draining surface. A rider can't hold them down; carrying capacity is `rest_fraction`. Level lever: past 1.0 the block can't carry the load and sinks.
- Swimmers underneath nudge floating blocks sideways slowly.
- Hanging from a block works while it is flat and still enough (≤10°, ≤90 px/s).
- A melting block spawns liquid per tile **at the block's position**, which then falls and can land on you, on a see-saw, or into a basin.

### Liquids: water, slag, steam

- **Water particles** flow, creep, and fall through catwalks. Moving particles shove the player a bit and are carried by moving solids. Water on a see-saw adds load.
- **Slag particles/pools** burn the player on contact (each frame of submersion or touch). Buoyant to swim in.
- **Basin** (`WaterBasin`): a hand-sized container sampled from the tiles under it. Authored: `liquid_type`, `initial_fill_depth_below_surface`, `boilable`, `conducts_sparks`, `electrified_time`. Fills from particles and **spills over its shorter wall into the next basin** (basins chain without adjacency data).
- **Faucet**: `flow_rate`, `liquid_type`, powered = open. Placed on a basin's interior floor tile, it's a **drain** (removes liquid, leaves any crust hanging over the void). Elsewhere it's a **source**.
- **Crust**: opposite liquids meeting in a basin solidify a 0.75-tile slab across the wet columns and emit **steam**. It never grows or thins. Walkable, laser-opaque, hangable from beneath where a drain has left a void. Same-liquid arriving on top just rests on it. Opposite liquid arriving on it evaporates into steam.
- **Steam**: rises 80 px/s in a narrow cone, about 8 tiles tall, stops at ceilings. **Only the surfing player feels it** (up to 1,500 px/s² of lift). It lifts the board off the floor once it exceeds gravity.
- **Skim**: a surfer at 180+ px/s on a still, non-hazardous, crust-free basin rides the surface on a temporary floor. Slower, slag, or electrified water: swim or sink instead.
- **Laser boiling**: `boils_water` on the turret *and* `boilable` on the basin. Drains it and makes steam. Slag is never boiled.
- **Electrified water**: a spark (rail bot) or arc touching a crust-free water basin electrifies the whole pool for `electrified_time`. Hurts a submerged player and kills skimming. Nothing else reads it.
- **Basin sensor**: a power source reading fill fraction, crust, or one column's depth, optionally filtered to water/slag.
- **Wet floor**: flowing water over the floor raises surf top speed to 800 and cuts friction. It decays 0.4 s after leaving the water.

### Beams and projectiles: laser, arc, cannon, mirror

| | Laser | Arc | Cannon bullet |
|---|---|---|---|
| Shape | continuous beam | slow projectile (220 px/s, range 480) | fast projectile |
| Reflects off mirrors | **yes** | **yes** | no (a bullet *hits* a mirror only if `bullet_rotates`) |
| Stopped by | solids, doors, blocks, enemies, mirror backs | tiles, doors, blocks, mirror backs | the player and world tiles |
| Passes through | catwalks, glass | catwalks, glass, **enemies, player layer** | other traps/enemies |
| Hurts | the player (per frame, polled), enemies (1 per 0.5 s) | the player only | the player |
| Melts | ice/metal blocks | no | no |
| Lights/triggers | **laser receiver** | **arc receiver**, electrifies water | **bullet target** |
| Boils water | optional | no | no |

- **Laser turret**: aim = instance rotation. Powered = beam on. `damage`, `boils_water`.
- **Arc turret**: `fire_interval` 2 s, `phase_offset`, `arc_speed`, `arc_range`. Powered = firing (a rising edge fires one at once). The telegraph is a growing glow in the last 0.45 s.
- **Cannon**: `fire_rate`. Powered = firing (rising edge fires one at once). Aim = rotation. The housing is a standable solid.
- **Mirror**: 45° step per kick (`rotation_step_degrees`), `rotate_direction`, `rotate_time`. Also turns on each **rising edge** of power (falling edges do nothing). `bullet_rotates` (off by default) lets a bullet turn it one step. Solid to the player. A mirror's back and edge block beams. Can ride a moving platform.

### Hazards

| Hazard | Behaviour | Controlled by power? |
|---|---|---|
| **Sawwheel** | Contact damage while spinning | yes (off = paused and safe) |
| **Crusher** | Spike down, solid arm up; cycle phases authored; shatters ice from above; jams on metal | yes (off parks it retracted; an off→on cycle clears a jam) |
| **Cannon** | See Beams and projectiles | yes |
| **Laser/arc turret** | See Beams and projectiles | yes |
| **Spike tiles** | Hurt from any side; polled, so you're re-hit after i-frames | **no** (tile) |
| **Powered spike layer** | The same spikes on a layer that is out or hidden as a whole | yes (powered = out, unpowered = hidden and harmless) |
| **Slag** (pool/particles) | Hurts on contact | no (but can be drained/crusted/boiled-not) |
| **Electrified water** | Hurts if submerged | no (triggered by sparks/arcs) |
| **Grunt hammer / drill / stingers / mine blast / rail bot** | See enemies | rail bot yes |

**Powered spike layer.** A `TileMapLayer` of spike tiles (paint them exactly as on the `Ground` layer) that is out or retracted as a whole. **Powered = out** (drawn and dangerous); **unpowered = hidden** and harmless. Wire it like any device: `sources` and `invert` on the root, or end a conductor at its `PowerTarget` child.
- **Knobs**: `sources`, `invert` (spikes out while the source is off, which is what "a button retracts them" needs). No timing exports: the transition is instant.
- **Reacts to**: the level of the power state, both edges. Unwired it stays out, so it behaves like spikes on the ground; the startup state snaps with no sound and a restore follows the sources.
- **Affects**: only the player, through the same hit as any spike (1 damage, knockback away from the tile, i-frames, a surf ends). It has no collision and no `surface_type`, so it blocks nothing and is never ground-like. Enemies and blocks ignore it, as with spike tiles.
- **Gotchas**: **no warning phase**, so spikes that extend under a player standing in them hurt on that frame, and spikes that retract spare the player the same frame. Show the player what is about to extend (layout, a camera cue on the same source) rather than relying on a telegraph. Power switches the whole layer, so independent groups of spikes are separate layers. **Move the `PowerTarget` child to the tile a conductor wire should end at** (it starts at the layer origin). A retracted layer is invisible, so it hides the route it guards until it is powered; pair it with a hint if the player has to find it.

**Crusher jam rules.** Metal under the extending spike latches the jam: the arm retreats and parks, the spike is harmless, and the jam stays even if the metal later melts or leaves. A wired crusher is reset by cycling its power; an unwired one stays jammed until reload or checkpoint restore. A block pressed against the arm's *side* doesn't jam it.

### Enemies

| Enemy | Threat | How to beat it | Surf | Notes |
|---|---|---|---|---|
| **Drillbot** | Drill at its **front** only; body is harmless | Kick (3 hits), laser | Bowled only if you come from behind; from the drill side you get hurt | Patrols to a set distance, or free-patrols to walls/ledges when `patrol_distance` is 0. |
| **Stingbot** | Flying; lunges and recoils; stingers are Area2Ds | Kick (3 hits), laser | n/a (flies) | Cycle: airborne (6 s) → lands → recharges (2 s) → relaunches. No obstacle avoidance, so it can stick on walls. |
| **Grunt** | Hammer with a clear telegraph (windup → swing → recover). Chases when you enter aggro range, stops at ledges. | 2 kicks, laser (1 dmg per 0.5 s), mine blast | **Always bowled** (even mid-windup) | Never hurt while in windup/recover if you're not in range. |
| **Tread crawler** | Sides hurt; top is a **stomp zone** | Stomp (flips it, you bounce) or kick; then kick it again to kill | Always bowled | A flipped crawler (4 s) is a **safe, standable stepping stone**, and **you standing on it pins it**. |
| **Proximity mine** | Arms within 32 px (h) / 28 px (v) of the player; blast radius 40, fuse 0.8 s, can't disarm | Kick it away (slides at 160 px/s); a kick or laser **arms** it | **Not** bowlable; the surfer stops and it arms | Blast hurts player and enemies (2 dmg: kills grunts, flips crawlers) and chains to other mines. No line-of-sight check, so it blasts through thin walls. |
| **Rail bot** | Hangs under a rail; contact hurts (and knocks a rail-hanger off); drips **sparks** every 1.6 s (telegraphed) | Laser or mine blast (it's overhead) | n/a | Powered = running. Sparks roll down slopes, ride belts, and electrify water. |

### Power: sources, wiring, devices

**Every powered device** carries a `PowerTarget`. With nothing wired it behaves as authored. A target has `sources` (any number), `all_required` (AND vs the default OR), and `invert` (also exportable on the device root). `debug_toggle_key` flips any device from the keyboard while testing.

**Sources**

| Source | Powers when | Knobs |
|---|---|---|
| **Button** | pressed by player or any block (not enemies/liquid) | `latch_mode` MOMENTARY / TOGGLE / TIMED (`duration`); colour is art-only |
| **Speed trap** | a *surfer* crosses its line at ≥ `threshold_speed` (450) | `hold_time` (5 s, 0 = latched), `require_surfing` |
| **Laser receiver** | lit by a beam; stays on `hold_time` (0.3 s) after | the flicker bridge |
| **Arc receiver** | hit by an arc | `latch_mode`; MOMENTARY pulse 2.5 s, TIMED 5 s, TOGGLE |
| **Bullet target** | hit by a cannon bullet | `latch_mode`; MOMENTARY pulse 0.3 s, TIMED 5 s, TOGGLE |
| **Weight plate** | summed weight ≥ `threshold` (2) | `hold_time` 0.15 s; counts stacked blocks and riders up to 3 deep |
| **Angle sensor** | a `RotatingBody` tilts past `threshold_degrees` (15) toward `side` | `hysteresis_degrees` 3 |
| **Basin sensor** | FILL ≥ 50%, CRUST present, or COLUMN depth ≥ 0.25 tile | `liquid_filter`, hysteresis, `hold_time` |
| **Conductor circuit** | any attached source is on | wired by painted tiles |

**Button specifics worth remembering**
- **Momentary**: the player *starting a crouch* while standing on it **cycles** it (falling then rising edge in one frame), which advances a mirror and replays the animation.
- **Toggle**: flips on step-on and on crouch.
- **Timed**: pressing again restarts the countdown (no new edge).
- A block melting on a button can't leave it stuck.

**Wiring.** Two ways: pick sources per device in the inspector, or paint **conductor** tiles (Red/Yellow/Green/Blue layers, colour is art only). Pieces: straights, corners, Ts, four-way junctions; same-layer crossings are junctions, different-colour layers cross freely. A wire's open end that doesn't meet a matching edge is a **terminal**: the device in the cell beyond it attaches. Lit/dim art tells you the state. Built once at load (painted tiles don't rewire at runtime).

**Camera cue.** A `Node2D` placed at the point to look at (no collision, no art at run time). A rising edge pans the camera there, holds, and eases back, so a trigger that works off-screen (a button, a receiver behind a wall) shows its effect. Wire it like any device: `sources` and `invert` on the root, or end a conductor at its `PowerTarget` child.
- **Knobs**: `pan_time` 0.6 s, `hold_time` 1.5 s, `return_time` 0.6 s, `delay` (seconds from the edge to the start of the pan; use it to line a door's opening up with the camera arriving), `once`, `cooldown`, `ease_curve` (LINEAR / SINE / CUBIC), `show_view_rect` (editor overlay of the 32×18-tile view centred on the cue). `play()` is callable from a script.
- **Reacts to**: rising edges only. A falling edge does nothing, and the startup state and a checkpoint restore never cue. An edge during a pending `delay` is ignored; an edge during a cue restarts it, and cues never queue (a second cue replaces the first).
- **Affects**: only the camera. The cue's position is read every frame, so one parented to a moving platform is tracked. The world keeps running.
- **Gotchas**: **input is not locked**, so the player can move, surf and be hit while the camera is elsewhere; a damaging hit or the win dance cuts the cue short, and a jump pad launch or stomp bounce does not. Keep holds short and trigger cues from calm moments (a button press, not a speed trap). `once` is saved, so a restore after the cue does not replay it. Nothing plays while the player is dead or dancing.

**Powered devices**

| Device | Powered means | Quirk |
|---|---|---|
| Door | open | invert = starts open |
| Laser turret | beam on | |
| Arc turret / Cannon | firing | rising edge fires immediately |
| Conveyor | running | |
| Faucet | open | drain or source by placement |
| Moving platform | running | pauses where it is |
| Crusher | cycling | parks retracted when off; clears jam on re-power |
| Sawwheel | spinning/dangerous | |
| Jump pad | live | |
| **Mirror** | **rising edge = turn one step** | startup is not an edge |
| See-saw / Swing | motor on | |
| Rail bot | running | stops dripping when off, still hurts |
| Powered gem | present and collectible | unpowered = hidden |
| **Camera cue** | **rising edge = pan the camera to it**, hold, return | startup is not an edge; no input lock |
| **Powered spike layer** | spikes out | unwired stays out; `invert` retracts on power; instant, no warning |
| Finish | optional lock input (see Collectibles, checkpoints, finish) | |

### Collectibles, checkpoints, finish

- **Gem**: counted in the level total. **Bonus gem**: 50 points, **not** counted toward unlock %; can be **powered** (trail appears/disappears). Placing gems along a launch arc doubles as a guide to the line (it's a level design trick, not code).
- **Medkit**: heals 2, gives 10 points even at full health.
- **Points**: popups exist for 5, 10, 20, 50.
- **Checkpoint**: `order` auto-numbered, a higher order overrides a lower one, and it snapshots everything saveable. Respawn re-applies it.
- **Finish**: unlocks at `required_gem_percent` (default 100) of the level's gems, optionally AND/OR a wired button (`require_all`). Plays the exit dance and the level-complete overlay. `next_level` overrides the next row in the catalog.

**What a restore keeps and drops** (it matters for puzzles):
- Kept: button/receiver state, door frame, blocks (position, melt progress), enemies, mirrors, see-saw angle, platform phase, basin fill and crust, crusher state and jam.
- Dropped: liquid particles in flight, bullets, arcs, sparks, steam, drop-platform state, electrification. A basin mid-overflow comes back settled; a dangerous state restores harmless.

## Interaction matrix

Row = thing acting; columns = what it does to each target. Read this to find combos.

| Actor ↓ | Ice block | Metal block | Water pool | Slag pool | Player | Enemies | Mirror | Door/solid |
|---|---|---|---|---|---|---|---|---|
| **Laser** | melts → water | melts → slag | optional boil (needs flags) | not boiled | damage/frame | 1 dmg/0.5 s | reflects | stopped |
| **Arc** | – | – | electrifies | – | damage | – (passes) | reflects | stopped |
| **Bullet** | – | – | – | – | damage | – | turns it (opt-in) | stopped |
| **Spark** | – | – | electrifies | – | damage | – | – | – |
| **Kick** | slides it | slides it (short) | – | – | – | damage / flips crawler / arms mine | turns 45° | – |
| **Surf** | shoves (long) | shoves (short) | skims if ≥180 | burns/ends surf | – | bowls | – | breaks barrier |
| **Crusher** | **shatters** | **jams crusher** | – | – | damage | – | – | – |
| **Slag touch** | melts fast, → crust | floats, slow melt | **crusts** it | rejoins | hurts | – | – | – |
| **Water touch** | floats | sinks | joins | **crusts** it | – | – | – | – |
| **Jump pad** | launches (weight-scaled) | launches (less) | – | – | launches | – | – | – |
| **Mine blast** | – | – | – | – | damage | 2 dmg | – | – |

**What presses what**
- Button: player + blocks. Weight plate: player (standing) + blocks (+ stacked riders). See-saw load: player + blocks + liquid. Speed trap: only a surfer.
- Receivers are lit by beam/arc/bullet *specifically*. A laser does nothing to an arc receiver and vice versa.

## Gaps, limits and gotchas

**Things you can't do (yet)**
- **Spikes switch per layer, not per tile**: a tile can't carry a `PowerTarget`, so independent groups of spikes are separate layers, and a spike with its own timing (a warning, a stroke) must be a node (e.g. a crusher or sawwheel).
- **The player can't push anything by walking**; only kick, surf-shove or (in water) underside push move blocks. Design block puzzles around kicks and slopes.
- **No catapult or launch from a see-saw**; no lever object; no keys or carryable items; no pickup that persists to other levels.
- **No ranged attack for the player** and **no dodge**; every enemy interaction is a kick, a stomp, a surf, or an environmental trick.
- **Doors can't be opened by enemies or liquid**; enemies weigh nothing and don't press plates or buttons.
- **Steam is a surf-only mechanic**; walking players and swimmers don't feel it.
- **Wire layout is fixed at load**; painted conductors don't rewire at runtime.
- **A level editor is a stretch goal**, and not built.

**Things that are traps for the designer**
- **Catwalk layers**: keep catwalks on their own layer in group `catwalk` (a mixed layer breaks brachiating and the surface checks).
- **Beams are polled by the turret**, so receiver `hold_time` matters; moving or rotating beams need ≥ 0.1 to 0.3 s.
- **Mirrors rotate on rising edges only**: an inverted or momentary source may give you edges you didn't expect on load (startup is not an edge).
- **Arcs aren't saved**: a restore never leaves an arc mid-flight. Don't depend on one.
- **AND of arcs/bullets** needs TIMED latches, since they rarely arrive together.
- **`breakable_barrier` `break_speed`** below 300 acts as 300 and above 800 is unreachable; above 600 needs wet ground.
- **Surf and slopes**: a see-saw's raised end is a wall for the surf; basin rims and sloped tiles are ramps; a ladder cell with spikes in it breaks climbing.
- **Closing doors wait**: they won't crush, so don't use a door as a hazard.
- **Metal blocks sink in water and float on slag**; ice does the reverse (ice in slag melts almost at once). Pick the liquid to pick the block.
- **Stingbot has no pathing** and can get stuck behind walls. **Mines have no line of sight** and blast through thin walls.
- **Hanging**: conveyors, button pedestals, receivers and barriers are deliberately *not* ledge-grabbable; doors, blocks and see-saw ends are.
- **Order of nodes**: place receivers, buttons, doors and swings before the Player in the tree so the player draws in front of them.
- **Sounds**: every new element needs a sound hook and an entry in `Audio.PLANNED`.

Reads with: `puzzles.md` (the primitives and combinations built from these pieces), `player.md` (verbs), `player-surf.md` (surf numbers), `power.md` (sources, devices, wiring), `enemies.md`, `hazards-traps.md`, `platforms-conveyors.md`, `meltable-blocks.md`, `rotating-bodies.md`, `lasers-arcs-mirrors.md`, `liquid-system.md`, `saving-levels-ui.md` (collectibles, checkpoints, finish)
