# Roadmap: planned mechanics

Planned additions that close gaps found while writing the level-design reference: puzzles that the current objects almost support. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

Covers: Phase 3 (Reach of existing systems: Freeze ray); Not on the roadmap

**This is the one file that describes planned work, not the project as it stands.** Everything in it is unbuilt or unconfirmed. An item has two lifecycle steps, set out under Finishing a roadmap item in How to maintain this file in `objon.md`: when it is built, the owning topic file describes it (with a `## Status` line) and the entry here gains a line `Built, awaiting in-editor confirmation; see Status in <topic file>.`; when the user has confirmed it in-editor, the entry is deleted here and the design reference and puzzle file are updated. Do not leave a confirmed item here as history.

**Ids.** Items are `N<phase>.<n>`. They do not continue the older numbering that source comments cite (`roadmap 1.1` to `8.5`, all built).

**Effort** is a rough guess from reading the docs, not the code: S (a day or less, one script plus a scene), M (a few days, touches one existing system), L (a week or more, changes a shared solver). Re-estimate against the code before starting.

**Every new object** follows the checklist in `objon.md` (Checklist: adding a new object type): placement, layers and groups, contracts, `PowerTarget` and `invert`, save and restore, `Audio.PLANNED` sound ids, export audit (`export-audit.md`), level-editor habits, then a bullet in the owning topic file. The items below only list what is specific to each.

## Ordering

Phases run from least to most invasive. Phase 3 extends the liquid system and the beam family. (Phase 2, the see-saw launch, is built and confirmed.) Within a phase the order is by value. There are no hard dependencies.

## Phase 3: Reach of existing systems

### N3.2 Freeze ray (L)

Built, awaiting in-editor confirmation; see Status in liquid-system.md.

**Gap.** The melt cycle is one way (ice becomes water, water never becomes ice), and the beam family has a heat ray (the laser turret) and an electrical impulse (the arc turret) but no cold. A freeze turret completes the three: a continuous beam whose effect is **cumulative** (dwell) rather than instant like the laser or discrete like the arc. Steam stays a surfing-player-only query; nothing here changes that.

**Freeze turret.** A beam turret on the existing `LaserBeam.trace()` solver, so it reflects off mirrors, passes catwalks and glass, and is stopped by everything that stops a laser (a crust included). Same shape as the laser turret: `@tool` `Node2D` root, `Body` on layer 2 in `water_solid`, a `Muzzle`, `PowerTarget`, `invert`; powered = beam on; aim is its own rotation. It is **non-lethal**: it deals no damage to anyone. Dispatch each physics frame on whatever ends the beam: a body with `on_freeze_hit(point, direction)` is told it is lit (like `on_laser_hit()`); the player is given chill (below); an enemy is opaque and unaffected in v1. The turret keeps no per-target state. **The dwell lives on the target, not the turret**, so one turret serves targets with different dwell times.

**Dwell.** Each target keeps its own runtime `frost` value that rises while the beam is on it and decays when it is not. The target acts when `frost` reaches its dwell time.

**Targets.**
- **Basin.** A `freezable` export (default false, like `boilable`) and a `freeze_time` export (seconds of sustained beam). `WaterManager.freeze_along_beam(points, delta)` mirrors `boil_along_beam()`: it tests the beam against the liquid polygons of every freezable basin. At `freeze_time` the basin calls `freeze()`. Valid only for a crust-free basin with liquid in it, **water or slag**, and **electrified or not**: it forms a **frozen crust** (below) through the existing crust machinery (`crust_top_row`, `crust_bottom_row`, the fixed 0.75-tile thickness, the collision rebuild) with no opposite-liquid particle and **no steam**. The liquid under the crust stays, as with a reaction crust.
- **Freeze receiver.** A power source like the laser receiver (group `"power_source"`, `is_powered()`, `powered_changed(on)`, `on_freeze_hit()`), with a `dwell_time` export (0 = instant, as a laser receiver is). It is powered once `frost` reaches `dwell_time` and then holds as the laser receiver's `hold_time` does, so a beam swept off and back, or a Stingbot flying through it, does not flicker the circuit. Holding a beam steady on it while mirrors turn is the puzzle verb.
- The powered `Freezer` device is not built: the ray is the trigger.

