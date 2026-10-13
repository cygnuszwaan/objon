# Roadmap: planned mechanics

Planned additions that close gaps found while writing the level-design reference: puzzles that the current objects almost support. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

Covers: Phase 3 (Reach of existing systems: Carbon fiber block; Steam lifts blocks; Steam tips the see-saw); Not on the roadmap

**This is the one file that describes planned work, not the project as it stands.** Everything in it is unbuilt or unconfirmed. An item has two lifecycle steps, set out under Finishing a roadmap item in How to maintain this file in `objon.md`: when it is built, the owning topic file describes it (with a `## Status` line) and the entry here gains a line `Built, awaiting in-editor confirmation; see Status in <topic file>.`; when the user has confirmed it in-editor, the entry is deleted here and the design reference and puzzle file are updated. Do not leave a confirmed item here as history.

**Ids.** Items are `N<phase>.<n>`. They do not continue the older numbering that source comments cite (`roadmap 1.1` to `8.5`, all built).

**Effort** is a rough guess from reading the docs, not the code: S (a day or less, one script plus a scene), M (a few days, touches one existing system), L (a week or more, changes a shared solver). Re-estimate against the code before starting.

**Every new object** follows the checklist in `objon.md` (Checklist: adding a new object type): placement, layers and groups, contracts, `PowerTarget` and `invert`, save and restore, `Audio.PLANNED` sound ids, export audit (`export-audit.md`), level-editor habits, then a bullet in the owning topic file. The items below only list what is specific to each.

## Ordering

Phases run from least to most invasive. Phase 3 extends the block family and steam. Within a phase the order is by value; N3.4 and N3.5 lean on N3.3 for tuning (carbon fiber is the block steam is meant to lift) but need nothing from it in code.

## Phase 3: Reach of existing systems

### N3.3 Carbon fiber block (M)

**Gap.** Blocks are two extremes: ice (light, short-lived, melts) and metal (heavy, melts slowly). There is no light block that lasts, no block the player can move without a kick, and the rules that separate blocks (what a bullet or a crusher does to them) are ad hoc. A third `MeltableBlock` subclass, `CarbonFiberBlock`, plus a small set of **material flags** on the base class, makes each block a row in one table.

**The block.** Extends `MeltableBlock`, own scene, placed and sized like the others (layers 1|2, `water_solid`, kickable, hangable, saveable, dispenser-compatible through `block_scene`). **It never melts**: `on_laser_hit()` only stops the beam (no melt progress, no `melt_time`), and slag does not heat it. It is **light**: mass about 0.5 per tile (ice 1, metal 4), so a jump pad or catapult throws it far (`launch_weight_exponent`), a lone 1×1 cannot press a weight plate whose threshold is 2 (stacked blocks or a rider still can), and a see-saw reads it as a small load. A permanent laser shield and a permanent slag raft are intended: a level that wants A3's disposable shield or B4's timed raft simply offers no carbon fiber block.

