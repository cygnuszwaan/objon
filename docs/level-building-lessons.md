# Level-building lessons learned

Practical notes for a Claude session generating `.tscn` levels for Objon, written after building 1-1 and 1-2 with the repo owner. Read `objon.md`, `docs/level-plan.md` and the relevant `docs/*.md` first. This file only covers what those don't: the mechanics of generating a level file, and what went wrong.

## How to maintain this file (read this first)

- **This is a living document.** If you learn something about building levels that isn't here, add it before the session ends. If something here turns out to be wrong, fix it in place and say what changed. Don't stack contradictions.
- **Tag every claim** as **[verified]** (you ran it, or decoded/diffed real files), **[assumed]** (read in docs or reasoned, never tested) or **[user]** (the owner told you). Upgrade or downgrade the tag when you learn more. Never promote an assumption without testing it.
- **Prune.** When a lesson becomes a repo doc or code (e.g. a helper script is committed), replace it here with a pointer.
- Keep new entries short and concrete: symptom, cause, fix.
- Add a line to the changelog at the bottom for every edit.

## Working with the owner

- **80/20 rule [user].** The owner wants a decent starting point, not perfection. They hand-edit the remaining 20% (terrain joins, one-way layers, art, balance) and upload the result.
- **Always start from their latest upload.** Files in `/mnt/user-data/uploads/` are the truth, not your earlier output and not the clone. Digest their diff before building on it (decode tilemaps, list nodes) so you don't undo their edits. [verified]
- **Ignore the existing level in the repo** when told to start from scratch; the owner supplies a `level_template.tscn`, and it can change between levels (the second one added a one-way layer).
- **Deliver the whole `.tscn`** to `/mnt/user-data/outputs/` and call `present_files`. Also write it into the clone's `scenes/levels/` so tests run against it.
- **Give status updates in a few words** if a long tool chain runs without output.
- Don't touch docs, `LevelCatalog` or other files unless asked. Mention them as follow-ups instead (neither 1-1 nor 1-2 is registered in the catalog yet).
- Be honest about what you didn't test (feel, balance, art). Say so in the summary.

## The template and coordinates

- Template is a 200×100-tile box [verified]: terrain walls at x 0–19 and 180–199 (rows 0–79), solid floor from row 80 down. Playable interior is x 20–179, **floor surface at y = 1280 px** (row 80 top). Tiles are 16 px.
- Player starts at (328, 1272). `WaterManager.kill_y` is 1600.
- Node sections under the root: `Collectibles`, `Enemies`, `Sources`, `Traps`, `Checkpoints`, `Liquids`, `Dynamic`, `Blocks`, plus the `Tilemaps` layers. Put things in the matching section.
- **Origins [verified from docs and scenes]:** gems, bonus gems, medkit and checkpoints use the **centre of a 16×16 tile**, so position = `(col*16+8, row*16+8)`. A standing row is the row directly above a solid surface. The **finish** uses the **bottom centre** on the floor line, e.g. `(col*16, 1280)`.
- Don't put a gem and a checkpoint in the same tile; the checkpoint hides the gem [user].
- The `Ladders` layer in the template sits at `position = Vector2(-16, 0)`; its tile coords are offset by one. Early template copies had stray floating ladder/catwalk tiles; clear them if present.

## Scene file format

- Level files are Godot 4 text scenes, `format=4`. A template's `uid` in the header will clash with the original template; delete the `uid="..."` attribute from a new level's header and let Godot assign one. [verified: loads fine]
- Add `[ext_resource]` lines **before** the first `[node ...]` line, with unique string ids. Instance new nodes as
  `[node name="Gem1" parent="Collectibles" instance=ExtResource("21_gem1")]` followed by `position = Vector2(x, y)`. `unique_id` on new nodes isn't needed. [verified]
