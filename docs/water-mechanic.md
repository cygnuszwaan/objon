# Water system — reference

This file is the detailed reference for the water system: full data model, public API, every
tuning constant, and what's still open. `liquid-system.md` (the "Liquid system" bullet) and the "Swim" bullet in `player.md`
have the short version — read those first. This file exists on its own, rather than folded into `liquid-system.md`
directly, because the system is large enough (particle simulation, basin authoring/query API, player
push, swim state, two spawn sources, non-tilemap collision) that inlining all of it would make
`liquid-system.md` itself front-load every session with detail most sessions won't need. Same maintenance
rule as `objon.md` applies here: this describes the system as it currently stands, not how it got
there — no changelog, no bug-fix narration, no roadmap checkboxes. If a fresh read of the code
contradicts something below, fix the claim here rather than leaving both versions in.

## Particle simulation (`water_manager.gd`)

One `WaterManager` per level scene (group `"water_manager"`, not an autoload — water state
shouldn't survive a level reload). Particles are data, not nodes: position/velocity/age/creep-state
live in fixed-size parallel arrays (`MAX_PARTICLES = 512`), dense-packed (a particle is live iff its
index is `< _active_count`) with swap-and-shrink removal. `spawn_particle(pos, vel) -> int` is the
generic primitive (returns `-1`, silently, if the pool is full) — a dropped spawn under extreme load
is an accepted failure mode, not a bug. Rendering is one `MultiMeshInstance2D` draw call, quad size
`LiquidConstants.PARTICLE_PIXEL_SIZE` square, with three per-particle randoms rolled once at spawn to
break up what would otherwise be a flat field of identical squares creeping in lockstep: an HSV-value
color jitter, a RENDER-ONLY size multiplier (`_visual_scale`, `PARTICLE_SCALE_JITTER_MIN`/`MAX`) built
into the instance transform's basis instead of `Transform2D`'s rotation/position constructor, and a
multiplier on floor-creep speed (`_creep_speed_mult`, `±CREEP_SPEED_JITTER`) applied at the one place
`profile.creep_speed` is read. All three are cosmetic/movement-feel only — `PARTICLE_VOLUME` and every
collision/absorb dimension still use the unscaled `PARTICLE_PIXEL_SIZE`, so represented volume and
physical size are unaffected by the size jitter. Liquid particles (not `STEAM`) also shrink linearly to nothing over the last
`PARTICLE_SHRINK_TIME` (4s) of their `PARTICLE_LIFETIME`, applied to the same render scale in `_process()`; it is
render-only, so a shrinking particle still collides and absorbs at full size until it despawns. Deliberately NOT done: z-sorting smaller particles to
draw in front of larger ones — multimesh instance slot and particle array index are the same number
today (what makes `despawn_particle()`'s swap-and-shrink a single move per array); drawing in
size-order would mean a per-frame sort plus reworking color/transform writes through that sorted
mapping, a real architectural change for a subtle effect. `_position` is each particle's CENTER
(matches the multimesh quad's own transform origin) — every other system (collision, absorb height
check) assumes this.

**Per-frame step** (`_physics_process()`, a `while` loop so a same-frame despawn re-processes the
slot it just refilled): for liquid particles, the `kill_y` floor check first (despawn when the
particle's center is below it), then the lifetime check (force-despawn past the type's `lifetime`,
20s for liquids), then basin absorb/surface handling (see below), then the general gravity/collision
step.

**Kill floor**: `WaterManager.kill_y` (export, world-space pixels, +y down, default 10000 — effectively
off) is the per-level "fell off the map" line. Set it a little below the lowest geometry in the level so
particles that leave the map are culled at once instead of simulating until their lifetime expires.
Steam is exempt (gas drifts up).

**Collision** is one raycast per particle per frame, from its current position along that frame's
motion vector, via `PhysicsRayQueryParameters2D`/`intersect_ray()` against `tile_collision_mask`
(default `3`, layer 2). A hit is only acted on if its collider is `world_tilemap` or a member of the
`"water_solid"` group (see "Non-tilemap collision" below) — anything else the query happens to hit is
discarded like a miss. On a real hit: above `BOUNCE_MIN_IMPACT_SPEED` (impact speed into the
surface), velocity reflects off the hit normal (`Vector2.bounce()`) damped by `BOUNCE_RESTITUTION`;
below it, the into-surface velocity component is cancelled and the tangential component survives
(damped by `SLOPE_SLIDE_FRICTION`) — this is what lets a particle creep downhill instead of sticking
on contact. Rest position is the hit point offset half a particle-width out along the normal.

**Ground creep** (non-basin flat ground and slopes): a particle landing below the bounce threshold on
a floor-like normal (`FLOOR_NORMAL_MAX_Y`) creeps at `CREEP_SPEED` along the surface tangent.
Direction is chosen once on first floor contact (downhill if sloped, else the sign of its own
horizontal velocity, else random) and persists across falls. A particle never creeps uphill — a
surface whose normal leans against the creep direction (`UPHILL_MIN_NORMAL_X`) blocks it, flipping
direction up to `MAX_CREEP_REVERSALS` times (default 1; `-1` = unlimited); past that it stops creeping
for good and rests/slides under gravity until the lifetime cap removes it. Falling off an edge needs
no code — past a floor's edge the motion ray just stops hitting anything.

**Bounce/creep overlap**: creep direction is chosen on the very FIRST floor contact
(`_resolve_surface_contact()`), whether or not that contact still bounces, rather than only once
impact speed decays below `BOUNCE_MIN_IMPACT_SPEED` — a particle bouncing several times before
settling used to sit essentially in place for all of them (only whatever tangential velocity it
already happened to carry moved it), reading as hopping in place before suddenly starting to flow.
The blocked-ahead check (see "Ground creep" above) is now computed up front, before deciding whether
to bounce at all, and a blocked contact skips bouncing entirely in favor of the ordinary
reversal/`MAX_CREEP_REVERSALS` handling — **fixing a real bug**: a creeping particle's own speed
routinely exceeds `BOUNCE_MIN_IMPACT_SPEED` (water's `creep_speed` is 24, the threshold 10), so a
particle arriving square at a wall used to always take the bounce branch and `return` before the
reversal check below it was ever reached. `MAX_CREEP_REVERSALS` — including `-1` for unlimited — had
no effect on this, since the code that reads it never ran: the particle just reflected in place and
walked straight back into the same wall next frame, forever. A wall hit before the particle has ever
creeped (no direction chosen yet) still bounces normally — the block check only fires once a
direction exists to be blocked. On every contact where bouncing is still allowed, a bounce above the
threshold blends in `BOUNCE_CREEP_BLEND * profile.creep_speed` of tangential velocity in the
already-chosen direction, so a particle visibly drifts toward where it's headed while still bouncing,
not only after.

**Non-tilemap collision**: `moving_platform.gd`, `drop_platform.gd`, `crusher.gd` (`ArmBody`), and
`cannon.gd` (`StaticBody2D`) self-register into the `"water_solid"` group in their own `_ready()`
(collected via a deferred call in `WaterManager._ready()`, so registration order can't race it). A
particle resting on a registered body is carried by that body's own per-frame position delta (same
technique the player's platform-hang follow uses); a crusher/cannon's registered body never itself
translates, so this is automatically inert for them. A drop platform's collision simply disabling
mid-fall makes the next frame's raycast stop finding it — a resting particle falls exactly as if the
platform vanished, no explicit release code needed.

## Basins (`basin.gd`, class `WaterBasin`)

A basin is a hand-placed `@tool` node (same placed-and-sized-by-hand convention as the conveyor
belt) — never auto-detected from geometry. `width_tiles` is authored by hand; `world_tilemap_path`
is an explicit `NodePath` (assigned in the Inspector, since `@tool` code can run before groups are
populated). Column 0 and the last column are the basin's two walls; everything between is interior.

**Structural data**, derived at edit time and re-derived once at runtime load (`@export_storage` so
it actually persists into the saved scene — a plain runtime `var` here would silently reset to empty
every time the scene is loaded):
- `floor_rows: Array[float]` — one entry per column, sampled from that column's tile's own physics
  collision-polygon points (not a physics-space query — the polygon data is read directly off
  `TileData`, since `@tool` code has no guaranteed synced physics space). A fully-solid tile yields a
  whole-number row; a half-height or sloped tile yields a fractional one.
- `seabed_floor_rows: Array[float]` — a separate per-column sample from the same tile data, used only
  for the drawn seabed shape (see below): the deeper of a tile's own top-surface height at its left
  edge vs. its right edge, always the first solid boundary from above (never an underside). Kept
  distinct from `floor_rows` (a center sample) because the seabed needs each column's actual deepest
  edge to avoid a visible gap against a sloped neighbor; `floor_rows`/height math don't need that.
- `spill_column: int` — auto-derived, always (`_update_spill_column()`): whichever wall column has
  the larger `floor_rows` value (physically lower = shorter wall = spills first); ties favor the left
  wall. There is no per-basin override for this — every basin spills over whichever wall the water
  naturally reaches first.
- `floor_row_override_enabled: Array[bool]` + `floor_row_overrides: Array[int]` — a matched pair,
  auto-synced to `width_tiles` length, for the rare case the automatic per-column floor derivation
  picks wrong. A column is overridden only where the flag is true; its value is a LOCAL row offset
  from the basin node's own origin row (the same number the debug draw shows).

**Fill state**: `fill_volume: float`, in tile-area units (1.0 = one full tile of cross-section across
the basin's whole interior width) — a live runtime value, mutated only by `add_volume()`/
`remove_volume()`, never touched by structural rebuilds. Volume↔surface-height conversion is a real
per-column walk (`_surface_row_for_volume()`/`get_surface_row()`), not a flat `volume / footprint`
division — a shallow interior column only starts holding volume once the rising surface reaches its
own floor. `_capacity_volume` (volume at which the basin reads full) is computed the same way, up to
the spill column's floor height. Query API: `get_surface_row()`, `get_surface_height_tiles()`,
`get_surface_world_y()`, `is_column_in_range(map_col)`, `get_fill_fraction()`, `is_full()`. A basin
with no interior or zero capacity reads as always-full rather than dividing by zero.

**Absorption**: `WaterManager._try_absorb()` checks a particle's position against
`get_basin_for_column(map_col, position.y)`; if in range and the particle's leading (bottom) edge has reached
`get_surface_world_y()` (the basin's OUTER surface — the crust's top face when crusted, else the liquid
surface), it's credited via `add_volume()` and despawned. A full basin declines instead (rather than
absorb-and-discard), so the particle falls through to overflow handling. A crusted basin absorbs nothing
— see "Crust" below. `_basin_for_particle()` returns no basin for a particle whose top edge is below its
column's seabed (`get_column_seabed_world_y()`, each column's deepest floor point): such a particle has
left the basin through the bottom — a drain outlet, or falling past a basin's floor into a lower level —
and must neither be absorbed back in nor snapped to a full basin's synthesized surface.

**Overflow**: no authored spill point, no spawned "overflow particle." A full basin's surface sits,
by construction, level with its shorter wall's own top — so a particle reaching that surface just
creeps along it (ordinary ground-creep rules, via a synthesized surface contact since a full basin's
surface isn't real tilemap geometry) until it walks itself off that wall with no obstacle, while the
taller wall still physically blocks/reverses a particle headed that way like any other wall. Basins
chain into each other for free this way — a creeping-out particle that lands in a neighboring basin's
footprint gets absorbed there by the normal settle check, with no adjacency graph or connectivity
pass anywhere.

**Pre-filled basins**: `initial_fill_depth_below_surface` (default `NO_INITIAL_FILL = -1.0`, meaning
"not authored, start empty") authors a starting depth in tiles below the basin's own full/spill
surface — `0.0` means start full. `_ready()` converts this to a volume (`_initial_fill_volume()`, via
`_volume_for_surface_row()`, the exact inverse of the volume→row query) and credits it through the
normal `add_volume()` path once, before the basin registers with `WaterManager` — not routed through
any spawn/melt/faucet path, since it's a starting condition rather than a fill event.

**Rendering**: `get_body_polygon_world() -> Array[PackedVector2Array]` returns one closed polygon per
contiguous run of actually-wet interior columns (a dry hump mid-basin that the rising water hasn't
covered yet splits the water into separate visible pieces rather than being clamped into a
degenerate shape) — flat top edge at the surface line, stepped bottom edge tracing `seabed_floor_rows`
as a staircase. Drawn behind the tilemap (lower z-index than ground tiles) so any mismatch between
the flat-per-column approximation and a sloped tile's real geometry is hidden under the opaque tile
art rather than visible.

**Wall overlap** (drawing only): the settled liquid, its surface art and the crust extend `wall_overlap_px` (export, default 8, rounded down to whole 4px strips, capped at one tile) behind each wall column, so a wall sprite with transparent padding on its open face shows liquid behind it instead of a gap. Only a run that touches an interior edge column gets a pad on that side; each pad strip copies the height and floor of the edge strip it continues. It is applied by `_run_strips(..., with_walls)` and `_build_column_runs(..., with_walls)`, which only the drawing paths pass; `get_body_polygon_world()`, `get_crust_polygon_world()`, collision and every query stay interior-only. A wall whose outer face is also transparent will show the overlap there, so lower the export for thin walls.

**Skins** (`res://scripts/liquid_skin.gd`, `class_name LiquidSkin`; runtime only): a liquid type can have a
top-of-liquid art strip (16px frames stacked vertically, one tile tall, tileable sideways only). `SKIN_BY_TYPE` maps each liquid type to
its art file and loop `fps`: `SLAG` uses `spsh_molten_steel.png` at 4 fps and `WATER` uses `spsh_water.png` at 6 fps
(faster, so it reads as less viscous). A type whose file is missing keeps its flat `BODY_COLOR_BY_TYPE` colour. The art is the surface layer and everything deeper is filled with the art's own
bottom-row colour (average of the frame's last row), so any depth is built from one tile. `LiquidSkin` reads the
texture itself: frame count, the transparent `headroom` rows (the surface line sits at the first opaque row;
headroom is never drawn) and per-frame bottom colours — swapping the art needs no code change. The art is drawn
in 4px strips (`RIPPLE_SUBDIVISIONS`) by `_draw_skin_strips()`, each clipped at its own column's seabed; tops are
snapped to whole world pixels, and a live ripple offsets each strip by the mean of its two samples. While a
liquid is skinned its drawn body's top edge is a staircase of those same strips (`_run_strips()`), so the body
never pokes above or falls short of the art. `_process` runs for the skin clock whenever a skinned liquid is
present (`_needs_process()`), not only during a ripple. While the liquid touches a crust's underside
(`_liquid_hidden_by_crust()`) the skin isn't drawn at all — the slag under the crust is the flat body colour —
and it appears (and starts animating) once a drain opens a gap past the contact tolerance.

**Registration**: `get_registration_data()` hands `WaterManager` this basin's interior columns
(absolute tilemap space) paired with floor rows; `WaterManager.register_basin()` builds
`_column_basin_id`/`_column_floor_row` lookups from it. Registration is deferred
(`.call_deferred()`) since sibling `_ready()` order between a basin and `WaterManager` isn't
guaranteed.

`_column_basin_id` maps a column to a LIST of basin IDs, not one — two basins can share a column
when one's floor sits directly above another's rim (a drain faucet's tile is exactly this: the
basin above's floor and the basin below's ceiling-less open top). `get_basin_for_column(map_col,
world_y)` disambiguates via `WaterBasin.owns_world_point(map_col, world_y)`: inclusive of the
basin's rim (`get_rim_world_y()`, same for every column) down to that column's seabed
(`get_column_seabed_world_y()`). The exact world y of a shared floor tile's top edge belongs to the
basin above (that tile IS its seabed) and is strictly above the basin below's rim (which starts a
full tile lower), so the boundary is never ambiguous. Every caller that resolves a basin from a
world position — particle absorb/push/hazard, the player's swim probe, the faucet's drain link —
passes its own world y through for this reason; a plain column-only lookup silently picks whichever
basin registered last on that column.

**Debug draw** (editor-time only, `Engine.is_editor_hint()`-gated): basin bounds/column range, plus
a waterline at whatever surface an authored `initial_fill_depth_below_surface` targets. No
spill-column marker — with basins always hand-authored, two equal-height walls are a normal shape,
so marking one as "the" overflow point would be misleading.

## Surface ripple (`basin.gd`, cosmetic)

A splash, a landing particle or a drain disturbs the top edge of a settled basin's liquid, and the
disturbance travels sideways and dies away. Drawing only: `fill_volume`, every surface-height query,
collision and crust are untouched, and `get_body_polygon_world()` still returns the flat shape.

- **Model.** Each interior column is cut into `LiquidConstants.RIPPLE_SUBDIVISIONS` (4) samples, one per 4px,
  each holding a height above rest (`_ripple_h`, px, + = up) and a vertical speed (`_ripple_v`). Every fixed
  step (`RIPPLE_STEP`, 1/120 s, as many per frame as needed) a sample is accelerated by its neighbours (a
  discrete wave equation), pulled back to rest by `RIPPLE_RESTORE` and slowed by damping. Wave speed is the
  profile's `ripple_speed` in px/s, capped at 0.9 sample per step (the stability limit is 1.0). Heights are
  clamped to `RIPPLE_MAX_HEIGHT_PX` (3) and speeds to `RIPPLE_MAX_VELOCITY` (90). On a full basin a crest may
  not rise above the rim, since the surface already sits level with the shorter wall.
- **Viscosity is data**, in `LiquidProfile` (`ripple_speed` px/s, `ripple_damping` 1/s, `ripple_strength`
  multiplier on every disturbance). Water 80 / 2.0 / 1.0; slag 22 / 6.0 / 0.4. A water wave crosses a tile in
  about 0.2 s and a burst takes 3-4 s to settle; a slag wave takes about 0.75 s per tile, mostly stays where it
  was made, and settles in about 2 s. Nothing in the code branches on the liquid type.
- **Where it travels.** Only through strips over wet columns (seabed below the liquid surface, the same test
  the drawn runs use), so ripples reflect off the two walls and off a dry hump, and each basin ripples on its
  own. A crust over touching liquid hides the surface, so ripples are cleared when a crust forms and ignored
  while the liquid touches it.
- **Drawing.** `_draw_settled_body()` calls `_get_drawn_body_polygons()`, which is `_build_column_runs(...,
  rippled = true)`: each run's flat top edge becomes one vertex per sample. Every vertex is clamped above the
  seabed of both strips it touches (and never above the flat surface line, so nothing pops when the ripple
  ends), so the polygon can't fold over its stepped bottom, which the triangulator rejects. A skinned liquid's
  body is not drawn from that polygon at all: `_draw_body_strips()` fills one rectangle per ripple strip (the
  same staircase, from `_run_strips()`), because `draw_colored_polygon()` triangulates all-or-nothing and a
  ripple's whole-pixel staircase could occasionally be rejected, blanking the whole body for a frame. The
  polygon form is still used for unskinned liquid, and `debug_check_body` on a basin warns when it would fail
  to triangulate. The crust and the shape queries never ripple.
- **Cost.** Nothing while calm. `disturb()` turns `_process` on; once every sample is below
  `RIPPLE_SETTLE_HEIGHT`/`RIPPLE_SETTLE_VELOCITY` the arrays are zeroed and `_process` turns itself off.
- **API.** `WaterBasin.disturb(world_x, velocity_px_s, radius_px = 6.0)`: adds a vertical speed (negative =
  down, what a falling object does) to the samples within the radius with a cosine falloff, scaled by the
  liquid's `ripple_strength`. Ignored in the editor, on an empty basin and under a touching crust. Callers:
  - `WaterManager._try_absorb()`: a same-type particle landing, `-|vy| * RIPPLE_PARTICLE_IMPULSE` scaled by
    `PARTICLE_VOLUME` so a finer `ACTIVE_PRESET` stirs the same in total. A melt burst lands a whole tile of
    particles at once and makes a proper splash.
  - `WaterFaucet._drip_from_basin()`: each drain drip dimples the surface above the outlet
    (`DRAIN_RIPPLE_PER_VOLUME`, per volume so it doesn't depend on the preset).
  - `player.gd`: swim entry (`SWIM_SPLASH_IMPULSE` times entry speed, before the speed cap) and a wake while
    swimming within `SWIM_WAKE_MAX_DEPTH` of the surface (`SWIM_WAKE_IMPULSE` times horizontal speed). Slag is
    never swum in, so this is water only.
  - `MeltableBlock._splash_ripple()`: an ice or metal block first touching a liquid at speed, sized by its width.

## Player push (`water_manager.gd` + `player.gd`)

Every physics frame, each active particle within `PLAYER_PUSH_RADIUS` of the player (binary check,
no falloff, measured from the player's origin) contributes a push vector in its own direction of
travel — a stationary/settled particle contributes nothing even in contact. The summed vector is
capped two ways, tightest wins: a flat `PUSH_CAP` ceiling (so a flood is a real threat but can never
fling the player off-level), and a per-frame ceiling equal to whichever contributing particle is
currently fastest — added because the flat cap alone let many slow particles (e.g. a flat-ground
crawling flood) sum to a push faster than any of them were actually moving, since each particle's
contribution is a fixed magnitude regardless of its own speed. `get_player_push() -> Vector2` is the
read side; `player.gd`'s `_water_push_speed()` adds its `.x` to `velocity.x`, gated off while
`is_climbing`/`is_hanging`/`is_swimming`.

Per-particle push magnitude is `LiquidConstants.profile(type).push_force_per_tile_volume * LiquidConstants.PARTICLE_VOLUME` — "how
hard one full tile's worth of water would shove, split across however many particles that tile is
currently divided into" — so total push for a given volume of water stays roughly consistent no
matter which `ACTIVE_PRESET` is active; only the granularity changes.

## Player swim state (`player.gd`)

See the "Swim" bullet in `player.md` for the full behavioral summary. Reference values: `swim_probe_offset_y
= -4.0`, `swim_enter_depth = 0.0`, `swim_exit_depth = -4.0`, `swim_speed = 120.0`,
`swim_up_speed = 80.0`, `swim_sink_speed = 30.0`, `swim_gravity = 150.0` (an approach *rate* toward
`swim_sink_speed` via `move_toward()`, not a target itself). `_water_surface_depth()` probes at
`collision_shape.global_position + Vector2(0, swim_probe_offset_y)`, looks up the basin via
`water_manager.get_basin_for_column(col, probe.y)`, and returns positive-when-submerged (`probe.y -
basin.get_liquid_surface_world_y()`), or `-INF` with no basin at that column at all — a dry column can
never satisfy the enter threshold. `_water_probe_basin()` also reports no basin when the probe is below
the column's seabed, so standing in a room under a basin (or under a drain) never reads as submerged.
Measuring against the liquid's own surface rather than the crust's faces means a crust's solid skin
reads as ground, and the void a drain leaves under a hanging crust reads as open air; only entering
the actual liquid counts. Without crust this is just the plain surface.

## Surfing (`water_manager.gd`, `basin.gd`, `player.gd`)

See the Surf bullet (Water) in `player-surf.md` for the behaviour. Both queries are pulled by the player only while it surfs.

- **`WaterManager.get_floor_wetness(feet, half_width) -> float`**: 0..1 coverage of the footprint (`2 * half_width` wide) by liquid particles in the band from `WET_BAND_ABOVE` (8 px) above `feet.y` to `WET_BAND_BELOW` (2 px) below it, within the footprint plus half a particle. A particle counts only if it is a non-gas, non-hazardous type (slag never wets), speed is at least `WET_MIN_SPEED` (8 px/s) and its vertical speed is at most `WET_MAX_VERTICAL_SPEED` (60 px/s), so settled, falling and bouncing particles are ignored. Coverage is summed `PARTICLE_PIXEL_SIZE` per particle over the width, so `ACTIVE_PRESET` doesn't change it, and `WET_FULL_COVERAGE` (0.5) of the width is a full reading. It is an O(particles) loop with no state; the player smooths it (instant rise, decay over `surf_wet_decay_time`).
- **`WaterManager.find_skim_basin(world_x, feet_y, catch_depth) -> WaterBasin`**: resolves the column under `world_x` and returns the basin there that has liquid over that column (`has_liquid_at_column()`), no crust, a non-hazardous liquid, the feet not below the column's seabed, and a liquid surface no more than `catch_depth` px above the feet (surface at or below the feet preferred; with stacked basins the smallest gap wins). Null otherwise. The lookup doesn't go through `get_basin_for_column()` because that needs a point at or below the rim, and a surfer arrives from above it.
- **`WaterBasin.set_skim_floor(active, catch_depth = 6.0)`**: runtime only (ignored in the editor). Active creates once, then re-places every call, a `top_level` `StaticBody2D` named `SkimFloor` with one `CollisionShape2D` (`one_way_collision` on, `one_way_collision_margin` = `catch_depth`, a `RectangleShape2D` `SKIM_FLOOR_THICKNESS` (8 px) thick) whose top is `get_liquid_surface_world_y()` (the flat line, never the ripple) and whose width is the interior columns plus `SKIM_FLOOR_EDGE_OVERLAP` (2 px) into each wall, on layer `SKIM_FLOOR_LAYER_BIT` (4, physics layer 3). Inactive sets its layer to 0. It is not in `"water_solid"` and particles and blocks don't mask layer 3, so only a body that adds layer 3 to its mask (the player does, in `_ready()`) can stand on it. The player re-places it each frame it is up and drops it from `_end_surf()`; call it every frame, since nothing else clears a stale one.
- **Pitfalls**: `_swim_pose_fits()` queries with the player's whole mask, which includes layer 3, so the floor must be dropped before a swim pose is tried (it is: swim entry is reached only after `_end_surf()`); anything else that queries with the player's mask while a skim floor is up would see it.

## Sources

- **`WaterFaucet` (`faucet.gd`)**: a tile-anchored node — origin at its tile's top-left, with
  `spawn_offset` (pixels from that origin, default `(0,0)`) picking where inside the tile particles
  appear; an editor-only overlay outlines the tile and marks the spawn point. `is_open` (exported bool,
  plus a debug key that flips it at runtime) gates it; `flow_rate` (per-instance export, volume per second in tile-area units — the units of
  `fill_volume`) sets how much liquid it moves. A volume budget accrues at `flow_rate` and emits one
  particle per `PARTICLE_VOLUME` accrued (several in one frame at high rates; the remainder carries), so
  the flow is independent of `ACTIVE_PRESET` — the preset only changes how finely it's divided. The
  budget is cleared while closed. Horizontal velocity is jittered by `FAUCET_JITTER_SPEED`. Its mode is resolved once, lazily, on the
  first open frame (basins register with the manager on a deferred call): the cell is taken from the
  tile's centre via `WaterManager.world_to_cell()`, and if that cell is the floor tile of a basin's
  interior column (`WaterBasin.is_floor_cell()`), the faucet is a **drain**; otherwise it is a plain
  **source**.
  - **Source**: spawns its own `liquid_type` at the spawn point via `spawn_particle()`.
  - **Drain**: each drip first checks `has_liquid_at_column()` (crust, void or a dry floor over the tile
    emit nothing) and that the particle pool isn't full (`spawn_particle()` drops silently when it is,
    so nothing is debited then), then debits `LiquidConstants.PARTICLE_VOLUME` via `remove_volume()` and
    spawns a particle of the BASIN's `liquid_type` (the faucet's own export is ignored). The last
    sliver smaller than one particle still emits a whole particle. The spawn y is clamped to at least
    one particle-width below the tile's top edge so the outlet starts wholly under the seabed (see the
    absorption note above). The tile must be solid — basin floors are derived from tile collision — so
    the outlet particle starts inside a solid tile and relies on the raycast ignoring shapes it starts
    inside.
- **`WaterManager.spawn_melt_particles(tile_pos: Vector2i)`**: batch primitive for a melting ice tile
  — spawns `PARTICLES_PER_TILE` particles at zero velocity, jittered within the tile's own footprint
  so a burst doesn't read as one fat particle. Exists and is ready to call, but has **no caller
  yet** — the laser/mirror/ice chain it's for isn't built.

## Tuning constants — still placeholders

None of these have had a dedicated tuning pass; they're all "reasonable placeholder," not "felt
right in-editor." Worth a pass together once there's a real level to test against:

- `liquid_constants.gd`: `ACTIVE_PRESET` (currently `TEN` → 10 particles/tile, 5px each, shared by
  every liquid type), `FAUCET_JITTER_SPEED` (12 px/s), `PUSH_CAP`
  (220 px/s, shared outer ceiling — see water_manager.gd's own per-type cap below), `STEAM_LIFETIME`
  (1.2s), `PARTICLE_SHRINK_TIME` (4s, liquid end-of-life shrink), `STEAM_PUFF_COUNT`/`STEAM_PUFF_SPEED` (in water_manager.gd, listed here since they're the
  steam-effect's own tuning knobs), and per-`LiquidProfile` (`profile()`): WATER's/SLAG's own
  `creep_speed` (24 / 10), `bounce_restitution` (0.35 / 0.15), `slope_slide_friction` (0.9 / 0.6),
  `push_force_per_tile_volume` (24.0 / 36.0) — none of SLAG's values have been felt in-editor at all,
  they read correctly in-editor but haven't had a dedicated tuning pass.
- `water_manager.gd`: `MAX_PARTICLES` (512), `PARTICLE_GRAVITY`, `GRAVITY_JITTER` (0.15, ±15%
  per-particle multiplier on it), `BOUNCE_MIN_IMPACT_SPEED` (shared across liquid types — "how hard
  counts as hard," not a material property), `BOUNCE_CREEP_BLEND` (0.5, fraction of `creep_speed`
  blended into a bounce as tangential drift — see the bounce/creep paragraph below), `PARTICLE_COLOR_JITTER`,
  `PARTICLE_SCALE_JITTER_MIN`/`MAX` (0.7/1.3, render-only size multiplier), `CREEP_SPEED_JITTER`
  (0.2, ±20% per-particle multiplier on `profile.creep_speed`),
  `MAX_CREEP_REVERSALS`, `FLOOR_NORMAL_MAX_Y` (-0.1), `UPHILL_MIN_NORMAL_X` (0.1), `SLAG_PARTICLE_DAMAGE`
  (1, untuned). `PLAYER_PUSH_RADIUS` has had its pass: retuned from an initial 28px (which reached
  well past the player's own collider, pushing them from particles that weren't visibly touching
  them) down to 8px, close enough to the player's own half-width that a push now tracks actual
  contact. Still doubles as the hazard-contact radius for slag (see
  `_accumulate_push_and_hazard()`), which was the other half of why the old, looser radius needed
  fixing.
- `player.gd`: `swim_speed`/`swim_up_speed`/`swim_sink_speed`/`swim_gravity`/`swim_enter_depth`/
  `swim_exit_depth`/`swim_probe_offset_y` (values above), `SLAG_CONTACT_DAMAGE` (1, untuned).
- `basin.gd`: `crust_collision_layer` (default `1`) — must match whatever physics layer the real ground
  tiles use (it does; crust is solid to both player and particles). `CRUST_THICKNESS_TILES` (0.75) — the
  fixed crust thickness (matches the crust art; must stay well above ~0.5 so a standing player's swim probe
  can't end up below a paper-thin crust); `LIQUID_CONTACT_TOLERANCE_TILES` (0.05) — how far the liquid may sit below the crust's underside
  and still count as touching it. Neither has had an
  in-editor feel pass.

## Liquid types (water/slag/steam)

Generalization of the whole system above from water-only to multiple liquids, per the "minimal
bifurcation" design goal: one simulation, branching on a per-particle/per-basin `LiquidType` rather
than a second copy of the code. Everything in this section is verified in-editor.

**`liquid_constants.gd`** (renamed from `water_constants.gd`/`WaterConstants` — the particle size/
count/volume cascade is unchanged, just no longer water-specific in name): adds
`enum LiquidType { WATER, SLAG, STEAM }` and `LiquidConstants.profile(type) -> LiquidProfile`, a
per-type bundle of everything that used to be a flat constant — `creep_speed`, `bounce_restitution`,
`slope_slide_friction`, `push_force_per_tile_volume`, `color_base`, `is_hazardous`, `is_gas`,
`lifetime`. `PUSH_CAP`, particle size/count, and `PARTICLE_GRAVITY`/`BOUNCE_MIN_IMPACT_SPEED`/etc.
stay flat (shared, not material properties). `STEAM` is folded into the same enum rather than given
a separate flag specifically so particles' existing per-particle type slot covers it too, at no
extra array cost.

**`water_manager.gd`**: particles gained a `_liquid_type: PackedInt32Array`. Every place that read a
flat creep/bounce/friction/push constant now reads `LiquidConstants.profile(_liquid_type[i])`
instead — one simulation, not two. `spawn_particle()`/`spawn_melt_particles()` both take an optional
`liquid_type` (defaulting to `WATER`, so every existing water-only caller is unchanged).
`_try_absorb()` branches on the basin's state. On a crusted basin see "Crust" (nothing is absorbed;
an opposite-type particle evaporates into a steam puff on contact). On a crust-free
basin: if the basin is currently EMPTY (`fill_volume <= 0.0`), it's fluid-agnostic — the incoming
particle's type is written straight to `basin.liquid_type` before anything else, claiming the basin, so
the same-type branch below always runs for it. Otherwise: same type as the basin's own (now possibly
just-claimed) `liquid_type` → credits `fill_volume` (refused if the basin's already full); MISMATCHED
type → solidifies a `LiquidConstants.PARTICLE_VOLUME` slice of what's settled into the basin's first
crust via `basin.convert_to_crust()` and spawns a steam puff — deliberately NOT gated on `is_full()`,
since it's a reaction with whatever's already settled, not an absorption into remaining capacity. (The
old "basin has no settled liquid yet, so nothing to react with" case is now unreachable here — an empty
basin claims the particle's type above instead of ever reaching the mismatch branch — but the guard is
left in `_try_absorb()` as a defensive fallback.) A new `_accumulate_push_and_hazard()` (renamed from `_accumulate_push()`) does both jobs in
the same radius check: still sums push exactly as before, and additionally calls `player.take_hit()`
every frame a hazardous-type particle (slag) is in range — the same poll-every-frame posture
sawwheel.gd/crusher.gd already use, relying on `take_hit()`'s own i-frames rather than anything on
this end. `STEAM` particles (`is_gas` in their profile) skip collision/absorb/push/hazard entirely
via a small `_step_gas_particle()` branch early in the main loop — they just drift on their spawn
velocity (`spawn_steam_puff()` gives each one a random upward-biased direction) until a short
type-specific lifetime removes them; this is a decorative effect, not a simulated liquid.

**`basin.gd`**: `@export var liquid_type` is only the STARTING type — for a basin authored pre-filled
(`initial_fill_depth_below_surface` > 0) or meant to stay a fixed type. A basin that's actually empty at
runtime (`fill_volume <= 0` and no crust — whether never filled, or drained back to empty) is
fluid-agnostic: `WaterManager._try_absorb()` overwrites `liquid_type` with whatever arrives first, and
from then on the basin is committed to that type exactly as an authored one would be, until it's
drained empty again. Plus the crust state below; see "Crust" for that model —
`convert_to_crust()` is the only thing that creates it; a crust never grows or thins afterwards.

### Crust

Crust is **stored geometry**, not something derived from volumes: `has_crust`, `crust_top_row`,
`crust_bottom_row` (fractional tilemap rows, larger = lower). `crust_volume` still exists but is a
read-only getter — the volume of the band between the two faces, via the same
`_volume_for_surface_row()` machinery as every other height query — so it always follows the geometry.
Liquid, by contrast, is always floor-anchored: `get_liquid_surface_row()` is
`_surface_row_for_volume(fill_volume)` and is unaffected by crust.

Consequences:
- **Draining leaves the crust hanging.** `remove_volume()` only touches `fill_volume`; the crust's faces
  never move, so lowering the liquid opens a void (empty air, no vacuum modelling) between the liquid
  surface and the crust's underside. No crust redraw or collision rebuild is needed on a drain.
- **`get_surface_row()` is the OUTER surface**: `crust_top_row` when crusted, else the liquid surface.
  `get_crust_bottom_row()` is the crust's lower face, equal to the liquid surface when there is no crust.
  `is_full()` compares the outer surface to the spill row (without crust, plain
  `fill_volume >= _capacity_volume`; with crust, `crust_top_row` at the rim regardless of what's drained
  beneath it). `_max_fill_volume()` caps liquid at capacity, or — once crusted — at the volume below the
  crust's underside, since liquid can't lift the crust.
- **Formation (fixed thickness)**: `convert_to_crust()` on a crust-free basin with liquid sets `crust_top_row` to
  the liquid surface at that moment and `crust_bottom_row` to `CRUST_THICKNESS_TILES` (0.75) below it, all at
  once: `fill_volume` drops to the volume beneath the new underside, so the remaining liquid's surface meets the
  crust exactly. On a basin too shallow to hold 0.75 tile the crust is clipped at the seabed like any shape
  (thinner, and all the liquid becomes crust). An existing crust is never grown, thinned or moved: the call
  returns the amount untouched. `LIQUID_CONTACT_TOLERANCE_TILES` (0.05) still defines "touching" for
  `liquid_touches_crust()`, which now only drives the ripple and skin hiding.
- **Nothing is absorbed through crust.** `_try_absorb()`: on a crusted basin no particle is credited to the basin.
  An opposite-type particle reaching the crust's top face (water onto a slag basin's crust) is removed and
  spawns a steam puff, whether or not liquid touches the crust's underside; it changes nothing else, since the
  crust is fixed. Same-type liquid just rests on the crust's collision body like on any other registered solid.
- **No refill from above.** With crust present nothing adds to `fill_volume`, so a drained crusted basin
  stays drained; refilling from below (a reverse drain) is not implemented.
- **The void is sealed.** The crust spans every wet interior column, so a void is enclosed by the basin's
  wall columns, the crust and the liquid/seabed. Getting the player into one needs an entrance authored
  in the tilemap.

**Rendering**: `get_body_polygon_world()` traces the liquid from `get_liquid_surface_world_y()` down to
the real seabed (uncapped); `get_crust_polygon_world()` traces the crust between its two stored faces
(`get_crust_top_world_y()` to `get_crust_bottom_world_y()`, the latter passed as the cap so a column whose
seabed sits inside the band is clipped there). Both use the shared `_build_column_runs()`/
`_build_run_polygon()` helpers; the void between them is simply not drawn. `_draw_settled_body()` draws
crust after the liquid body. The crust is skinned too (`CRUST_SKIN_PATH_BY_TYPE`, frames glowing/wet → cold, chosen by the
liquid the basin holds, i.e. the one that solidified: `spsh_solidifying_steel.png` for slag,
`spsh_solidifying_water.png` for water, falling back to the slag crust art if a type's file is missing): the top face is snapped to a whole pixel for drawing (collision keeps the
exact value) and the art is the top layer. `LiquidSkin` is built for it with `cut_fringe`: the colours in each frame's first `NEUTRAL_ROWS` (4) opaque rows are that frame's neutral
palette, and every other opaque pixel is fringe (the liquid's colour along the bottom row, and a scatter of hot pixels that creeps up as the crust cools). In `texture` the fringe is
transparent, so what is drawn behind the crust shows through. While the liquid touches the crust's underside (`liquid_touches_crust()`) the settled body's fill extends up to
the crust's top face and the liquid's own surface art stays hidden, so the cut pixels read as the liquid glowing through and there is only one surface. Once a drain opens a gap the body drops
to its own surface (drawn with its surface art at the correct level) and `_draw_crust_strips()` draws `backed_texture` instead: fringe with a neutral pixel below it in its column is
inside the crust and is filled with the frame's neutral colour (`neutral_color()`, rounded to 8 bits so a flat rect matches the baked pixels), while fringe below a column's last neutral pixel
stays transparent. The underside over the void is therefore the art's own jagged edge (10 to 11 px of the 12 in the current art), never a flat fill down to the bottom face; a flat
neutral fill over the whole face makes the crust 1 to 2 px too thick. A column whose seabed lies at or above the crust's bottom face (within `CRUST_SEAT_TOLERANCE`, 0.5 px) is the exception:
it rests on the floor, so its strip gets a neutral rect down to the seabed first and shows no gap above the floor tile. The drawn underside sits 1 to 2 px above the collision's bottom face
(collision and every query still use the stored face). A newly
formed crust plays the frames in order over `CRUST_COOL_TIME` (2s) and holds the last; a restored crust is
already cold, and it is solid from the first frame either way.
Without the file it falls back to a flat `CRUST_COLOR`.

**Physical collision**: `_ensure_crust_body()` creates one `StaticBody2D` (group `"water_solid"`, so
liquid particles collide with/rest on it exactly like any other registered solid).
`_rebuild_crust_collision()`, called only from `convert_to_crust()`, gives it one rectangular
`CollisionPolygon2D` per crusted interior column, built independently from the stored faces rather than
the merged multi-column polygon — a merged run's stepped bottom edge is concave whenever neighboring
columns' seabed heights differ, and `CollisionPolygon2D`'s convex decomposition can fail outright on
that and silently leave the body with NO collision. A single rectangle per column is always four points
and already convex; **any future change to `_rebuild_crust_collision()` that goes back to feeding it a
merged/stepped polygon reintroduces this exact silent-collision-loss bug.** `crust_collision_layer`
(export, default `1`) must match whatever physics layer the real ground tiles use, so both the player's
floor detection and water particles' `tile_collision_mask` treat crust as solid.

### Drain queries (`basin.gd`)

- `is_floor_cell(cell: Vector2i)` — the cell is the floor tile of one of this basin's interior columns
  (`int(floor(floor_rows[col])) == cell.y`; whole for a full tile, fractional for a half/sloped one).
- `has_liquid_at_column(map_col)` — liquid currently lies over that interior column's floor
  (`get_liquid_surface_row() < floor_rows[col]`). Crust and void read false.
- `get_column_seabed_world_y(map_col)` — world y of the column's deepest floor point; `INF` outside the
  interior.
- `get_interior_column_count()` — how many open columns the basin has (width minus its two walls); 0 when
  it has no interior.
- `get_liquid_depth_at_interior_column(index)` — depth in tiles of still-liquid over the `index`-th interior
  column (0 = just inside the left wall) above that column's floor; 0 when there is none, the index is out
  of range or the basin is empty. Crust and void read 0. Both are read-only and are what `BasinSensor`
  reads (with `get_fill_fraction()`, `has_crust` and the runtime `liquid_type`).

**`player.gd`**: swim entry checks the probed basin's `liquid_type` first (`_water_probe_basin()`,
factored out of `_water_surface_depth()` so both share one probe, which reports no basin when the probe is
below the column's seabed). A hazardous basin (slag) never enters swim — instead
`take_hit(SLAG_CONTACT_DAMAGE, global_position)` fires every frame of submersion, `take_hit()`'s own
i-frames doing the same job they do for every other hazard. Passing the player's own position as
`from_position` (there's no single "point" a settled liquid hazard could knock the player away from)
relies on `take_hit()`'s existing "almost exactly on top of it" fallback, which backs the player away from
their current facing direction. Both this hazard check and ordinary swim entry read
`_water_surface_depth()`, which measures against `basin.get_liquid_surface_world_y()`, so a crust's solid
skin, and the void under it, read as dry.

**Steam** (`spawn_steam_puff()` on `WaterManager`): a small burst (`STEAM_PUFF_COUNT`, currently 4)
of `STEAM`-type particles at the contact point, each with a random upward-biased velocity
(`STEAM_PUFF_SPEED`). Purely decorative — dispersal is just each particle's own short
`STEAM_LIFETIME` running out, not any fade/alpha system. Fired once per water/slag contact event
alongside `convert_to_crust()`, from the same `_try_absorb()` branch.

**`faucet.gd`** — see "Sources" above. Its `liquid_type` export is what a SOURCE faucet drips (passed
straight through to `spawn_particle()`) and is otherwise ignored. A DRAIN reads `_drain_basin.liquid_type`
fresh on every drip rather than caching it at link-resolution time, so it stays correct across a basin
being drained empty and later reclaimed by a different liquid — the faucet needs no fluid-agnostic
handling of its own, it just always reports whatever the basin currently holds.

**Deferred, deliberately**: particle-vs-particle interaction (e.g. a water particle and a slag
particle meeting mid-air/mid-flow, not via a basin) is out of scope for now — no basin/settled-body
involved, no clear design for what it should do beyond "maybe they cancel out with a puff of steam,"
and nothing currently checks for it. Revisit once the basin-level reaction has actually been played
with.

Reads with: `liquid-system.md` (the short version), `player.md` (the swim state), `player-surf.md` (the surf water rules).
