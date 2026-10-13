# Level design reference: what the game can do

A designer's view of the game as it stands: every verb, surface, object and interaction, with the numbers and gotchas that matter when laying out a level. It is a summary: the topic files hold the detail and the reasoning, and where this file and the code disagree, the code wins. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first. The puzzle patterns built from these pieces are in a separate file.

Covers: Player verbs; Terrain and surfaces; Object catalogue (Movers: platforms, belts, pads, rails, barriers, powered bridges and ladders; Rotating bodies: see-saw and swing; Blocks: ice, metal and carbon fiber; Liquids: water, slag, steam; Beams and projectiles: laser, arc, cannon, mirror; Hazards; Enemies; Power: sources, wiring, devices; Collectibles, checkpoints, finish); Interaction matrix; Gaps, limits and gotchas

**Units.** 1 tile = 16 px. The camera shows 512×288 px, which is **32×18 tiles**. Speeds are px/s; a walk is 150 px/s (about 9.4 tiles/s). Numbers are the documented defaults and may have been retuned.

## Player verbs

| Verb | How | Notes for design |
|---|---|---|
| Walk / jump | left/right, jump | Coyote time and jump buffering. Small step-downs are walked down, not fallen off. Walking into a **carbon fiber block** pushes it (see Blocks); every other body in the world stops you. |
| Crouch / sneak | down; down + left/right | Crouch collider is shorter (fits low gaps). **Sneak** creeps at 50 px/s. Crouching on a button presses/cycles it. |
| Kick | kick | Hits enemies (`take_damage`), turns mirrors, shoves blocks, boots mines. Ground kick roots you; **air kick** doesn't, and cancels upward speed (never slows a fall). No dash, no dodge. |
| Ladder | up/down at a ladder tile | Ladders are their own tile layer, sharing a cell with the catwalk they pass through. |
| Ledge hang + mantle | airborne beside a ledge | Works on ground, glass, catwalk tiles and on bodies in group `ground` (doors, blocks, see-saw ends, moving/drop platforms). **Not** on conveyors, button pedestals, receivers, barriers. |
| Catwalk underside hang | jump up into a catwalk, or crouch + jump while standing on one | Left/right **brachiates** hand-over-hand. Jump goes up through the catwalk. Blocked by terrain. Hands off onto a ladder with up/down. A **powered catwalk layer** that retracts lets you go. |
| Crust underside hang | same as catwalk, under a basin's crust | Only where a **drain has left a void** under the crust. Refused while liquid fills the space. |
| Swing hang | airborne near a swing bar | Left/right pumps; jump releases with the bar's velocity; crouch drops. |
| Rail hang | airborne near a grabbable rail | Flat rail: brachiate. Steep rail (>10°): slide. Jump or crouch to leave. |
| Swim | in water or slag | Slag is buoyant and hurts every frame. Electrified water hurts. Kick/crouch/grabs are disabled while swimming. |
| **Chill** | in a freeze beam, or inside a frozen crust that formed around you | Walk, sneak and swim speed fall to **half** at full chill (instant on, fades over 0.5 s after the last source). It never hurts and never removes control, so the beam can always be left. The surf and a launch's momentum (pad, swing release) are **not** slowed; jump height, ladders and rails are not either. Overlapping sources don't stack. Every enemy is slowed the same way (see Enemies). |
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
| **Catwalk** tile (or body in group `catwalk`) | one-way (jump up through, stand on top) | yes (side + underside) | **passes** | **passes** (falls through) | Keep on its own tile layer in group `catwalk`. A **powered catwalk layer** makes a run of it appear and vanish. |
| **Ladder** tile | none | n/a | passes | passes | Own tilemap layer. A **powered ladder layer** makes a run of it appear and vanish. |
| **Spike** tile | none (hurts) | no | passes | passes | Four orientations. Damage polled every frame. A tile can't be powered: paint it on a **powered spike layer** to switch it. |
| **Crust** (basin) | yes, walkable | underside only (over a void) | blocks | blocks | Forms when water meets slag (a **reaction crust**, permanent), or when a freeze beam freezes a `freezable` basin (a **frozen crust**: slippery, and a laser can thaw it). |
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

