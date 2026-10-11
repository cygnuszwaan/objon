# Roadmap: planned mechanics

Planned additions that close gaps found while writing the level-design reference: puzzles that the current objects almost support. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

Covers: Phase 1 (Quick wins: Camera cue; Powered spikes; Zone sensor; Mirror reverse mode; Enemy weight on plates); Phase 2 (Logic and spawning: Logic nodes; Block dispenser; See-saw launch); Phase 3 (Reach of existing systems: Steam for blocks and walkers; Freeze); Not on the roadmap

**This is the one file that describes planned work, not the project as it stands.** Everything in it is unbuilt or unconfirmed. An item has two lifecycle steps, set out under Finishing a roadmap item in How to maintain this file in `objon.md`: when it is built, the owning topic file describes it (with a `## Status` line) and the entry here gains a line `Built, awaiting in-editor confirmation; see Status in <topic file>.`; when the user has confirmed it in-editor, the entry is deleted here and the design reference and puzzle file are updated. Do not leave a confirmed item here as history.

**Ids.** Items are `N<phase>.<n>`. They do not continue the older numbering that source comments cite (`roadmap 1.1` to `8.5`, all built).

**Effort** is a rough guess from reading the docs, not the code: S (a day or less, one script plus a scene), M (a few days, touches one existing system), L (a week or more, changes a shared solver). Re-estimate against the code before starting.

**Every new object** follows the checklist in `objon.md` (Checklist: adding a new object type): placement, layers and groups, contracts, `PowerTarget` and `invert`, save and restore, `Audio.PLANNED` sound ids, export audit (`export-audit.md`), level-editor habits, then a bullet in the owning topic file. The items below only list what is specific to each.

## Ordering

Phases run from least to most invasive. Phase 1 adds nothing to a shared solver: new sources, one new hazard layer, two small exports, and a camera term in the player's existing camera easing, so each item can ship alone. The camera cue is first because it helps every level built after it. Phase 2 adds logic and resources and is where the save/restore rules bite. Phase 3 extends liquid and steam. Within a phase the order is by value. There are no hard dependencies; the camera cue's `delay` lines up neatly with the Delay logic node (N2.1) but does not need it.

## Phase 1: Quick wins

### N1.1 Camera cue (M)

Built, awaiting in-editor confirmation; see Status in power.md.

**Gap.** When a trigger works somewhere off-screen (a button opens a door two screens away, a receiver lights up behind a wall), the player gets no feedback. A cue pans the camera to the affected spot, holds, and returns to the player, so the effect of a trigger is shown for a moment. It is also a level-design tool in its own right: it lets a puzzle be readable without a hint sign.

