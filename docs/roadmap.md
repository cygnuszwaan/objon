# Roadmap: planned mechanics

Planned additions that close gaps found while writing the level-design reference: puzzles that the current objects almost support. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

Covers: Phase 2 (Launch: See-saw launch); Phase 3 (Reach of existing systems: Steam for blocks and walkers; Freeze); Not on the roadmap

**This is the one file that describes planned work, not the project as it stands.** Everything in it is unbuilt or unconfirmed. An item has two lifecycle steps, set out under Finishing a roadmap item in How to maintain this file in `objon.md`: when it is built, the owning topic file describes it (with a `## Status` line) and the entry here gains a line `Built, awaiting in-editor confirmation; see Status in <topic file>.`; when the user has confirmed it in-editor, the entry is deleted here and the design reference and puzzle file are updated. Do not leave a confirmed item here as history.

**Ids.** Items are `N<phase>.<n>`. They do not continue the older numbering that source comments cite (`roadmap 1.1` to `8.5`, all built).

**Effort** is a rough guess from reading the docs, not the code: S (a day or less, one script plus a scene), M (a few days, touches one existing system), L (a week or more, changes a shared solver). Re-estimate against the code before starting.

**Every new object** follows the checklist in `objon.md` (Checklist: adding a new object type): placement, layers and groups, contracts, `PowerTarget` and `invert`, save and restore, `Audio.PLANNED` sound ids, export audit (`export-audit.md`), level-editor habits, then a bullet in the owning topic file. The items below only list what is specific to each.

## Ordering

Phases run from least to most invasive. Phase 2 adds a see-saw launch. Phase 3 extends liquid and steam. Within a phase the order is by value. There are no hard dependencies.

## Phase 2: Launch

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

Reads with: `player.md` (launch), `power.md` (sources, devices and the contract most items extend), `lasers-arcs-mirrors.md` (mirrors), `rotating-bodies.md` (see-saw), `meltable-blocks.md` (blocks, launch), `liquid-system.md` (steam, crust), `water-mechanic.md` (the crust data model), `saving-levels-ui.md` (the pause menu)