**Powered catwalk layer and powered ladder layer.** Two `TileMapLayer`s that exist only while powered: a bridge or a ladder a button summons. Paint catwalk or ladder tiles on them exactly as on the level's `Catwalks` and `Ladders` layers (the catwalk layer's tile set is the ground tileset, the ladder layer's is the ladder tileset) and wire them like any device. A catwalk with a ladder through it takes one layer of each on the same source; put the ladder layer at the same position as the level's `Ladders` layer so the cells line up.
- **Knobs**: `sources`, `invert` (out while the source is off: a floor a button removes), `warn_time` (1 s, 0 = none), `show_ghost` (off) and `ghost_opacity` (0.25 of the layer's own opacity; only shown while the ghost is on). The same ghost knobs are on the spike layer.
- **Reacts to**: the level of the power state. Powered = out, unpowered = retracted, unwired stays out. **Extending is instant. Retracting waits `warn_time`**: the layer blinks at 5 Hz, still solid (a ladder still climbable), then goes, so the retract is `warn_time` later than the source and a TIMED button's `duration` is the time before the blink starts. Power returning during the blink cancels it. The startup state snaps with no blink and nothing is saved: the layer follows its source after a restore.
- **Affects (catwalk layer)**: out, it is a one-way solid in group `catwalk`, so the player's hang probes, the laser (passes), water and steam (pass) and the ladder-landing scan all treat it as any catwalk. Retracted, a standing player, block or enemy **drops**, and a player hanging from its underside or mid-mantle is **released** (with the regrab lockout). Extending into a body is harmless: the tiles are one-way, so it rises through.
- **Affects (ladder layer)**: out, the player can climb it; a player on it as it retracts is dropped on the next frame. Nothing else reads ladders.
- **Ghost view**: with `show_ghost` a retracted layer stays drawn faintly where it will be. It is only a drawing: nothing about it is solid, climbable or dangerous, and the blink alternates full and ghost. It says where, never when.
- **Gotchas**: **only catwalk tiles** go on a catwalk layer (ground and glass can't be switched; a configuration warning names a stray cell). A powered bridge's cells must stay off the static catwalk layer: a static tile in the same cell keeps its collision, so a hanger is released and may re-grab it (untested). Water falls through a bridge, so a bridge holds no liquid, and a beam passes it. Without the ghost a retracted layer is invisible, so it hides the route it guards. **A checkpoint on a powered bridge** restores the layer from its source: with the source off the bridge gets one blink and then retracts under the respawned player. Move the layer's `PowerTarget` child to the tile a conductor wire should end at. `traps/bridge_extend` and `traps/bridge_retract` are shared by both layers.

### Rotating bodies: see-saw and swing

**See-saw.** Torque from loads: player weight 2, ice 1 per tile, metal 4 per tile, water 1 per tile of volume, slag 3, enemies and steam pushing the underside (both below). Spring back to level; limit ±25°. Per-instance `length_tiles`.
- Powered = **motorized**: it oscillates between limits, and the motor must beat opposing loads. Unwired it's free.
- `mirror_surface` makes the whole top face reflect lasers, so tilting it aims the beam.
- Ends are ledge-hangable while tilted less than 15° and moving slowly. The underside is not.
- Read by the **angle sensor** (a power source).
- **Enemy loads are opt-in**: `enemy_weight_scale` (default 0, so enemies ride a plank for free) multiplies each enemy's weight (grunt, drillbot, crawler 2; mine and landed Stingbot 1; the rail bot none). At 1 a grunt counts as much as the player, and what stands on a weighing enemy counts too.
- Raised end is a lip (see surf notes). Idle riders are gripped, so they don't slide off.
- **Steam push** (opt-in): `steam_torque_scale` above 0 (default 0, so a plank ignores steam until a level opts in) lets steam that **dies on the plank's underside** push that spot **up**. Each particle adds about 1.17 torque per pixel of its distance from the pivot, so **steam under the pivot does nothing** and columns under opposite ends oppose each other. Arrivals add and fade over 0.3 s: the push follows the column's density, rises as steam lands and is gone about 0.3 s after the column is cut. At scale 1 a full laser boil of a pool (1 tile/s, about 16 particles/s) landing whole at the tip of a 2-tile plank gives about 45: more than the player standing at the tip (32), less than a 1×1 metal block there (64); raise the scale for a heavier or longer plank. An end that steam lifts behaves like an end that gets lighter: the angle sensor reads it and a block or the player riding that end rises with it. A launching plank (`launch_gain`) calls its stop hook however the plank got there, so it should throw what rests on the end steam lifted if it arrives faster than `launch_min_speed` (not tried with steam).
  - **Gotchas**: only the **underside** counts (a face within 60° of head-on; an end face, the top and tiles add nothing). A column is narrower than the plank and its ±6° cone clips the tip, so one 2 px inside the tip reads about 30, not 45, and the reading is noisy (the puff count is rounded at random). Steam dies on the first solid, so a block or another plank in the column takes it first, and **the plank shadows everything above it**: a surfer or a carbon fiber block over the plank gets no lift from that column. Steam can only lift, never press down: an end it has raised comes back by the plank's spring (`restoring_torque`), a load or a vent under the other end, and with `restoring_torque` 0 and `friction_torque` above the leftover torque it stays where it was left. The push is not saved: after a checkpoint restore it is gone until the column rebuilds (about 1.6 s).
- **Launch** (opt-in): `launch_gain` above 0 (default 0 = a plain plank) makes it a **catapult**. When the plank arrives at a stop faster than `launch_min_speed` (default 0.2 rad/s), everything resting on its **raised** end is thrown along the plank's face normal, about 25° off vertical and leaning toward the end that came down, at `angular speed × its distance from the pivot × launch_gain` px/s, capped at `launch_max_speed` (default 500). Standing at the tip throws furthest. The player and blocks are thrown; enemies are not. Loads on the lowered end, where the weight that tipped it stands, are never thrown. A heavy block's drop arrives at only about 0.3 rad/s, so gains are in the tens (40 on a 4-tile plank threw the player about 3.5 tiles up and 9 across; headless figure).
- **Launch gotchas**: a gentle tip below `launch_min_speed` throws nothing (a light ice block on a short plank may not fire). A **motorised** plank hits its stops every cycle and so launches only with `launch_when_motorised` (default off). A **block** takes the throw divided by its mass, so metal barely moves at a gain that flings the player and ice flies about as far as the player. A player **hanging** from the raised end is not a load and is not thrown. Each stop throws once; a checkpoint restore throws nothing. Sound `interactive/seesaw_launch` (no file yet).
- A block or player on the plank shields the face from above, and a lit block melts onto it.

**Swing.** A rigid-rod pendulum, `length_tiles` (default 4), default ±80° limits. `free_rotation` allows full circles. The player pumps with left/right. Catching it transfers your momentum (`ω = r × v / |r|²`). Releasing hands the bar's tangential velocity to the player (jump adds jump speed). The bar is **not solid**. The arc must be clear of solid tiles (hanging bodies aren't physics-resolved). Powered = motor.

### Blocks: ice, metal and carbon fiber

All three are rigid bodies, sized in tiles, with free rotation by default. They **topple off ledges, can be kicked, and are opaque to lasers**; they press buttons and weight plates, ride belts and get launched by pads. **A walk moves only carbon fiber**: ice and metal can't be pushed by walking (the shove guard discards actor pushes, and an enemy can't move any block).

| | Ice | Metal | Carbon fiber |
|---|---|---|---|
| Weight per tile | 1 | 4 | 0.5 (a 1×1 is 0.5, a 2×2 is 2) |
| Melts to | water (2 s lit) | slag (3 s lit) | **never melts**: a beam only stops on it |
| Cools/refreezes | yes (0.5/s) | yes (0.4/s) | n/a |
| In slag | melts fast, bursting water onto the slag (→ **crust**) | floats (60% submerged) but melts in about 8 s | **floats (60%) and never melts**: a permanent raft |
| In water | floats (about 80% submerged), small bob | **sinks** to the seabed | **floats (60%)** |
| Slippery to stand on | **yes** (ice-rink acceleration) | no | no |
| Surf friction on top | 0.25× (about 4× the coast) | normal | normal |
| Kick | shunts at 100 px/s, slides about 4 tiles; can slide off ledges | shunts at 50 px/s, about 1 tile | shunts at 100 px/s, about 4 tiles |
| Walk | refuses | refuses | **pushed**, at up to 75 px/s (half walk speed) |
| Cannon bullet | **breaks** (bursts to water) | **absorbs it** (a ping), unharmed | **breaks** (fades, no liquid) |
| Crusher | **shatters** (melts to water on the spot) | **jams** the crusher | **shatters** (fades, no liquid); never jams |
| Surf shove | transfers speed; slides up to 18 tiles on ice | moves less (heavy), but still costs the surfer speed | moves furthest and costs the surfer least (light) |
| Steam | ignores it (`steam_lift_accel` 0) | ignores it | **lifts it** (up to 80 px/s) |