**Sketch.** A `CameraCue`: a `Node2D` placed at the point to look at, with a `PowerTarget` child and an `invert` export, so any source or conductor circuit can drive it. A **rising edge** plays the cue. The startup state is not an edge (it goes through `set_powered_initial()`, which does nothing), so a level that loads with the source already on does not cue, which is also what a checkpoint restore needs. Exports: `pan_time` (default 0.6 s), `hold_time` (1.5 s), `return_time` (0.6 s), `delay` (seconds from the edge to the start of the pan, so a door's opening can be lined up with the camera arriving; a Delay logic node from N2.1 does the same thing on the wiring side), `once` (play only the first time), `cooldown` (ignore edges for this long after a cue ends), and an ease choice. A public `play()` lets a script or another device call it. The cue node's `global_position` is read every frame, so a cue parented to a moving platform tracks it.

**Camera side.** The camera is a child of the player and its `offset` is already driven every idle frame by `_update_camera_lead()` (lead from horizontal speed, look-down from falling). The cue adds a second term: `offset = lead_and_fall × (1 − weight) + (cue_point − player.global_position) × weight`, with `weight` tweened 0 to 1 to 0 in idle time (`TWEEN_PROCESS_IDLE`; the offset is not physics-interpolated). Because the cue term is relative to the player, the camera centres on the cue point whether the player stands still or walks. There is no camera limit or smoothing node to fight, so any distance works. The cue is a public method on the player, `show_cue(world_point_or_node, params)`, found through group `"player"` lazily (the player joins it in its own `_ready()`).

**Rules to keep.**
- **A new tween on the player is added to `_interrupt_current_action()`** (`objon.md`, Cross-system invariants). A hit should end the cue early and ease back, so the player can see what hurt them; a dead or dancing player eases both terms to zero, as the lead and look-down do. A hard teleport (`respawn_at()`) resets camera interpolation as before and cancels any cue.
- **The cue is runtime only and not saved.** It never produces state a restore must rebuild. `once` needs a saved `fired` flag (the cue is then a saveable, with a silent `load_state()`), or a restore from a checkpoint after the cue would replay it on the next edge.
- **Pause** freezes the tween with everything else; nothing extra is needed. A new `create_timer()` for `delay` must pass `process_always = false` (see Pause menu).
- A second cue while one is playing retargets from the current offset and restarts the hold; do not queue them.
- Authoring: the editor shows the 512×288 view rectangle centred on the cue point, gated on a flag rather than `Engine.is_editor_hint()` (Level editor seams: authoring overlays). The configuration warning (no `PowerTarget` sources) is a plain method. Sound hook: one optional id for the pan (put it in `Audio.PLANNED`, not ending in a digit).

**Locking the player (decided: not in v1).** The world keeps running during a cue (the door has to open on screen), so the player can be hit while the camera is elsewhere, and a surfer keeps going. The first version should not lock input: it ends the cue on a hit, and the level designer keeps holds short and triggers cues from calm moments (a button press, not a speed trap). A lock is the obvious follow-up but is not cheap: the player reads `Input` directly in about two dozen places (`player.gd`), so a lock needs a small input wrapper first (a `get_input_axis()`, `is_pressed()` and `just_pressed()` the player calls instead), and then a rule for what a lock does to a surf, a swing or a hang. Decide that with the first levels in hand.

**Touches.** `player.md` (Camera, `_interrupt_current_action()`, Hard teleports), `power.md` (Power contract: the rising-edge and startup rules; add it to Powered devices), `saving-levels-ui.md` (Pause menu; Checkpoint and save/restore if `once` is saved).

### N1.2 Powered spikes (S to M)

**Gap.** Spike tiles carry no `PowerTarget`, so a retractable spike trap is impossible. This is the most standard trap the game cannot make.

**Sketch.** A `PoweredSpikeLayer`: a `TileMapLayer` on the ground tileset in a new group `"hazard_layer"`, no collision, with a `PowerTarget` child and an `invert` export. Powered means the spikes are out and dangerous; unpowered means the layer is hidden and skipped. The player's tile-hazard poll runs over every layer in the group as well as the world tilemap, through the same `TileHazards.hit_in_rect()` and `danger_zone()`, so the hit rule, knockback and sound are unchanged. Power switches the whole layer, so independent groups are separate layers; per-spike control would need a node and is out of scope. Optionally a short harmless rising phase before the layer turns dangerous, as a telegraph, with `warn_time` an export.

**Rules to keep.** Spikes stay on a layer with no collision and no `surface_type`, so they are never ground-like. Putting them on their own layer also avoids the `_ascending_landing_y()` pitfall (it treats any painted world-tilemap cell as floor). Add the group to Groups in use in `objon.md`. The layer keeps no state: it derives from power through `set_powered_initial()`, so it has no `save_state()`. Move the `PowerTarget` to the cell a conductor wire should end at.

**Touches.** `hazards-traps.md` (Spikes), `power.md` (Powered devices), `player.md` (the poll sits next to Health / Hurt / Dead).

### N1.3 Zone sensor (S)

**Gap.** There is no "something is in this area" power source. It would give a door that shuts behind the player, an ambush trigger, and a lure puzzle where an enemy stands in the zone.

**Sketch.** A power source in the same contract as `Button` (group `"power_source"`, `is_powered()`, `powered_changed(on)`): an `Area2D` on layer 0, mask 1, polled every physics frame (never `body_entered`). Exports: `count_player`, `count_enemies`, `count_blocks`, `min_count` (default 1), `hold_time` (the shared analogue-source rule, so a body crossing the edge cannot chatter it). Enemies are group `"enemy"`, blocks are `MeltableBlock`; a dead or dancing player never counts. Not physical, so it is wired like any source. Saves `powered` and `time_left` per the shared rule, and keeps power for a few physics frames after a restore even if the sensor reads empty, as `Button` and the weight plate do (a restored body only overlaps once the physics server has stepped).

**Touches.** `power.md` (Button and Weight plate are the patterns; add it to the sources), `enemies.md` (which bodies count).

### N1.4 Mirror reverse mode (S)

**Gap.** A mirror only turns on rising edges, so a powered mirror cannot swing between two aims.

**Sketch.** An export on `Mirror` (for example `falling_turns_back`, default false) that turns one step the other way on a falling edge. The startup state is still not an edge.

**Pitfall to resolve first.** A momentary button cycled by crouching produces a falling and a rising edge in one physics frame, and an edge that arrives during a turn is dropped. In reverse mode that would net one step back instead of one forward. Queue at most one pending edge during a turn in this mode, or ignore a falling edge that is paired with a rising edge in the same frame. Kicks during a turn stay dropped.

**Touches.** `lasers-arcs-mirrors.md` (Mirror), `power.md` (Powered devices, Button).

### N1.5 Enemy weight on plates (S)

**Gap.** Enemies weigh nothing, so a grunt cannot hold a plate down.

**Sketch.** An `enemy_weight` export on the weight plate (default 0, so every existing level is unchanged) that adds that weight for each group-`"enemy"` body overlapping the strip. Leave the see-saw alone at first: it would need the same rule in its load scan, and its default must stay 0. If both are wanted later, a duck-typed `get_load_weight() -> float` read by both is the cleaner contract.

**Touches.** `power.md` (Weight plate), `rotating-bodies.md` (Loads) if extended.

## Phase 2: Logic and spawning

### N2.1 Logic nodes (M)

**Gap.** Logic is only OR, AND (`all_required`) and `invert` on a `PowerTarget`. There is no delay, memory, counter or one-shot, so a combination lock has to be faked with a mirror.

**Sketch.** Four small source nodes, each in the `Button` contract with a `sources: Array[Node]` and `add_source()`: **Delay** (on-delay and off-delay), **Latch** (set and reset sources), **Counter** (on after N rising edges of its sources, optional reset source and auto-reset), **Pulse** (a rising edge powers it for `duration`, restarting while on, with no new edge). Inputs are evaluated the way `PowerTarget` evaluates its own, including the deferred first recompute so nothing is driven before every `_ready()` has run.

**Design choice to make first.** Whether a logic node is also a `PowerTarget` (it already has an `_apply_power(on)` hook meant for subclasses) so a conductor wire can end at it and start from it. A node in both `"power_target"` and `"power_source"` makes circuits chainable, but then a loop of such nodes is possible; give it a cycle guard.

**Rules to keep.** Saveable: delay timers, latch state and count are saved; `load_state()` snaps silently and emits `powered_changed` only on a change, and tolerates `set_powered_initial()` running afterwards. Derive-from-level steps are named methods. Configuration warnings are plain methods (an empty `sources`, a counter threshold of 0).

**Touches.** `power.md` (Power contract, Conductors), `saving-levels-ui.md` (What each type saves).

### N2.2 Block dispenser (M to L)

**Gap.** Nothing creates a block, so ice and metal are one-use. A dispenser makes them a renewable resource (a replaceable shield, a second weight).

**Sketch.** A powered device: a rising edge spawns a block (ice or metal scene, `size_tiles`) at a marker, if the spawn area is free (an `intersect_shape` check, as the door does before closing). Exports: `block_scene`, `size_tiles`, `max_alive`, `cooldown`. When `max_alive` is exceeded the oldest block is removed through its own melt or shatter path, not a bare `queue_free()`.

**The crux is checkpoints.** `Game.apply()` frees every saveable with no snapshot entry, and snapshot keys are node paths relative to the level root, so a block added at runtime would be freed on the next respawn, and a name from a bare `add_child()` is not stable. Plan: the dispenser owns its spawned blocks. It gives each an explicit unique name, a spawned block does not join `"saveable"` itself (a `MeltableBlock` hook is needed to skip that in `_ready()`), and the dispenser's own `save_state()` carries each live block's state and re-creates them in `load_state()`. That keeps the restore independent of order and keeps a restore from producing a surprise hit. This is the same rule a runtime level editor needs (Level editor seams: a placed object's identity is its node name).

**Touches.** `meltable-blocks.md` (Meltable block), `saving-levels-ui.md` (Saveable contract, What each type saves), `power.md` (Powered devices), `objon.md` (Level editor seams).

### N2.3 See-saw launch (M)

**Gap.** A see-saw tips and carries riders but never throws them, so a heavy block dropped on one end cannot fling the player off the other.

**Sketch.** An opt-in `launch_gain` export on the see-saw (0 = off, so existing planks are unchanged). When the plank hits its stop at an angular speed above `launch_min_speed` (the stop sound already measures that speed), it calls `launch(vector)` on the loads resting on the raised end, along the plank's face normal, scaled by the end's speed and `launch_gain` and capped. The load that caused the tip is excluded. `get_loads()` already supplies each body, offset and weight. The existing `launch()` contract does the rest: the player buffers it and drops held states, and a block divides it by `mass ^ launch_weight_exponent` with its vertical speed capped.

**Pitfalls.** Release an idle rider's grip anchor before launching, or the grip pulls it back onto the face. A load that is latched for `LOAD_LATCH_FRAMES` must not launch twice. Tune by playtest; headless runs cannot judge the feel.

**Touches.** `rotating-bodies.md` (Rotating bodies and the see-saw: Loads, Audio), `platforms-conveyors.md` (Jump pad, for the shared contract), `player.md` (Jump pads), `meltable-blocks.md` (Jump pad launch).

## Phase 3: Reach of existing systems

### N3.1 Steam for blocks and walkers (S to M)

**Gap.** Only a surfing player reads steam, so a steam column is useless to everything else.

**Sketch.** `WaterManager.get_steam_lift(rect, previous, delta)` is already stateless and takes a rect. First consumer: `MeltableBlock` reads it over its bounds each physics frame and accelerates upward by `steam_lift_accel / mass ^ k` (an export, 0 = off), so ice rises in a column and metal does not. Second, optional: a Player export (default off) that lets a walking or falling player feel it, which changes what steam is for and should be decided per level theme, not by default. Steam does not move enemies.

**Rules to keep.** Each caller keeps its own smoothed value; the manager keeps no per-caller state. Update the sentences that say the surfing player is the only caller.

**Touches.** `liquid-system.md` (Liquid system: steam lift query), `player-surf.md` (Water: Steam lift), `meltable-blocks.md`, `player.md` if walkers are included.

### N3.2 Freeze (M)

**Gap.** The melt cycle is one way: ice becomes water, water never becomes ice again except through the block's own `melt_progress`.

**Sketch.** `WaterBasin.freeze()`, valid only for a crust-free water basin with liquid in it: it forms a crust of the water type through the existing crust machinery (`crust_top_row`, `crust_bottom_row`, the fixed 0.75-tile thickness, the collision rebuild), with no opposite-liquid particle and **no steam**. A `Freezer` device (powered rising edge freezes the basin named by a `basin` NodePath, as the basin sensor names its basin) is the trigger. The water crust skin already exists, so the art is mostly done. Slag stays out of scope.

**What it gives.** A frozen pool is plain walkable ground (a surfer rides it at any speed, which is the opposite of a skim), reads as `CRUST` to a basin sensor, and over a drained void gives the crust underside hang.

**Constraint.** Crust never thins, so a freeze is permanent until reload or a restore from before it. A thaw would break that rule and the CRUST sensor mode's meaning; make it a separate decision, not part of this item. Crust fields are already saved, so a restore needs nothing new.

**Touches.** `liquid-system.md` (Liquid system: crust), `water-mechanic.md` (the crust data model and rendering; read it before changing anything), `power.md` (Basin sensor, Powered devices), `player.md` (Catwalk underside hang: crust).

## Not on the roadmap

The beam stays one polyline of one colour: `LaserBeam.trace()` returns a single result, so there is no splitter, prism or coloured beam. Two other gaps look intentional and are left alone: the player cannot push blocks by walking (the shove guard in `meltable-blocks.md` is deliberate; a kick, the surf and an underside push move them), and doors never crush (`power.md`, Door).

Known weak spots in existing behaviour, listed here so nobody mistakes them for planned features: the Stingbot has no obstacle avoidance and can stick on a wall, and the proximity mine's blast has no line-of-sight test (both in `enemies.md`).

Reads with: `player.md` (camera, hazard poll, launch, `_interrupt_current_action()`), `power.md` (sources, devices and the contract most items extend), `hazards-traps.md` (spikes), `lasers-arcs-mirrors.md` (mirrors), `rotating-bodies.md` (see-saw), `meltable-blocks.md` (blocks, launch), `liquid-system.md` (steam, crust), `water-mechanic.md` (the crust data model), `saving-levels-ui.md` (the saveable contract that N2.1 and N2.2 must satisfy, the pause menu)
