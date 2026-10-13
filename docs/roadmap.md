# Roadmap: planned mechanics

Planned additions that close gaps found while writing the level-design reference: puzzles that the current objects almost support. **Nothing is planned at the moment**; every roadmap item so far is built and confirmed. Read `objon.md` (the core: setup, layers and groups, contracts, invariants, docs index) first.

**Always attach the patch.** The user has no access to the session's sandbox. Every session that changes the repository ends by attaching its result as a patch (`git diff` against the starting commit, saved as `<item id>.patch`, for example `n3.4.patch`) to its final reply, not just describing the changes. Test scaffolding and files Godot regenerates (`.import`, `.godot/`) are left out of the patch.

Covers: Not on the roadmap

**This is the one file that describes planned work, not the project as it stands.** Everything in it is unbuilt or unconfirmed. An item has two lifecycle steps, set out under Finishing a roadmap item in How to maintain this file in `objon.md`: when it is built, the owning topic file describes it (with a `## Status` line) and the entry here gains a line `Built, awaiting in-editor confirmation; see Status in <topic file>.`; when the user has confirmed it in-editor, the entry is deleted here and the design reference and puzzle file are updated. Do not leave a confirmed item here as history.

**Ids.** Items are `N<phase>.<n>`. They do not continue the older numbering that source comments cite (`roadmap 1.1` to `8.5`, all built).

**Effort** is a rough guess from reading the docs, not the code: S (a day or less, one script plus a scene), M (a few days, touches one existing system), L (a week or more, changes a shared solver). Re-estimate against the code before starting.

**Every new object** follows the checklist in `objon.md` (Checklist: adding a new object type): placement, layers and groups, contracts, `PowerTarget` and `invert`, save and restore, `Audio.PLANNED` sound ids, export audit (`export-audit.md`), level-editor habits, then a bullet in the owning topic file. The items below only list what is specific to each.

## Adding an item

Items go under a `## Phase <n>: <name>` heading, phases ordered from least to most invasive and, within a phase, by value. An item is an `### N<phase>.<n> <title> (<effort>)` entry with a **Gap**, a **Sketch**, **What it gives**, **Rules to keep**, **Open** questions and **Touches** (the topic files it will change).

## Not on the roadmap

The beam stays one polyline of one colour: `LaserBeam.trace()` returns a single result, so there is no splitter, prism or coloured beam. Two other gaps look intentional and are left alone: the player cannot push ice or metal blocks by walking (the shove guard in `meltable-blocks.md` is deliberate; a kick, the surf and an underside push move them; carbon fiber is the one block a walk moves), and doors never crush (`power.md`, Door).

Known weak spots in existing behaviour, listed here so nobody mistakes them for planned features: the Stingbot has no obstacle avoidance and can stick on a wall, and the proximity mine's blast has no line-of-sight test (both in `enemies.md`).

Reads with: `player.md` (launch), `power.md` (sources, devices and the contract most items extend), `lasers-arcs-mirrors.md` (mirrors), `rotating-bodies.md` (see-saw), `meltable-blocks.md` (blocks, launch), `liquid-system.md` (crust), `water-mechanic.md` (the crust data model), `saving-levels-ui.md` (the pause menu)