- **Melt progress is reversible**: a block lit then shaded refreezes or cools along its animation.
- Floating blocks ride a rising/draining surface. A rider can't hold them down; carrying capacity is `rest_fraction`. Level lever: past 1.0 the block can't carry the load and sinks.
- Swimmers underneath nudge floating **ice** blocks sideways slowly; carbon fiber has no underside push.
- Hanging from a block works while it is flat and still enough (≤10°, ≤90 px/s).
- A melting block spawns liquid per tile **at the block's position**, which then falls and can land on you, on a see-saw, or into a basin.
- **Carbon fiber (`carbon_fiber_block.tscn`) is the block that lasts**: no melt means a laser makes it a permanent shield and slag a permanent raft, so a level that wants a disposable shield or a timed raft offers ice or metal and no carbon fiber. It is light: a lone 1×1 (0.5) can't press a weight plate with a threshold of 2 (a rider, a stack or a bigger block still does), a see-saw reads it as a small load, and a jump pad or catapult throws a 1×1 as far as a 1×1 ice block (a bigger one lifts less).
- **Walk push.** Walking into the side of a carbon fiber block while on the floor pushes it at the lesser of your walk speed and 75 px/s, and you slow to match. **A chain pushes together**: up to 8 carbon fiber blocks in a row, each extra block ×0.75 slower; anything else in the line (a tile, an enemy, an ice or metal block, a wall behind the last) **refuses the whole push** and is a wall as before. **A crouched or sneaking player never pushes.** When the push ends the block **stops dead** on an ordinary floor and **coasts** only on a slippery one (an ice block or a frozen crust), in the air or in liquid. There is no pull: you can only push the way you walk.
- A carbon fiber block pushed off a ledge falls like any block; onto a platform or belt it follows the ordinary block rules.
- **Steam lift.** A carbon fiber block over a steam column is carried up it, at up to **80 px/s** (the steam's own speed), to the top of the column (about 8 tiles above its source) or to a ceiling, and it sinks again when the steam stops. The lift is an acceleration that beats gravity by a wide margin (1,600 against 900 for a lone carbon fiber block), and what it can lift is set by **weight per tile**, not total weight: a 1×1, a 2×1 and a 2×2 all rise the same way, while a 1×1 **ice** block that a level opts in is only slowed in its fall, and metal never reads steam at all.
  - **Knobs** (group "Steam" on any block; `carbon_fiber_block.tscn` sets the first): `steam_lift_accel` (800 on carbon fiber; **0 = off**, the default for ice and metal), `steam_lift_max_area` (4 tiles: up to 2×2 or 4×1; a bigger block gets nothing), `steam_rider_load` (0.25 per rider), `steam_max_rise` (80 px/s) and `steam_drag` (6).
  - **Reacts to**: steam in a thin band hugging the block's **underside**, so what matters is the steam that reaches it from below; a column covering about half the block's width already reads full, and a thinner one lifts less. A reading above about 0.56 lifts an unloaded block and a lower one only slows its fall, so thin steam gives a hover or a slow rise and a full column the full speed. Steam from a crust reaction and from laser boiling both count.
  - **Affects**: the block only. A **rider** (the player or an enemy standing on it; blocks stacked on it are not counted) adds load: one rider slows a carbon fiber block to about 19 px/s, and two **ground it** (the push no longer beats gravity). A block that is lifted carries its rider, and a block that reaches a ceiling stops there as any block does. Steam never moves a walker or an enemy.
  - **Gotchas**: **steam dies on the first solid it meets, a block included**, so a block in a column cuts the steam above it (a surfer over the block gets nothing) and a column cannot lift two blocks one above the other: only the lowest one reads it. A catwalk lets steam through. Steam is not saved: after a checkpoint restore a block that was riding a column falls until the column rebuilds, over about 1.6 s. A boiled pool's steam stops when the beam does, and the block sinks about 0.3 s later.
- **Bullets now stop at every block** (a cannon bullet used to fly through them): metal absorbs it unharmed, so a metal block is a permanent bullet shield (the counterpart of a laser shield), while ice and carbon fiber break under it.

**Block dispenser.** A powered device that makes blocks, so any block can be a renewable resource (a shield that replaces itself, a second weight, a stair). A small housing with a **spawn point** (a marker, one tile below it by default) where each block appears, upright and at rest, and then falls under gravity like any block. Its placeholder art is a steel box with a light: green when it is ready, amber while it cools down.
- **Knobs**: `block_scene` (`ice_block.tscn` by default, or `metal_block.tscn` or `carbon_fiber_block.tscn`), `size_tiles` (the size of each block), `max_alive` (1; 0 = unlimited), `cooldown` (0.5 s; 0 = none), `invert`, and `show_spawn_area` (an editor-only outline of the block's footprint at the spawn point). Move the `SpawnPoint` marker to put the block somewhere else, and the `PowerTarget` child to choose where a wire attaches.
- **Reacts to**: a **rising edge** of its power, nothing else: a source that stays on spawns once, a falling edge does nothing, and an inverted dispenser spawns when its source falls. The startup state and a checkpoint restore are never edges, so a level never loads with a block waiting. An unwired dispenser never spawns. An edge during the cooldown is ignored.
- **Affects**: its own blocks, which are ordinary blocks in every way (kickable, meltable, a plate or see-saw weight, hangable, carried by belts, launched by pads). It keeps at most `max_alive` of them: a new block **dissolves the oldest** (a quiet fade, no liquid), and a block that melted or shattered no longer counts, so its slot is free. It never touches another dispenser's blocks.
- **Gotchas**: **a spawn into an occupied area is refused**: if the player, an enemy, a block or a tile is inside the block's footprint, the press does nothing but a "blocked" sound (the old block is not dissolved and the cooldown does not start). That includes the block you made last time if it is still sitting under the dispenser, unless it is the one about to be retired. With `max_alive` above 1, the spawn point has to be somewhere blocks leave (a drop, a slope, a belt, a kick) or the second press is refused. **A block a dispenser made is taken back by the next one**: with `max_alive` 1, a block left on a plate or used as a stair vanishes the next time the dispenser fires, whatever the player is doing with it. The dissolved block stops being solid at once, so whatever stood on it falls. A dispenser's blocks are saved with it: a checkpoint keeps the blocks that were alive then, and a restore makes none. Nothing about its state is visible to the player beyond the light, so wire a lamp, a door or a gem to what it is meant to show. No new block can appear without a rising edge, so a block lost to a melt, a pit or slag can only be replaced by the player causing one.

### Liquids: water, slag, steam

- **Water particles** flow, creep, and fall through catwalks. Moving particles shove the player a bit and are carried by moving solids. Water on a see-saw adds load.
- **Slag particles/pools** burn the player on contact (each frame of submersion or touch). Buoyant to swim in.
- **Basin** (`WaterBasin`): a hand-sized container sampled from the tiles under it. Authored: `liquid_type`, `initial_fill_depth_below_surface`, `boilable`, `conducts_sparks`, `electrified_time`, `freezable`, `freeze_time`, `melt_time`. Fills from particles and **spills over its shorter wall into the next basin** (basins chain without adjacency data).
- **Faucet**: `flow_rate`, `liquid_type`, powered = open. Placed on a basin's interior floor tile, it's a **drain** (removes liquid, leaves any crust hanging over the void). Elsewhere it's a **source**.
- **Crust**: opposite liquids meeting in a basin solidify a 0.75-tile slab across the wet columns and emit **steam**. This **reaction crust** never grows or thins and nothing removes it (a laser is simply stopped by it). Walkable, laser-opaque, hangable from beneath where a drain has left a void. Same-liquid arriving on top just rests on it. Opposite liquid arriving on it evaporates into steam.
- **Steam**: rises 80 px/s in a narrow cone (about 6° either way), about 8 tiles tall, stops at ceilings and at the first solid it meets. **Three things feel it: the surfing player** (up to 1,500 px/s² of lift, which raises the board off the floor once it exceeds gravity), **a carbon fiber block** (see Steam lift under Blocks) **and the underside of a see-saw** with `steam_torque_scale` above 0 (a push on the plank, see Steam push under See-saw). Walkers, swimmers, enemies, ice and metal do not.
- **Skim**: a surfer at 180+ px/s on a still, non-hazardous, crust-free basin rides the surface on a temporary floor. Slower, slag, or electrified water: swim or sink instead.
- **Laser boiling**: `boils_water` on the turret *and* `boilable` on the basin. Drains it and makes steam. Slag is never boiled.
- **Frozen crust**: a `freezable` basin (default off) that holds water **or slag** and has no crust freezes after `freeze_time` (2 s) of a freeze beam on its liquid. Frost decays 1 s per second once the beam leaves, so a short touch is forgotten. It forms the same 0.75-tile slab, with **no steam**, and the liquid under it stays (so a drain can still open a void for the underside hang). It is walkable, laser-opaque, a basin sensor reads it as CRUST, and it is **slippery underfoot** (ice-rink acceleration; the surf's friction is unchanged, and a surfer rides it at any speed, the opposite of a skim). It differs from a reaction crust in three ways. **A laser thaws it**: `melt_time` (2 s) of laser on the crust, then it reverses its cooling animation, stays solid until the first frame and the whole slab goes (never a hole), the liquid band returning with no steam; if the laser leaves, the thaw backs off and the crust cools again. **Frozen slag is temporary**: it is held only while the beam stays on it (a few frames of grace) and thaws backwards when the beam leaves; a freeze still short of its last frame does the same, even on water. A fully frozen water crust stays until a laser melts it. **It conducts**: see Electrified water. A player inside the band when it forms is **embedded**: the crust ignores them (set once, at the freeze), they are chilled and swim up through it, and it is solid for them once they are above it. The freeze is non-lethal and seals nobody in.
- **Electrified water**: a spark (rail bot) or arc touching a crust-free water basin electrifies the whole pool for `electrified_time`. Hurts a submerged player and kills skimming. Nothing else reads it. A strike on a **frozen crust over water** electrifies it too (frozen slag never): while it lasts the **top of the crust hurts a player standing on it** (airborne is safe; a submerged or embedded player is hurt by the liquid as before), paced by i-frames. An electrified pool that freezes keeps its remaining time on the crust.
- **Basin sensor**: a power source reading fill fraction, crust, or one column's depth, optionally filtered to water/slag. CRUST reads a frozen crust too, so over a `freezable` basin it can fall again when the crust thaws.
- **Wet floor**: flowing water over the floor raises surf top speed to 800 and cuts friction. It decays 0.4 s after leaving the water.

### Beams and projectiles: laser, arc, cannon, mirror

| | Laser | Arc | Cannon bullet |
|---|---|---|---|
| Shape | continuous beam | slow projectile (220 px/s, range 480) | fast projectile |
| Reflects off mirrors | **yes** | **yes** | no (a bullet *hits* a mirror only if `bullet_rotates`) |
| Stopped by | solids, doors, blocks, enemies, mirror backs | tiles, doors, blocks, mirror backs | the player, world tiles and blocks (metal absorbs it, ice and carbon fiber break) |
| Passes through | catwalks, glass | catwalks, glass, **enemies, player layer** | other traps/enemies |
| Hurts | the player (per frame, polled), enemies (1 per 0.5 s) | the player only | the player |
| Melts | ice/metal blocks (never carbon fiber) | no | no |
| Lights/triggers | **laser receiver** | **arc receiver**, electrifies water | **bullet target** |
| Boils water | optional | no | no |

- **Laser turret**: aim = instance rotation. Powered = beam on. `damage`, `boils_water`. It also thaws a frozen crust (see Frozen crust).
- **Freeze turret**: aim = instance rotation, powered = beam on, `start_enabled`, `invert`. The cold of the family: a continuous beam on the same solver as the laser (reflects off mirrors, passes catwalks and glass, stopped by solids, doors, blocks, enemies, the player, a crust and mirror backs) whose effect is **cumulative**, so the dwell lives on the target, never the turret. It **never hurts**. It freezes a `freezable` basin (`freeze_time`), powers a **freeze receiver** (`dwell_time`), chills the player and any enemy it ends on, and does nothing to blocks, ice or metal (they are plain shields, with no lifespan).
- **Arc turret**: `fire_interval` 2 s, `phase_offset`, `arc_speed`, `arc_range`. Powered = firing (a rising edge fires one at once). The telegraph is a growing glow in the last 0.45 s.
- **Cannon**: `fire_rate`. Powered = firing (rising edge fires one at once). Aim = rotation. The housing is a standable solid.
- **Mirror**: one checkbox per instance, `toggle_between_aims`, picks how it turns; the Inspector shows only that mode's fields. `rotate_time`, `kick_rotates`, `bullet_rotates` (off by default) and `invert` apply to both. Solid to the player. A mirror's back and edge block beams. Can ride a moving platform.
  - **Step mode** (default): the instance's rotation is step 0. A kick turns it `rotation_step_degrees` (45°) in `rotate_direction`, and so does each **rising edge** of power (falling edges do nothing). A bullet turns it one step.
  - **Toggle mode**: two aims, `aim_0_degrees` (unpowered, and the start) and `aim_1_degrees` (powered), each the node's rotation in degrees, so the instance's rotation in the editor is ignored. Power **follows the level**: on is aim 1, off is aim 0, on both edges. A kick or a bullet flips to the other aim until the next power change. The sweep takes `rotate_time` and runs the numeric way (0 to 270 turns 270°, 0 to -90 the short way). The editor draws both aims.

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
- **Knobs**: `sources`, `invert` (spikes out while the source is off, which is what "a button retracts them" needs). No timing exports: the transition is instant. `show_ghost` and `ghost_opacity` (see the catwalk and ladder layers) draw the retracted field faintly; a ghost spike is harmless.
- **Reacts to**: the level of the power state, both edges. Unwired it stays out, so it behaves like spikes on the ground; the startup state snaps with no sound and a restore follows the sources.
- **Affects**: only the player, through the same hit as any spike (1 damage, knockback away from the tile, i-frames, a surf ends). It has no collision and no `surface_type`, so it blocks nothing and is never ground-like. Enemies and blocks ignore it, as with spike tiles.
- **Gotchas**: **no warning phase**, so spikes that extend under a player standing in them hurt on that frame, and spikes that retract spare the player the same frame. Show the player what is about to extend (layout, a camera cue on the same source) rather than relying on a telegraph. Power switches the whole layer, so independent groups of spikes are separate layers. **Move the `PowerTarget` child to the tile a conductor wire should end at** (it starts at the layer origin). A retracted layer is invisible unless `show_ghost` is on, so it hides the route it guards until it is powered; turn the ghost on (it marks where the spikes will be, not when) or pair it with a hint if the player has to find it.

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

**Enemy weight** (`load_weight`, in the units of block mass): grunt 2, drillbot 2, tread crawler 2 (flipped too), proximity mine 1, Stingbot 1 **only while landed**, rail bot none. An enemy weighs it only while alive and on the floor, so a dying one, a flying Stingbot and anything airborne weigh nothing. Read by the **weight plate** (always, `enemy_weight_scale` 1) and the **see-saw** (opt-in, scale 0). The defaults are first guesses to tune against plate thresholds.

### Power: sources, wiring, devices

**Every powered device** carries a `PowerTarget`. With nothing wired it behaves as authored. A target has `sources` (any number), `all_required` (AND vs the default OR), and `invert` (also exportable on the device root). `debug_toggle_key` flips any device from the keyboard while testing.

**Sources**

| Source | Powers when | Knobs |
|---|---|---|
| **Button** | pressed by player or any block (not enemies/liquid) | `latch_mode` MOMENTARY / TOGGLE / TIMED (`duration`); colour is art-only |
| **Speed trap** | a *surfer* crosses its line at ≥ `threshold_speed` (450) | `hold_time` (5 s, 0 = latched), `require_surfing` |
| **Laser receiver** | lit by a beam; stays on `hold_time` (0.3 s) after | the flicker bridge |
| **Freeze receiver** | the freeze beam has stayed on it for `dwell_time` (1 s; 0 = at once); stays on while lit and `hold_time` (0.3 s) after | frost builds 1 s per second of beam and decays 1 s per second without, so a sweep across does nothing and a beam that leaves and returns keeps what is left; opaque, lit on any face |
| **Arc receiver** | hit by an arc | `latch_mode`; MOMENTARY pulse 2.5 s, TIMED 5 s, TOGGLE |
| **Bullet target** | hit by a cannon bullet | `latch_mode`; MOMENTARY pulse 0.3 s, TIMED 5 s, TOGGLE |
| **Weight plate** | summed weight ≥ `threshold` (2) | `hold_time` 0.15 s, `player_weight` 2, `enemy_weight_scale` 1 (0 = ignore enemies); counts stacked blocks, enemies and riders up to 3 deep |
| **Angle sensor** | a `RotatingBody` tilts past `threshold_degrees` (15) toward `side` | `hysteresis_degrees` 3 |
| **Basin sensor** | FILL ≥ 50%, CRUST present, or COLUMN depth ≥ 0.25 tile | `liquid_filter`, hysteresis, `hold_time` |
| **Zone sensor** | `min_count` or more bodies (player, enemies, blocks, as enabled) are inside its rectangle | `size`, `count_player` / `count_enemies` / `count_blocks`, `min_count`, `hold_time` 0.15 s |
| **Delay** (logic) | the input has stayed on for `on_delay` (1 s); falls once it has stayed off for `off_delay` (0) | a flicker shorter than the delay never passes |
| **Latch** (logic) | a `sources` input has been on; stays on after it lets go until a reset input is on | `reset_sources`, `start_on`; reset dominates |
| **Counter** (logic) | `count_to` (3) rising edges of its sources, each source counting on its own | `reset_sources`, `auto_reset_time` (0 = stays on) |
| **Pulse** (logic) | for `duration` (1 s) after a rising edge of its input, whatever the input does next | a new edge restarts it; `invert_input` triggers on the fall |
| **Camera cue pass-through** | mirrors the cue's final state, but a rising edge waits `delay` + `pan_time` | lets a device start once the camera has arrived |
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
- **Pass-through**: the cue is also a source (picked in a device's `sources`; not a wire object) that mirrors its final state after `invert`, with one difference: a rising edge is held back `delay` plus `pan_time` seconds, so what it drives starts once the camera is in position. A falling edge passes at once and cancels a wait. When no cue will play for an edge (`once` spent, a cooldown running, the player dead or dancing) the edge passes with no wait. The startup state passes at once, so a device wired to it snaps instead of counting an edge. It can feed a logic node.

**Zone sensor.** An `Area2D` source (layer 0, mask 1) that is powered while enough bodies are inside an axis-aligned rectangle: a door that shuts behind the player, an ambush trigger, a lure where an enemy has to stand in the zone. It blocks nothing, so it is wired like any source (`sources` on a device, or a conductor ending at its origin cell). **Invisible and silent in play by default.**
- **Knobs**: `size` (px, default 48×48, centred on the origin; leave rotation and scale alone), `count_player` (on), `count_enemies` (off), `count_blocks` (off), `min_count` (1; the count is summed across the enabled kinds), `hold_time` (0.15 s, up to 5 s and beyond), `show_zone` (draws the zone and the live `count/min_count` at run time; the editor always draws it), `silent` (on; turn it off for on and off sounds).
- **Reacts to**: bodies overlapping the zone, in any state. The player counts unless dead or dancing, so a player on a ladder, hanging or swimming counts (unlike a weight plate, which wants the floor). An enemy is anything in group `enemy`, so a dormant mine and a flipped crawler count. A block is any ice or metal block, and weight is irrelevant: a metal block counts as one, like an ice block, and one in the air counts. Each body counts once. It powers the frame the count reaches `min_count` and releases once the count has stayed below it for `hold_time`, so a body crossing the edge cannot chatter it, and a longer `hold_time` is a delay on leaving. Absence is `invert` on the device or target.
- **Affects**: only what is wired to it. Nothing in the world reads it directly. It counts bodies in any state, where the weight plate counts only weight on the floor.
- **Gotchas**: the zone is invisible and silent, so the player gets no warning of it. Drive something the player can see coming (a door closing, a bullet in flight, a camera cue) rather than a spike layer that extends with no warning, and put the zone's edge well before the hazard. A zone knows nothing of speed or direction (the speed trap does): a surfer covers 10 to 13 px a physics frame at 600 to 800 px/s, so a zone across a surf line should be deeper than that, or tested. A conductor attaches in the cell the **origin** (the centre) is in, so wire a large zone through `sources`. An enemy leaves the group as it starts to die (a Drillbot and a Stingbot at the end of that frame), and a Stingbot flies, so a zone meant to hold one has to cover its airspace. A zone that only an enemy can power is stuck off once that enemy is dead, so give the route a second way (OR). It saves its state, so a checkpoint restore comes back as it was (a sealed room stays sealed) and keeps power for a few frames until the bodies overlap again.

**Logic nodes.** Four small sources (Delay, Latch, Counter, Pulse: `logic_delay.tscn`, `logic_latch.tscn`, `logic_counter.tscn`, `logic_pulse.tscn`) that read other sources and give back a state of their own, for what OR, AND and `invert` cannot do: wait, remember, count, make a pulse. A device picks one in its `sources` like a button. No collision, art or sound at run time; the editor draws a tag and a line to each source (orange for a reset list).
- **Knobs**: every node has `sources` (any node with `is_powered()`: buttons, receivers, plates, sensors, a camera cue's pass-through, other logic nodes), `all_required` (AND instead of OR; hidden on the Counter), `invert_input` and `draw_links`. **Delay**: `on_delay` 1 s, `off_delay` 0. **Latch**: `reset_sources`, `start_on`. **Counter**: `count_to` 3, `reset_sources`, `auto_reset_time` 0 (never). **Pulse**: `duration` 1 s.
- **Reacts to**: **Delay** both edges of the combined input, each only if the input stays there the whole delay, so an on-delay filters short presses and an off-delay stretches them (a zero delay is instant that way; both zero is a plain pass-through and warns). **Latch** levels, not edges: a set on makes it on and it stays on; while any reset source is on the output is off and a set cannot take, and when the reset lets go a set that is still on latches again at once. **Counter** rising edges, **each source on its own** (a second source rising while the first is held counts), so one pad pressed three times and three pads pressed once each both reach 3; stepping onto a pad is an edge and so is each crouch-cycle of a momentary button, a TOGGLE button counts only its turn-ons, and `invert_input` counts turn-offs instead. Edges past `count_to` are ignored; while a reset source is on the count is held at 0, the output is off and edges are not saved up; `auto_reset_time` clears the count that long after the output goes on. **Pulse** the rising edge (the falling edge with `invert_input`).
- **Affects**: only what is wired to it, and nothing in the world reads it directly. A logic node is not a wire object, so a conductor cannot end at one or start from one: to bring a wire in, put a button or sensor on that wire.
- **Gotchas**: a logic node is **invisible and silent**, so the player cannot see a count, a wait or a latched state: give every one a visible consequence (a door, a bridge, a powered gem) or the player cannot tell an input registered. **Startup is never an edge**: an input already on at load is not counted, pulsed or waited for (a Latch with `start_on`, or a set already on, starts latched). Nodes may read each other, but a loop that cannot settle is cut at 16 deep with one warning, and the Inspector warns about any node that can reach itself. Timers are plain countdowns, so pausing freezes them. Everything is saved (output, input level, pending waits, counts), a restore is silent, and a source restored after the node cannot fake an edge. A source is added at run time by assigning `sources`; there is no `add_source()`. There is no counting window (a count is not cleared by a quiet spell) and no per-source `all_required` on the Counter.

**Powered devices**

| Device | Powered means | Quirk |
|---|---|---|
| Door | open | invert = starts open |
| Laser turret | beam on | |
| Freeze turret | beam on | non-lethal; `invert` = on while unpowered |
| Arc turret / Cannon | firing | rising edge fires immediately |
| Conveyor | running | |
| Faucet | open | drain or source by placement |
| Moving platform | running | pauses where it is |
| Crusher | cycling | parks retracted when off; clears jam on re-power |
| Sawwheel | spinning/dangerous | |
| Jump pad | live | |
| **Block dispenser** | **rising edge = make one block** at its spawn point | startup is not an edge; an edge in the cooldown or into an occupied area is dropped; past `max_alive` the oldest block dissolves |
| **Mirror** | **step mode: rising edge = turn one step; toggle mode: powered = aim 1, unpowered = aim 0** | step mode: startup is not an edge; toggle mode: snaps to its aim at load, and a change mid-turn turns it back |
| See-saw / Swing | motor on | |
| Rail bot | running | stops dripping when off, still hurts |
| Powered gem | present and collectible | unpowered = hidden |
| **Camera cue** | **rising edge = pan the camera to it**, hold, return | startup is not an edge; no input lock |
| **Powered spike layer** | spikes out | unwired stays out; `invert` retracts on power; instant, no warning |
| **Powered catwalk layer** | bridge out (one-way solid) | unwired stays out; `invert` removes it on power; extends at once, blinks `warn_time` before it retracts; releases a hanger |
| **Powered ladder layer** | ladder out | as the catwalk layer; a climber is dropped as it retracts |
| Finish | optional lock input (see Collectibles, checkpoints, finish) | |

### Collectibles, checkpoints, finish

- **Gem**: counted in the level total. **Bonus gem**: 50 points, **not** counted toward unlock %; can be **powered** (trail appears/disappears). Placing gems along a launch arc doubles as a guide to the line (it's a level design trick, not code).
- **Medkit**: heals 2, gives 10 points even at full health.
- **Points**: popups exist for 5, 10, 20, 50.
- **Checkpoint**: `order` auto-numbered, a higher order overrides a lower one, and it snapshots everything saveable. Respawn re-applies it.
- **Finish**: unlocks at `required_gem_percent` (default 100) of the level's gems, optionally AND/OR a wired button (`require_all`). Plays the exit dance and the level-complete overlay. `next_level` overrides the next row in the catalog.

**What a restore keeps and drops** (it matters for puzzles):
- Kept: button/receiver state, door frame, blocks (position, melt progress), enemies, mirrors, see-saw angle, platform phase, basin fill and crust (a frozen crust comes back cold, slippery and meltable), crusher state and jam.
- Dropped: liquid particles in flight, bullets, arcs, sparks, steam, drop-platform state, electrification, frost and heat, chill, the embedded latch. A basin mid-overflow comes back settled; a dangerous state restores harmless. A freeze still in progress, and frozen slag held by a beam, come back as the plain liquid; a freeze receiver comes back full if it was powered, else empty, and the live beam takes over.

## Interaction matrix

Row = thing acting; columns = what it does to each target. Read this to find combos.

| Actor ↓ | Ice block | Metal block | Carbon fiber block | Water pool | Slag pool | Player | Enemies | Mirror | Door/solid |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Laser** | melts → water | melts → slag | stopped, **never melts** | optional boil (needs flags); thaws a frozen crust over it | not boiled; thaws a frozen crust over it | damage/frame | 1 dmg/0.5 s | reflects | stopped |
| **Freeze ray** | stopped, no effect | stopped, no effect | stopped, no effect | freezes a `freezable` basin after `freeze_time` → frozen crust | freezes it, **held only while the beam stays** | chills (half speed), no damage | chills, no damage | reflects | stopped |
| **Arc** | – | – | – | electrifies (also through a frozen crust over it) | – | damage | – (passes) | reflects | stopped |
| **Bullet** | **breaks** (bursts to water) | **absorbed** (a ping), unharmed | **breaks** (fades) | – | – | damage | – | turns or flips it (opt-in) | stopped |
| **Spark** | – | – | – | electrifies (also through a frozen crust over it) | – | damage | – | – | – |
| **Kick** | slides it | slides it (short) | slides it | – | – | – | damage / flips crawler / arms mine | turns 45° (step) or flips aim (toggle) | – |
| **Surf** | shoves (long) | shoves (short) | shoves (long, cheap) | skims if ≥180 | burns/ends surf | – | bowls | – | breaks barrier |
| **Steam** | ignores it (opt-in only, and too heavy to rise) | ignores it | **lifts it**, at up to 80 px/s (one rider slows it, two ground it) | – | – | lifts a **surfer**; a walker or swimmer feels nothing | – | – | stopped by it (a block's underside ends the column); a **see-saw** with `steam_torque_scale` above 0 is also **pushed up** at its underside |
| **Crusher** | **shatters** | **jams crusher** | **shatters** (fades, no liquid) | – | – | damage | – | – | – |
| **Slag touch** | melts fast, → crust | floats, slow melt | floats, never melts | **crusts** it | rejoins | hurts | – | – | – |
| **Water touch** | floats | sinks | floats (60%) | joins | **crusts** it | – | – | – | – |
| **Jump pad** | launches (weight-scaled) | launches (less) | launches (a 1×1 as far as ice) | – | – | launches | – | – | – |
| **See-saw stop** (with `launch_gain`) | launches if on the raised end (weight-scaled) | launches (less) | launches if on the raised end (weight-scaled) | – | – | launches if on the raised end | – (no `launch()`) | – | – |
| **Block dispenser** (makes) | makes one; past `max_alive` the oldest dissolves | the same | the same | – | – | its spawn area occupied: the press is refused | its spawn area occupied: refused | – | solid in the spawn area: refused |
| **Mine blast** | – | – | – | – | – | damage | 2 dmg | – | – |
| **Retracting catwalk layer** | drops | drops | drops | – (water already falls through a catwalk) | – | drops; a hanger is released | drops | – | – |
| **Retracting ladder layer** | – | – | – | – | – | a climber is dropped | – | – | – |
| **Zone sensor** (reads) | counted if `count_blocks` | counted if `count_blocks` (weight is irrelevant) | counted if `count_blocks` (weight is irrelevant) | – | – | counted if `count_player` (not dead or dancing) | counted if `count_enemies` | – | – |
| **Weight plate** (reads) | 1 per tile | 4 per tile | 0.5 per tile | – | – | 2 while on the floor | grunt, drillbot, crawler 2; mine, landed Stingbot 1 (× `enemy_weight_scale`); not in the air or dying | – | – |
| **Walking player** | refuses (a wall) | refuses (a wall) | **pushes it** (up to 75 px/s; a chain, never crouched) | – | – | – | – | – | – |

**What presses what**
- Button: player + blocks (a carbon fiber block too: its weight is 0.5 per tile, which matters only to a plate). Weight plate: player (standing) + blocks + enemies on the floor (+ stacked riders, through a block or an enemy). See-saw load: player + blocks + liquid (+ enemies when `enemy_weight_scale` is above 0, + an upward steam push on the underside when `steam_torque_scale` is above 0). Speed trap: only a surfer. Zone sensor: any body of an enabled kind inside it (player, enemies, blocks), whatever it weighs.
- Steam is read by a surfing player and by a carbon fiber block, through the same query, and pushes a see-saw plank that opts in (when a particle dies on its underside, a separate path); nothing else (no sensor, no enemy) reads it.
- Logic nodes and the camera cue's pass-through press nothing: they read other sources' levels and edges, and only a device's `sources` (or another logic node) reads them.
- Receivers are lit by beam/arc/bullet/freeze ray *specifically*. A laser does nothing to an arc receiver or a freeze receiver, and vice versa.

## Gaps, limits and gotchas

**Things you can't do (yet)**
- **Spikes switch per layer, not per tile**: a tile can't carry a `PowerTarget`, so independent groups of spikes are separate layers, and a spike with its own timing (a warning, a stroke) must be a node (e.g. a crusher or sawwheel).
- **Only catwalks, ladders and spikes can be switched as terrain.** Ground and glass can't (the basin scans, the water manager and the laser's world lookup assume one `world_tilemap`), so a wall or floor that appears is a door, a drop platform or a crust (a frozen crust is the one the player can summon with a beam and take away with a laser).
- **The player can push only carbon fiber by walking**; ice and metal move by kick, surf-shove or (in water, ice only) underside push. There is no pull and no carrying; the only lift is steam under a carbon fiber block (see Blocks).
- **A mirror has two powered aims at most** (toggle mode); more positions need step mode (one step per rising edge) or several mirrors.
- **The freeze ray freezes only `freezable` basins and powers only freeze receivers.** It does not freeze blocks, doors or the player; chill is a slowdown, not a stop. Chill is a flat half speed, not a dial.
- **No lever object**; no keys or carryable items; no pickup that persists to other levels.
- **No ranged attack for the player** and **no dodge**; every enemy interaction is a kick, a stomp, a surf, or an environmental trick.
- **An enemy presses a weight plate (and, if the plank opts in, tips a see-saw, and so can drive a catapult's drop) but never a button, and a see-saw never throws one**; it can also power a zone sensor (`count_enemies`). Liquid opens a door only through a basin sensor.
- **Steam moves only a surfer, a carbon fiber block and a see-saw plank that opts in** (`steam_torque_scale`, from below only); walking players, swimmers, enemies, ice and metal don't feel it (ice and metal can be opted in per instance with `steam_lift_accel`, but they are too heavy per tile to leave the floor).
- **Wire layout is fixed at load**; painted conductors don't rewire at runtime. A conductor also cannot reach a logic node or the camera cue's pass-through (neither is a wire object): put a button or sensor on the wire, or pick the source in `sources`.
- **No free-running clock node**: a clock is a crusher, an arc turret, a patrol through a zone or a motorised see-saw read by a sensor. A ring of logic nodes is not a supported one: the editor warns of the loop, and startup is not an edge, so it would not start by itself (untested).
- **A level editor is a stretch goal**, and not built.

**Things that are traps for the designer**
- **`freezable` is off by default**: a basin the beam crosses does nothing until it is set. Check `freeze_time` against how long the beam really rests there (a mirror in motion, a shadow from a passing enemy).
- **Frozen slag is a held bridge, not a latch**: it thaws within a few frames of the beam leaving, and a water crust interrupted before its last frame reverses too. Only a fully frozen water crust stays, and a laser still removes it. A CRUST sensor over a `freezable` basin is a resettable latch, where one over a reaction crust is permanent.
- **A frozen crust is slippery**: a platform of it over a pit or spikes needs run-up room and a stopping place, since a walker keeps momentum on it. A surfer is not affected.
- **The beam is opaque to bodies**: a grunt, a Stingbot or the player standing in the beam ends it there and shadows whatever is behind, so a freeze receiver behind a patrol goes dark and loses frost 1 s per second. A laser on a frozen crust or the beam on a reaction crust just stops.
- **Chill is a slowdown only**: a Rail bot slows on its rail but its drip clock does not, so it drips closer together; a Stingbot's lunge and recoil are slowed as well as its flight.
- **Checkpoint mid-freeze**: a freeze that has not finished comes back as plain liquid with no frost, and a player who was embedded comes back unchilled and unembedded; put the checkpoint before the beam is switched on.
- **A weight plate in an enemy's lane counts the enemy**: the plate is a flush ribbon with no collider, so grunts, crawlers and drillbots walk across it and press it for the crossing plus `hold_time`; set `enemy_weight_scale` to 0 on a plate meant only for the player and blocks. A Stingbot counts only while landed, and a mine counts even when dormant.
- **Catwalk layers**: keep catwalks on their own layer in group `catwalk` (a mixed layer breaks brachiating and the surface checks). A powered bridge is its own layer, kept off the static one.
- **Checkpoint on a bridge**: a restore re-derives a powered layer from its source, so a bridge whose source is off blinks once and retracts under a player respawned on it. Put the checkpoint on ground.
- **Beams are polled by the turret**, so receiver `hold_time` matters; moving or rotating beams need ≥ 0.1 to 0.3 s.
- **Step-mode mirrors rotate on rising edges only**: an inverted or momentary source may give you edges you didn't expect on load (startup is not an edge). A toggle-mode mirror reads the level instead, so use it wherever the state, not the click count, should aim the beam.
- **Toggle-mode mirrors ignore a momentary button's crouch-cycle** (falling then rising in one frame): the mirror ends where it started (one stray turn sound may play). Stepping on and off the button is what swings it.
- **A kick or bullet can put a toggle-mode mirror on the aim the power state doesn't name**; the next power change puts it back. Set `kick_rotates` false (and leave `bullet_rotates` off) on a mirror a switch owns.
- **Arcs aren't saved**: a restore never leaves an arc mid-flight. Don't depend on one.
- **AND of arcs/bullets** needs TIMED latches (or a Latch on each), since they rarely arrive together.
- **`breakable_barrier` `break_speed`** below 300 acts as 300 and above 800 is unreachable; above 600 needs wet ground.
- **Surf and slopes**: a see-saw's raised end is a wall for the surf; basin rims and sloped tiles are ramps; a ladder cell with spikes in it breaks climbing.
- **Closing doors wait**: they won't crush, so don't use a door as a hazard.
- **Metal blocks sink in water and float on slag**; ice does the reverse (ice in slag melts almost at once); carbon fiber floats on both and melts in neither. Pick the liquid to pick the block.
- **Carbon fiber never melts**: a beam or slag will not remove it, so a puzzle that relied on a shield or raft running out needs ice or metal. What does remove it is a bullet, a crusher's spike, a fall into a pit and a dispenser retiring its oldest.
- **Blocks stop bullets**: a bullet no longer flies through a block, so a block left in a cannon's line shields whatever is behind it (metal for good, ice and carbon fiber for one shot). Check any cannon lane that has a block in it.
- **A pushed block has no undo**: you can only push the way you walk, so a carbon fiber block pushed against a wall or into a corner stays there unless the player can get round to its other side (a catwalk, a ladder, a hang) or a dispenser makes another.
- **A light block pays only a light plate**: a lone 1×1 carbon fiber block (0.5) does nothing on a plate at threshold 2, and a zone sensor or button counts it regardless of weight, so two sensors beside each other can disagree about one block.
- **A steam lift is only as steady as its source**: a laser boil is steady while the beam rests on a boilable pool (and the pool must not drain dry, since a faucet below the drain rate cannot keep it up), a crust reaction makes steam only while the liquids are meeting, and a column that is cut drops the block about 0.3 s later. A block under a ceiling in a column stays pinned there for as long as the steam lasts, so a level that needs it to come down has to let the steam stop.
- **Steam tips only a plank that opts in, and only from below**: `steam_torque_scale` defaults to 0, so a see-saw in a boil column does nothing until it is set. A column under the pivot reads nothing, columns under both ends cancel, and the lever arm is the dial (a column near the tip pushes hardest). Aim a column a little inside the tip, and remember the plank shadows what is above it.
- **A pushed block coasts only on a slippery floor**: a frozen crust or an ice block under it turns a precise push into a slide, and the push also needs the player standing, not crouched.
- **A block dispenser refuses an occupied spawn area and retires its own oldest block**: see the dispenser's gotchas under Blocks. The two to remember are a spawn point where blocks never leave (every press after the first is refused) and a block the player is relying on that the dispenser takes back.
- **Stingbot has no pathing** and can get stuck behind walls. **Mines have no line of sight** and blast through thin walls.
- **Hanging**: conveyors, button pedestals, receivers and barriers are deliberately *not* ledge-grabbable; doors, blocks and see-saw ends are.
- **Order of nodes**: place receivers, buttons, doors and swings before the Player in the tree so the player draws in front of them.
- **Sounds**: every new element needs a sound hook and an entry in `Audio.PLANNED`.

Reads with: `puzzles.md` (the primitives and combinations built from these pieces), `player.md` (verbs), `player-surf.md` (surf numbers), `power.md` (sources, devices, wiring), `enemies.md`, `hazards-traps.md`, `platforms-conveyors.md`, `meltable-blocks.md`, `rotating-bodies.md`, `lasers-arcs-mirrors.md`, `liquid-system.md`, `saving-levels-ui.md` (collectibles, checkpoints, finish)