**Frozen crust.** A new crust **kind**, not a reaction crust. It is recorded on the basin (a saved `crust_frozen` flag) and differs from a reaction crust in four ways: it has its own skin (the same frames as the solidifying art, a different colour, one skin for both liquids; reaction crusts keep their art); a **laser melts it**; it can be **electrified**; and it is otherwise the same: solid, walkable, hangable from beneath over a drained void, and read as `CRUST` by a basin sensor. A reaction crust is unchanged: it never thins, is not meltable and cannot be electrified.

**Melting.** The crust body forwards `on_laser_hit(point, direction)` to its basin, and a frozen crust keeps a runtime `heat` value that rises while a laser is on it and decays when not; at `melt_time` (export) the whole crust **thaws** (its cooling frames play backwards from the last frame and the crust is removed, staying solid until they finish; the laser leaving, or a freeze hit on it, in the meantime resumes cooling forward from the same frame) (always the whole crust, never a hole in the columns the beam touches): the crust and its collision body are removed and the basin is an ordinary crust-free basin again (no steam, no particles; frozen slag is molten slag again). A laser on a reaction crust is simply stopped, as today. The laser and the freeze ray are opposites: a boilable pool can be crusted by the ray and the laser then melts the crust before it boils anything. The basin needs a `thaw()` that reverses `convert_to_crust()` (new; today nothing removes a crust).

