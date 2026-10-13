# Roadmap: planned mechanics

Planned additions that close gaps found while writing the level-design reference: puzzles that the current objects almost support. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

**Always attach the patch.** The user has no access to the session's sandbox. Every session that changes the repository ends by attaching its result as a patch (`git diff` against the starting commit, saved as `<item id>.patch`, for example `n3.4.patch`) to its final reply, not just describing the changes. Test scaffolding and files Godot regenerates (`.import`, `.godot/`) are left out of the patch.

Covers: Phase 3 (Reach of existing systems: Steam tips the see-saw); Not on the roadmap

**This is the one file that describes planned work, not the project as it stands.** Everything in it is unbuilt or unconfirmed. An item has two lifecycle steps, set out under Finishing a roadmap item in How to maintain this file in `objon.md`: when it is built, the owning topic file describes it (with a `## Status` line) and the entry here gains a line `Built, awaiting in-editor confirmation; see Status in <topic file>.`; when the user has confirmed it in-editor, the entry is deleted here and the design reference and puzzle file are updated. Do not leave a confirmed item here as history.

**Ids.** Items are `N<phase>.<n>`. They do not continue the older numbering that source comments cite (`roadmap 1.1` to `8.5`, all built).

**Effort** is a rough guess from reading the docs, not the code: S (a day or less, one script plus a scene), M (a few days, touches one existing system), L (a week or more, changes a shared solver). Re-estimate against the code before starting.

**Every new object** follows the checklist in `objon.md` (Checklist: adding a new object type): placement, layers and groups, contracts, `PowerTarget` and `invert`, save and restore, `Audio.PLANNED` sound ids, export audit (`export-audit.md`), level-editor habits, then a bullet in the owning topic file. The items below only list what is specific to each.

## Ordering

Phases run from least to most invasive. Phase 3 extends steam to the see-saw. Within a phase the order is by value.

## Phase 3: Reach of existing systems

### N3.5 Steam tips the see-saw (S to M)

**Gap.** Steam moves a surfer but nothing that turns. A weak upward torque on a plank, significant only in abundance, makes a boiled pool or a crust reaction a drive for the see-saw.

**Sketch.** The see-saw's load path already exists: `WaterManager._accumulate_resting_torque()` adds weight × offset from the pivot for every liquid particle resting on a body that has `get_pivot_global()`, summed into `_resting_torque` (cleared every physics frame) and read by `RotatingBody` through `get_resting_torque(body)` × `liquid_weight_scale`. Steam never rests: it dies on the first solid it meets. So when a steam particle dies on a body with a pivot, whose surface faces it (the hit normal opposes the particle's velocity, so only the underside of the plank counts), the manager adds an **upward** torque for it: `STEAM_TORQUE_PER_PARTICLE × (particle x − pivot x)`, with the sign of an upward push at that lever arm. A new constant, small by design: one puff does almost nothing and a dense column tips a plank. Because particles arrive one at a time and `_resting_torque` is cleared each frame, the steam term is **smoothed per body** (instant rise to what arrived this frame, linear decay over about 0.3 s, the shape of the lift query's decay), kept in a separate dictionary so liquid load and steam push do not share a clock. `RotatingBody` gains `steam_torque_scale` (default **0**, opt-in, like `enemy_weight_scale`, so no existing level changes), read beside `liquid_weight_scale`. An end that steam pushes up behaves like an end that gets lighter, so the angle sensor, the launch and a block's rider all read it with no further change.

**What it gives.** Laser-boiling a pool (`boilable`) or pouring water on slag under a plank makes steam under it, which tips the plank and trips an angle sensor: a scale driven by heat. Steam and liquid together: water poured on one end loads it down while steam under the other lifts it.

**Rules to keep.** Runtime only and never saved; a restore comes back level and the column rebuilds. The manager keeps no per-caller state beyond the per-body smoothing, which is cleared by `forget_motion(body)` for a teleported body. Steam still dies on the plank, so a plank also shadows what is above it.

**Open.** The torque constant and decay by feel; whether a plank with `mirror_surface` set should be excluded (probably not); whether steam passing a catwalk-tile plank counts (no: catwalks are stepped past).

**Touches.** `liquid-system.md` (Steam; Carry and load), `water-mechanic.md` (read before touching the steam particle's death path), `rotating-bodies.md` (Rotating bodies and the see-saw: the torque sum), `level-design.md` (See-saw, Liquids: Steam, Gaps), `puzzles.md` (B6, C-concepts).

## Not on the roadmap

The beam stays one polyline of one colour: `LaserBeam.trace()` returns a single result, so there is no splitter, prism or coloured beam. Two other gaps look intentional and are left alone: the player cannot push ice or metal blocks by walking (the shove guard in `meltable-blocks.md` is deliberate; a kick, the surf and an underside push move them; carbon fiber is the one block a walk moves), and doors never crush (`power.md`, Door).

Known weak spots in existing behaviour, listed here so nobody mistakes them for planned features: the Stingbot has no obstacle avoidance and can stick on a wall, and the proximity mine's blast has no line-of-sight test (both in `enemies.md`).

Reads with: `player.md` (launch), `power.md` (sources, devices and the contract most items extend), `lasers-arcs-mirrors.md` (mirrors), `rotating-bodies.md` (see-saw), `meltable-blocks.md` (blocks, launch), `liquid-system.md` (crust), `water-mechanic.md` (the crust data model), `saving-levels-ui.md` (the pause menu)