- Scene paths: `scenes/collectibles/{gem_1,gem_2,medkit}.tscn`, `scenes/interactive/{checkpoint,finish,button,door}.tscn`. `gem_1` is the regular gem; `gem_2` is the bonus gem (50 points, doesn't count toward the finish unlock). Checkpoint has an `order` export; set it explicitly (1, 2, ...).
- The finish requires 100% of regular gems by default. Count gems and don't strand any.

## Tilemap data encoding (this is what makes generated terrain possible)

`tile_map_data = PackedByteArray("<base64>")`. Decoded: 2-byte header `00 00`, then 12 bytes per cell, little-endian: `x:int16, y:int16, source:uint16, atlas_x:int16, atlas_y:int16, alternative:uint16`. [verified: decoded real files and re-encoded generated ones that loaded]

```python
import base64, struct
def dec(b64):
    b = base64.b64decode(b64); d = {}
    for o in range(2, len(b), 12):
        x, y, s, ax, ay, alt = struct.unpack('<hhHhhH', b[o:o+12]); d[(x, y)] = (s, ax, ay, alt)
    return d
def enc(d):
    return base64.b64encode(b'\x00\x00' + b''.join(struct.pack('<hhHhhH', x, y, *v) for (x, y), v in d.items())).decode()
```

Generate levels by decoding the template's `Ground` data, adding cells, re-encoding and splicing the string back in. Build the level in a throwaway Python script; it doesn't need to live in the repo, but consider committing one if levels keep being made this way.

### Tile atlas coordinates

- **Riverbank (`Ground`, source 0)** [verified from existing data, **not seen rendered**]: `(1,0)` top edge, `(1,1)` interior, `(0,0)`/`(2,0)` top-left/top-right corners, `(0,1)`/`(2,1)` left/right sides, `(0,2)`/`(1,2)`/`(2,2)` bottom row. Block helper: left column gets x=0, right gets x=2, top row gets y=0. Blocks at least 2 wide; I didn't find a single-width tile.
- **`ground_tileset.tres`** has a different atlas layout. Source 2 (terrain sheet 1) contains half-height slabs: **top-half slab `(0..6, 5)`**, **bottom-half slab `(0..6, 4)`**. I used `(2, 1, 5)`. Source 3 is the spike sheet; `(0,0)` is spikes pointing up. [verified from the .tres, spikes tested; slab art not seen]
- Floor tiles under raised blocks stay; the owner joins visuals by hand.

## Player metrics (for sizing geometry)

- Standing collider is a capsule, **15 px tall**, radius 2. Crouched is **7.5 px**. [verified in `player.tscn` / `_make_crouch_shape`]
- Walk 150 px/s, sneak 50 px/s, ladder 100 px/s. `step_height` is 4 px. [docs]
- Jump apex is about **2 tiles** (v²/2g from the script constants). Treat a 3-tile ledge as a mantle and 4+ as unreachable from the floor. [assumed; not play-tested. Check this early.]
- Falling into a spike costs 1 health; health started at 4 in the headless test. [verified]

## Gotchas that cost time

1. **A plain `TileMapLayer` is not a hazard.** The player only damages from layers with `is_hazard_active()`. Spikes must go on a `PoweredSpikeLayer` (`scenes/traps/powered_spike_layer.tscn`) using `ground_tileset.tres`, whose spike tiles carry the `hazard_damage` / `hazard_direction` custom data. An unwired powered layer stays "out" (always live). Putting the group `hazard_layer` on a plain layer, or using a tileset without those custom-data layers, does nothing. [verified; fixed 1-1 this way]
2. **A 16 px gap does not force a crouch**: the standing capsule is 15 px. Real crouch gaps need an **8 px** opening, built from a half-slab tile: a full-tile mass above plus a top-half slab in the row below it leaves 8 px, so only a crouched player fits. The margin over 7.5 px is thin. [verified headless: standing blocked, crouch passes]. The slab lives on a separate layer using `ground_tileset.tres` (groups `ground`, `world_tilemap`), because riverbank has no such tile. Its art may not match.
3. **Don't block the main route with floor-level step blocks.** A staircase built on the floor row walls off the path. Build stairs over a tunnel (a "hill" with a tunnel under it) or put them off-route. [lesson from planning 1-2]
4. **A button inside an 8 px tunnel can't be crouch-pressed**: the player is already crouched and "arriving crouched doesn't count". The E4 "button inside the corridor" twist needs a stand-up pocket. Not built yet.
5. **Headless checks:** `-s script.gd` runs don't have autoloads, so the player/game singletons are missing. Instead make a tiny scene whose script loads the level, and pass the scene path as the main scene. Input actions are `move_left`, `move_right`, `jump`, `crouch`. [verified]
6. Godot headless needs downloading: `github.com` is on the sandbox allowlist, so fetch the 4.4.1 Linux binary from the godotengine releases into `/tmp`. Running `--import` rewrites some `.import` files in the clone; `git checkout` them afterward so the diff contains only the level.
7. **The clone is behind the owner's project.** Resources they've added locally (`riverbank-1-oneway.tres`, `catwalks.tres`, `spikes.tres`) aren't in the repo, so headless loads print "non-existent resource" parse errors for them. Ignore those; everything else loads. Don't "fix" the references.
8. Check what the owner actually shipped before assuming a feature exists. If a doc and the files disagree, trust the files and tell them.

## Ladders, catwalks and hanging (learned building 1-3)

- **Tile coordinates [user + verified]:** each of `ladder_tileset.tres` and `catwalks.tres` has one tile, **source 0, atlas (0,0)**. Paint ladders on `Ladders` and catwalks on `Catwalks`; nothing else goes on those layers.
- **The `Ladders` layer is offset by `position = (-16, 0)`**, so to put a ladder in world column `c`, paint cell `c+1`. Catwalks aren't offset. [verified: climbed a generated ladder headless]
- **Ladder shape:** run the cells from the floor row (79) up to one row *above* the catwalk row, so the top is flush with the deck and the player steps off. The catwalk tile can sit in the same cell column as the ladder.
- **Catwalk surface** is the top of its tile row (row 73 -> surface y = 1168, standing row 72). The tile is one-way (top 4 px). Underside bonus gems go one row below the catwalk row.
- **Hang route [verified headless, with a stub tileset]:** standing on a catwalk, hold crouch ~20 frames, then tap jump -> `is_hanging`; then holding move_right brachiates (about 130 px in 1.5 s). Pressing crouch and jump on the same frame just drops through. The end-of-deck mantle was not tested.
- **`catwalks.tres` is not in the clone** (owner-local file). Without it the `Catwalks` layer has no collision in headless tests and the player falls through. To test, temporarily copy `resources/ground_tileset.tres` to `resources/catwalks.tres` (strip its `uid`), run the test, then **delete the stub**; don't leave it in the diff. Ladders are fine (`ladder_tileset.tres` is in the repo).
- **Input action names:** `move_left`, `move_right`, `jump`, `crouch`, `climb_up` (down is `crouch`), `kick`. [verified in project.godot]
- Climb test: put the player on the ladder column, hold `climb_up` for ~240 frames; the player ended above the deck, off the ladder.

## Buttons, doors and powered layers (learned building 1-4)

- **Godot version:** the project is 4.7 (`config/features`). `github.com/godotengine/godot/releases/download/4.7-stable/Godot_v4.7-stable_linux.x86_64.zip` downloads in the sandbox. [verified]
- **Wiring in a generated `.tscn`:** an `Array[Node]` export is saved as `[NodePath("../../Sources/Btn")]` **and the node's header must carry `node_paths=PackedStringArray("sources")`** (before `instance=`). Without the header attribute Godot errors "Unable to convert array index 0 from NodePath to Object" and `sources` loads empty. [verified: had Godot save a wired scene and copied its output]
  - Powered layers: `sources`, `invert`, `show_ghost`, `warn_time` go straight on the layer instance (paths relative to the layer, e.g. `../../Sources/Btn`).
  - Doors: override the child, `[node name="PowerTarget" parent="Dynamic/DoorA" index="2" node_paths=PackedStringArray("sources")]` with `sources = [NodePath("../../../Sources/Btn")]`, plus `[editable path="Dynamic/DoorA"]` at the bottom of the file.
- **`latch_mode`:** MOMENTARY 0, TOGGLE 1, TIMED 2. Colours: blue 0, red 1, yellow 2, green 3. [verified in `button.gd`]
- **A button is a 5 px pedestal and `step_height` is 4**, so the player must jump onto it; plan one jump's room either side. A TOGGLE hopped on and off twice flips twice. [verified headless]
- **The ground's collision top is at y = 1282, not 1280** (2 px below the tile top). A one-way catwalk whose top is 1280 therefore **cannot be walked onto from the floor**: the feet are already below its top, so the player walks through and falls. A bridge that starts at floor level goes one row up (row 79, top y = 1264) and the player jumps onto it; walking off it onto the floor is fine. [verified headless; the first 1-4 bridge at row 80 failed this way]
- **A powered ladder layer needs `position = Vector2(-16, 0)`** like `Ladders` (the template instance has none), and its cells are painted at col+1. [verified: climbed it]
- **Ladder beside a solid ledge** (no catwalk through it): the climb ends about 21 px above the ledge surface and the player presses right to land on it. Only a ladder that passes through a catwalk or floor cell gets the automatic landing snap. [verified headless]
- **Mounting a ladder while still landing from a jump latches `climb_up`** (the mount lifts the feet and the landing branch ends the climb at once; releasing and pressing up again works). A headless driver must let the player settle on the floor (~25 frames) before holding `climb_up`. Release every held action (`jump` especially) when a scripted walk ends. [verified]
- **Timer sums for a TIMED ladder race** (climb 100 px/s, walk 150 px/s, a ladder retracts `duration + warn_time` after the press): two buttons wired to one layer are ORed, so a second button midway restarts the window. 1-4 uses duration 2 s + 1 s blink on both, so a player who dawdles needs the mid button. Falling is free (no fall damage), so a missed race costs only time. [verified numbers by script; feel not tested]
- **Headless route test:** a scene that loads the level, drives `Input.action_press`, and prints position/health/gems per stage (hop onto each button, walk, climb) is enough to prove a route is completable; it took four iterations to get the driver right, so keep it. Not committed to the repo.
- A one-way **catwalk bridge flush with ladders:** a static ladder (the pit rescue ladder in 1-4) shares a cell with the bridge; ladder top = the row above the deck, as in 1-3.

## Zone sensors, doors and camera cues (learned building 1-7)

- **Template now includes** `PoweredSpikeLayer`, `PoweredCatwalkLayer`, `PoweredLadderLayer` and `ConductorLayers` as unwired instances, and `catwalks.tres` / `riverbank-1-oneway.tres` are in the repo. Rename-free: wire the template's own `PoweredSpikeLayer` (add `node_paths=PackedStringArray("sources")`, `sources`, `invert`, `show_ghost`) instead of adding a new one; add an extra plain instance for unwired always-out spikes. [verified]
- **Godot 4.7 headless** loads the repo clone with no stubs needed now; `--import` left no tracked diffs. [verified]
- **Zone-shut door:** a `ZoneSensor` (instance in `Sources`, `size` set per instance, origin at the zone centre) wired to a door with `invert = true` on the door root gives "closes behind the player, reopens when they leave". Start the zone one tile past the door column so the door never closes on the player. A 2-wide wall with a doorway needs the door in only one of the two columns. [verified headless: closed after the player passed, stayed open until then]
- **Camera cue:** instance in `Dynamic`, `node_paths=PackedStringArray("sources")` and `sources` go on the cue root (no Editable Children needed). A TIMED button gave `is_cue_playing() == true` the frame after the press. [verified headless; framing/feel not seen]
- **Scripted button press:** a driver that holds `jump` while moving overshoots a 16 px button. Walk to the button's x, release, then tap jump with a short `move_right`. [verified]
- 1-7 (*Look Ahead*): TIMED button (9 s) retracts a 10-tile inverted spike field out of sight, with a camera cue on the field; checkpoint; a 20x14 shut-in room whose entry door closes via the zone; ladder to a catwalk deck, TOGGLE button opens the exit door; optional underside route over a floor spike strip for bonus gems and a medkit.

## Level design conventions used so far

- Difficulty is gentle in world 1: short spike patches (2 tiles) over flat landing space; the owner removed spikes from 1-1 for being too unforgiving [user].
- Each level: a regular gem trail teaching the mechanic, one or two checkpoints, a finish near the right, plus an optional **bonus detour** (bonus gems + a medkit, with a small risk).
- Checkpoint just before a long or risky section, not inside it.
- 1-1: steps 1/2/3 tiles (the 3rd needs a mantle), a 3-tile wall, a bonus pillar staircase (owner later moved it to a one-way layer). 1-2 (crouch/sneak + spikes, puzzle type E4 in `docs/puzzles.md`): three crouch tunnels, two spike hops, a bonus roof route over the long tunnel. 1-3 (*Up and Under*, ladders/catwalks/underside hang, puzzle types E5 and E1): ladder up to a 36-wide catwalk deck; the deck's right half hangs over a floor spike strip, with the underside route (crouch+jump, brachiate) holding the bonus gems and medkit so the risk is optional; a checkpoint, then a second, taller ladder to a second deck, then a drop to the finish. Check `docs/level-plan.md` for what each level is meant to introduce before designing. 1-4 (*Press and Cross*, buttons/doors/TIMED/powered layers, puzzle types E8 and H6): a TOGGLE button opens a two-tile doorway in a wall; a TIMED button retracts a 12-tile inverted spike field (ghost on); a TIMED button summons a 16-tile bridge over a pit (ghost on, 1 s blink) with a bonus gem/medkit nook and a rescue ladder in the pit; then a two-stage ladder race up two ledges with a second TIMED button midway; checkpoint on the top ledge, then a drop to the finish.

## Open questions / not yet verified

- Real jump apex, mantle limit, and whether a 4-tile ledge is climbable.
- Whether the 8 px tunnel feels fair in play (0.5 px margin).
- How the half-slab art looks next to riverbank tiles.
- Whether bottom-row riverbank tiles `(x,2)` connect visually under a mass.
- Single-width block tile coordinates.
- Whether the end of an underside route mantles cleanly onto the deck edge (the 1-3 deck is contiguous, so it may never need to), and how generous the ladder-top step-off is.
- Enemies are untouched. Buttons, doors and powered layers are used in 1-4 (headless-verified, feel and art not seen).
- 1-4: whether the 2 s ladder window feels like a race or a chore; whether the spike ghost reads clearly; whether jumping up onto the bridge from the lip feels natural.
- Register new levels in `LevelCatalog` (not done).

## Changelog

- Initial version: written after levels 1-1 and 1-2.
- Added the ladders/catwalks/hanging section after building 1-3.
- Added the buttons/doors/powered-layers section and the 1-4 summary after building level 1-4.
- Added the zone sensor/door/camera cue section and the 1-7 summary after building level 1-7.