**Electrified frozen crust.** Today an arc or spark electrifies only a crust-free water basin. A frozen crust over water accepts it as well (frozen slag does not: slag is never electrified), for `electrified_time`. While electrified, the **top of the crust hurts the player standing on it**, and an electrified pool that is frozen keeps its remaining timer on the crust. The hurt is a polled hazard (`take_hit()` every physics frame while the player is in a thin strip along the top face, with the player's i-frames pacing it, as the crusher and sawwheel do), and it goes through `is_hazardous_now()`, the one question for a transient hazard, so a crust that is not electrified never hurts. Only the player reads it, as with electrified water. A submerged or embedded player is already hurt by the electrified liquid. Electrification is runtime-only, so a restore comes back harmless.

**Player chill.** One contract, `apply_chill(strength)` (0..1), called every physics frame by whichever source is touching the player: the freeze beam, and an embedded crust (below). The player keeps its own smoothed chill (instant rise to the largest strength received that frame, linear decay over `CHILL_DECAY_TIME`, 0.5 s, the same shape as surf wetness) and scales its walk and swim speed by `lerp(1, CHILL_MIN_SCALE, chill)`. **Surf and jump pad launches are exempt**: the scale is not applied while surfing or while a launch's velocity is in force (the smoothed value keeps tracking, so stepping off a board inside the beam is chilled at once). **Rules:** chill scales control and never removes it (`CHILL_MIN_SCALE` is above zero, so the player can always leave); overlapping sources take the **maximum**, never the sum; chill is non-lethal; it is runtime-only and not saved. The beam and the crust use the **same** scale for now, as one constant; retune swimming separately only after playtesting. Chill is not held state, so it does not go in `_interrupt_current_action()` unless it gains one.

**Freezing around the player.** Crust is solid, so a freeze must not seal anyone in. At the moment of freeze the basin latches the player as **embedded** if the player overlaps the crust band or is submerged in that basin's liquid. For an embedded player the crust is passable (`add_collision_exception_with()` on the crust body, the player only, so particles and the laser still see it as solid) and applies chill every frame the player overlaps it. It becomes solid for the player only when the player is clear of the band **and** out of the liquid (with a small margin, so a one-pixel overlap is not depenetrated oddly), which in practice means they have surfaced on top of it. The latch is set once, at the freeze: a player arriving later meets ordinary solid crust. An embedded player in frozen slag is chilled by the crust and still hurt by the slag liquid as today. A thaw clears the latch.

**Animation.** The freeze plays the frozen skin's frames as a reaction crust plays its cooling frames (`_crust_cool_t`, `CRUST_COOL_TIME`), but **the final frame is withheld while a player is embedded**: the cooling holds on the frame before it, and the last frame shows once the crust has gone solid for the player. With nobody embedded it plays through and is solid from the first frame, as a reaction crust is.

**What it gives.** A frozen pool is plain walkable ground (a surfer rides it at any speed, the opposite of a skim), reads as `CRUST` to a basin sensor, and over a drained void gives the crust underside hang. The laser and the ray together make a toggle: freeze to cross, melt to reopen, and the arc turns the crossing into a hazard.

**Save and restore.** The new saved field is `crust_frozen` (beside the existing crust fields), so a restored frozen crust is cold, solid, meltable and drawn in the frozen skin. `frost`, `heat`, the embedded latch, chill and electrification are runtime-only: a restore never produces a surprise hit or a half-built state, and a crust restored from before a freeze or a thaw is the crust it was then.

**Rules to keep.** Each target keeps its own `frost` and `heat`, and the manager and the turret keep no per-caller state (the same rule as the steam lift query). Authored values stay exports (`freeze_time`, `dwell_time`, `melt_time`); `frost`, `heat`, the embedded latch and chill are runtime variables (runtime code never writes an export). The new contracts (`on_freeze_hit(point, direction)`, `apply_chill(strength)`) go in the core's contracts table, the turret and receiver in the groups lists and the audit log, and the sound ids in `Audio.PLANNED` (for example `traps/freeze_hum`, `interactive/basin_freeze`, `interactive/basin_thaw`, `interactive/freeze_receiver_on`).

**Deferred, not in this item.** Chill for enemies (a shared speed scale across six enemy scripts); what a block floating in the surface band does when the crust forms.

**Open, decide before or during the build.**
- Whether `add_collision_exception_with()` on a static crust body is honoured by the player's `move_and_slide()` (testable headless).
- How an arc or spark reaches a frozen crust: the arc samples a point against `find_basin_at_point()`, which has to find a basin by its crust surface.
- If an air limit is ever added to swimming, revisit chill and swim speed together.
- The dwell constants, `melt_time` and `CHILL_MIN_SCALE`, by feel in the editor.

**Touches.** `lasers-arcs-mirrors.md` (Freeze turret; the Laser beam solver's callers; an arc electrifying frozen crust), `power.md` (Freeze receiver; Basin sensor), `liquid-system.md` (crust; freezing; thawing; electrified water), `water-mechanic.md` (the crust data model and its cooling animation; read it before changing anything), `player.md` (chill; Swim; Catwalk underside hang: crust), `player-surf.md` (surf and launches exempt from chill), `hazards-traps.md` (the electrified-crust strip as a polled hazard), `level-design.md` (the Crust and Electrified water rows, which say crust never thins and only crust-free water is electrified), `saving-levels-ui.md` (`crust_frozen`), `objon.md` (contracts, groups).

## Not on the roadmap

The beam stays one polyline of one colour: `LaserBeam.trace()` returns a single result, so there is no splitter, prism or coloured beam. Two other gaps look intentional and are left alone: the player cannot push blocks by walking (the shove guard in `meltable-blocks.md` is deliberate; a kick, the surf and an underside push move them), and doors never crush (`power.md`, Door).

Known weak spots in existing behaviour, listed here so nobody mistakes them for planned features: the Stingbot has no obstacle avoidance and can stick on a wall, and the proximity mine's blast has no line-of-sight test (both in `enemies.md`).

Reads with: `player.md` (launch), `power.md` (sources, devices and the contract most items extend), `lasers-arcs-mirrors.md` (mirrors), `rotating-bodies.md` (see-saw), `meltable-blocks.md` (blocks, launch), `liquid-system.md` (crust), `water-mechanic.md` (the crust data model), `saving-levels-ui.md` (the pause menu)