**Liquids.** Buoyant in water like ice but higher (`float_depth_fraction` about 0.6, tune by feel). On slag it **floats and does not melt** (`float_depth_fraction` as metal's, `_touching_slag()` never starts a melt), so it is a permanent raft. It jams nothing: `jams_crusher()` is false.

**Material flags on `MeltableBlock`** (exports, so a scene sets them and no subclass overrides code for them):
- `brittle` (ice true, carbon fiber true, metal false): a bullet breaks it and a crusher's spike shatters it. Ice goes through its existing melt path (a water burst); carbon fiber goes through `dissolve()` (fade, no liquid, no steam), so the crusher's `shatter()` hook (`_shatters_when_crushed()`) and the new bullet hook both read the flag instead of an ice-only override.
- `absorbs_bullets` (metal true): the bullet is consumed on contact with a ping and the block is unharmed, so a metal block is a bullet shield, the counterpart of A3's laser shield.
- Both through the existing duck-typed `on_bullet_hit(point, direction) -> bool` that `bullet.gd` already tests for (true = the bullet is consumed): `MeltableBlock` gains it, so `bullet.gd` and the contracts table need no new method. **Today a bullet ignores blocks entirely**, so "metal blocks bullets" is a new rule for existing metal blocks too; check the hit order against `Mirror` (`bullet_rotates`), which implements the same hook.
- Optional, same pass: a freeze beam on a melting ice block resets its melt progress at once (freeze cools, laser heats); carbon fiber and metal ignore the freeze beam. Needs `on_freeze_hit()` on `MeltableBlock`, which `FreezeTurret` already dispatches on.

**Walking pushes it.** The guard that discards actor pushes is the export `reject_actor_shove` (default true); carbon fiber sets it false, so the physics solver's own contact push stands. Do not rely on that alone: add a duck-typed `walk_shoved(direction: float, walk_speed: float) -> float` on `MeltableBlock` (like `surf_shoved`), called by the player while it is on the floor and moving into a block's side, returning the speed the block took or -1 to refuse (a wall or body on the far side, `shunt_speed` 0). Ice and metal return -1, so **the guard stays for them** and the rule "the player cannot push blocks by walking" stays true except for carbon fiber. The push speed is below walk speed (a cap export on the block, about half) so it reads as effort; the player is slowed to match while pushing and pushing is not a held state, so `_interrupt_current_action()` needs nothing. Open: the block against a wall or a second block (the player must not be squeezed or the block tunnel), a rider on top, pushing off a ledge, sneak and crouch (probably no push), and pushing a block onto a platform or belt.

**Rules to keep.** Authored values are exports; melt-free means no `melt_progress` to save, but `save_state()`/`load_state()` keep position and velocity as the base does. Joins `water_solid` and the other block groups in its own `_ready()`; a subclass calls `super()` in `_ready()` and `_physics_process()`. Sounds (`interactive/carbon_shunt`, `interactive/carbon_break`, `interactive/metal_ping` for an absorbed bullet) in `Audio.PLANNED`. Placeholder art drawn in code (a black woven tile) until sprites exist. Script in `export-audit.md`.

**Open, decide during the build.**
- Carbon fiber's mass and `float_depth_fraction`, the push cap and the lift numbers of N3.4, by feel.

**Touches.** `meltable-blocks.md` (Meltable block, a new Carbon fiber block bullet, the Block dispenser's `block_scene` note), `hazards-traps.md` (Cannon / Bullet; Sawwheel / Crusher: shatter and jam), `player.md` (Movement: the walk push), `level-design.md` (Blocks table, the Interaction matrix rows for Bullet and Crusher, and the gap line "the player can't push anything by walking"), `puzzles.md` (A3, B4, C-concepts that name block weights), `saving-levels-ui.md` (What each type saves), `objon.md` (contracts: `walk_shoved`, and the layers line if the block's layers differ), `export-audit.md`.

### N3.4 Steam lifts blocks (S to M)

**Gap.** Only a surfing player reads steam, so a column is useless to a block. The old sketch holds: `WaterManager.get_steam_lift(rect, previous, delta)` is already stateless and takes a rect.

**Sketch.** `MeltableBlock` gains `steam_lift_accel` (default 0 = off, so ice and metal are unchanged until a level opts in; `carbon_fiber_block.tscn` sets it) and `steam_lift_mass_exponent` (k). Each physics frame a block with a non-zero value reads `get_steam_lift()` over a rect **hugging its underside** (about 4 px deep, its rotated footprint's width), not over its bounds: a steam particle dies on the first solid it meets (a block in `water_solid` included), so the column ends at the block's underside and a bounds query would read nothing above it. It adds an upward acceleration of `steam_lift_accel × lift / mass^k` into `velocity` inside `_apply_forces()` (the block's own force hook, so buoyancy and liquid drag still apply), with the block keeping its own smoothed reading (`previous`, `delta`) like the surfer. Lift reads 0..1 of how much of the underside steam covers, so thin steam hovers the block and a full column carries it up to the column top (about 8 tiles) or a ceiling. Tune `steam_lift_accel` so a full column beats gravity (900) for carbon fiber at mass 0.5 per tile by a margin, and does not for a 1×1 ice block even if opted in; the exponent sets how much a bigger block loses. Steam does not move enemies or walkers (a Player export for walkers stays out of scope: it changes what steam is for and should be a per-theme decision).

**Rules to keep.** The manager keeps no per-caller state (the same rule as the steam lift query); the block's smoothed lift is a runtime variable, not saved, and a restore restarts it at 0. The lift is acceleration, never a teleport, so a restore never throws a block. A block lifted into a ceiling or onto a see-saw plank behaves as any block there does. Steam is not saved, so after a restore a column rebuilds over about one lifetime and a block that was riding it falls until it does.

**Touches.** `meltable-blocks.md`, `liquid-system.md` (Steam lift query: a second caller), `player-surf.md` (Steam lift: now one of two readers), `level-design.md` (Liquids: Steam, Gaps: "Steam is a surf-only mechanic"), `puzzles.md`.

### N3.5 Steam tips the see-saw (S to M)

**Gap.** Steam moves a surfer but nothing that turns. A weak upward torque on a plank, significant only in abundance, makes a boiled pool or a crust reaction a drive for the see-saw.

**Sketch.** The see-saw's load path already exists: `WaterManager._accumulate_resting_torque()` adds weight × offset from the pivot for every liquid particle resting on a body that has `get_pivot_global()`, summed into `_resting_torque` (cleared every physics frame) and read by `RotatingBody` through `get_resting_torque(body)` × `liquid_weight_scale`. Steam never rests: it dies on the first solid it meets. So when a steam particle dies on a body with a pivot, whose surface faces it (the hit normal opposes the particle's velocity, so only the underside of the plank counts), the manager adds an **upward** torque for it: `STEAM_TORQUE_PER_PARTICLE × (particle x − pivot x)`, with the sign of an upward push at that lever arm. A new constant, small by design: one puff does almost nothing and a dense column tips a plank. Because particles arrive one at a time and `_resting_torque` is cleared each frame, the steam term is **smoothed per body** (instant rise to what arrived this frame, linear decay over about 0.3 s, the shape of the lift query's decay), kept in a separate dictionary so liquid load and steam push do not share a clock. `RotatingBody` gains `steam_torque_scale` (default **0**, opt-in, like `enemy_weight_scale`, so no existing level changes), read beside `liquid_weight_scale`. An end that steam pushes up behaves like an end that gets lighter, so the angle sensor, the launch and a block's rider all read it with no further change.

**What it gives.** Laser-boiling a pool (`boilable`) or pouring water on slag under a plank makes steam under it, which tips the plank and trips an angle sensor: a scale driven by heat. Steam and liquid together: water poured on one end loads it down while steam under the other lifts it.

**Rules to keep.** Runtime only and never saved; a restore comes back level and the column rebuilds. The manager keeps no per-caller state beyond the per-body smoothing, which is cleared by `forget_motion(body)` for a teleported body. Steam still dies on the plank, so a plank also shadows what is above it.

**Open.** The torque constant and decay by feel; whether a plank with `mirror_surface` set should be excluded (probably not); whether steam passing a catwalk-tile plank counts (no: catwalks are stepped past).

**Touches.** `liquid-system.md` (Steam; Carry and load), `water-mechanic.md` (read before touching the steam particle's death path), `rotating-bodies.md` (Rotating bodies and the see-saw: the torque sum), `level-design.md` (See-saw, Liquids: Steam, Gaps), `puzzles.md` (B6, C-concepts).

## Not on the roadmap

The beam stays one polyline of one colour: `LaserBeam.trace()` returns a single result, so there is no splitter, prism or coloured beam. Two other gaps look intentional and are left alone: the player cannot push blocks by walking (the shove guard in `meltable-blocks.md` is deliberate; a kick, the surf and an underside push move them; carbon fiber, N3.3, is the one planned exception), and doors never crush (`power.md`, Door).

Known weak spots in existing behaviour, listed here so nobody mistakes them for planned features: the Stingbot has no obstacle avoidance and can stick on a wall, and the proximity mine's blast has no line-of-sight test (both in `enemies.md`).

Reads with: `player.md` (launch), `power.md` (sources, devices and the contract most items extend), `lasers-arcs-mirrors.md` (mirrors), `rotating-bodies.md` (see-saw), `meltable-blocks.md` (blocks, launch), `liquid-system.md` (crust), `water-mechanic.md` (the crust data model), `saving-levels-ui.md` (the pause menu)
