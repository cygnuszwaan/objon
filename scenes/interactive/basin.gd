@tool
extends Node2D
class_name WaterBasin

# Authored basin marker — self-building with override (water-mechanic.md, "Decided" section).
#
# Place this node's origin at the basin's TOP-LEFT tile: the same row/column as the basin's
# leftmost wall column, one tile above (or level with) where the water surface is expected to sit.
# `width_tiles` (the whole basin footprint, INCLUDING its two bounding wall columns — e.g. a trough
# three tiles wide with a wall tile on each side is width_tiles = 5) is DETECTED by default: left at
# its default, `_rebuild()` scans rightward from this node's own row for the first wall tile and
# derives the width from that (see `_detect_width_by_wall_scan()`). Set `width_tiles` to a real
# number in the Inspector to override the scan by hand instead, the same authored-by-hand convention
# conveyor_belt.gd's `segments` uses.
#
# At edit time this samples the ground TileMapLayer underneath and derives, per column, the row of
# the topmost solid tile — same "surface_type" custom-data convention player.gd already uses
# (see _is_hangable_surface() in player.gd: a tile counts as solid ground here only if its
# surface_type is "ground"; "catwalk" tiles are ignored, since water passes straight through them).
# Column 0 and column (resolved_width_tiles - 1) are
# treated as the basin's two walls; everything between is open/interior water volume.
#
# STATUS (roadmap steps 1.1-1.4): floor-height derivation (1.1), spill-point derivation +
# per-instance overrides (1.2), debug draw (1.3), and the runtime fill scalar + query API (1.4) are
# all done. `_rebuild()` now runs once at runtime too, not just in the editor — it still skips the
# expensive tile-scanning derivation there and trusts the values baked in at edit time, but it does
# compute the small structural cache the runtime query API reads (surface height, column-in-range,
# full/not — see the bottom of this file). fill_volume itself is live state, mutated by
# WaterManager, not derived here at all.
#
# STATUS (roadmap step 2.3, WaterManager side): at runtime, _ready() now hands this basin's
# structural data to WaterManager via get_registration_data()/register_basin() — see both functions
# near the bottom of this file. Nothing downstream reads that registered data yet (Phase 3 doesn't
# exist), so this is currently a no-op from the player's perspective; only in-editor/console warnings
# (a missing WaterManager, or the tile-scan warnings _scan_column_floor() already had) would surface
# anything from this yet.
#
# STATUS (roadmap step 3.4): `get_spill_point_world()` has been REMOVED. It existed only to support
# spawning an overflow particle at an authored point, which Phase 3.4 turned out not to need — a full
# basin's particles now creep out along the surface on their own (see water-mechanic.md's 3.4 entry),
# using `get_surface_world_y()`, not a spill-point position. `spill_column` is UNCHANGED and still
# load-bearing: it's still what `_capacity_volume` (and therefore `is_full()`, and therefore where a
# full basin's water level sits) is computed from — it just no longer also doubles as a spawn
# location.
#
# STATUS (roadmap step 14): the debug-draw triangle that used to mark `spill_column` has been REMOVED
# (see `_draw_editor_debug_bounds()`). `spill_column` still exists purely as a tie-break convenience
# for the capacity math, but with which wall counts as "the" spill point no longer separately
# authorable, two equal-height walls are a normal, expected authoring shape, and
# water can creep out over either one; a marker singling out one wall as "the" overflow point was
# misleading in exactly that (common) case, so it's gone rather than fixed. Nothing about
# `spill_column`'s role in `_capacity_volume` changes — only its debug visualization is gone. In its
# place, the debug overlay now marks `initial_fill_depth_below_surface`'s starting waterline instead
# (see that field's own comment). The per-basin override that used to let an author pin
# `spill_column` to a specific wall is gone too, for the same reason the marker is: with overflow now
# just uncredited particles creeping off the surface in whichever direction is open (rather than a
# single designated drain point), there's no authoring case left for insisting on one wall over the
# other. `spill_column` itself is always auto-derived now (shorter/lower wall, tie favors the left —
# see `_update_spill_column()`).
#
# STATUS (roadmap step 5.1): this basin now draws its own settled-water body at runtime — originally
# a flat-bottomed rectangle from the current surface line down to the flat floor reference, spanning
# the interior (open-water) columns only; superseded by Phase 10.3 below, which traces the real
# per-column floor instead. `get_body_polygon_world()` is the shape query (see its own comment for
# why it's kept separate from the height/volume query methods above it), `_draw()` dispatches to
# either that or the pre-existing editor-only debug overlay depending on Engine.is_editor_hint() —
# these are two different things drawn by the same callback, not one growing into the other: the
# debug overlay is a dev tool (bounds/floor-height/spill-column, gated off at runtime by design —
# see "Debug visualization" in water-mechanic.md, which explicitly rules out a runtime fill overlay
# for TOOLING purposes), while the settled body is the actual player-visible water. `z_index` is set
# below `_world_tilemap`'s own (see `_rebuild()`) so the body renders behind the ground tiles per the
# "Sloped/half-height basin floors" decision, hiding any mismatch on a sloped/half-height floor tile
# under the opaque tile art rather than resolving it — this mismatch is now much smaller since Phase
# 10.1, but the draw-behind-tilemap choice is kept unconditionally rather than only for the tiles
# still imperfectly represented, since there's no cheap way to tell those apart at draw time.
#
# STATUS (roadmap steps 10.1-10.3): the flat per-basin floor approximation is replaced with real
# per-column geometry, in the shape the "Accurate basin floor mapping" v2 goal called for.
# (10.1) `floor_rows` is now `Array[float]`, not `Array[int]` — each column's value is still derived
# from the topmost tile whose `surface_type` tag reads as ground (that gate is unchanged),
# but now carries a fractional offset sampled from that specific tile's own physics-layer collision
# polygon (`_sample_tile_floor_offset()`), so a half-height or sloped tile contributes where its
# actual solid surface sits within the tile instead of being read as fully solid from the tile's top
# edge. A fully-solid tile still yields a whole-number row, identical to pre-10.1 behavior, so this
# is a strict refinement, not a behavior change, for every tile the basin's test level used before.
# The sample is taken at each column's horizontal center — still one scalar per column, not a
# continuous sub-tile curve — so a diagonal ramp tile's contribution is its height at the column's
# midpoint, not its min/max across the column. Override columns (`floor_row_override_enabled`) are
# unaffected: an override is still a whole-tile row offset, authored, not sampled.
# (10.2) `get_surface_row()`/`get_surface_height_tiles()` no longer divide `fill_volume` by the flat
# `_footprint_width`. `_update_runtime_query_cache()` now also builds a small per-basin cache
# (`_sorted_interior_floor_rows`, `_cum_volume_at_level`) of the interior columns' `floor_rows`
# sorted deepest-first, with the cumulative cross-section volume at each column's own floor level —
# a shallow column only starts holding volume once the rising surface reaches its own floor, exactly
# like a real basin with an uneven bottom, rather than every interior column filling in lockstep.
# `_surface_row_for_volume()` walks that cache to invert volume -> surface row. `_capacity_volume`
# is computed the same way now (volume needed to reach the spill column's floor via the real
# per-column sum, not the flat `(_basin_floor_row - spill_row) * _footprint_width`) — kept
# consistent with the same integration `get_surface_height_tiles()` now uses, since a capacity
# computed by the old flat formula would no longer agree with is_full()/get_fill_fraction() against
# the new accurate height. This is a superset of the roadmap's own 10.2 note, which only named the
# height query explicitly; consistency between the two seemed worth the extra few lines rather than
# leaving a straight edge where the flat and real math would otherwise visibly disagree right at a
# full basin's spill point.
# (10.3) `get_body_rect_world()` is REMOVED, replaced by `get_body_polygon_world()`, returning
# stepped polygons (flat top at the current surface line, a staircase bottom edge tracing each
# interior column's own floor height) instead of a flat-bottomed rectangle. `_draw_settled_body()`
# now draws them.
#
# REFINEMENT: the polygon's per-column height comes from a new `seabed_floor_rows`, sampled
# separately from `floor_rows` (see that field's own comment) — `floor_rows` samples each tile's
# collision polygon at the column's horizontal CENTER (the right choice for gameplay height/volume),
# but center-sampling a sloped tile for the DRAWN seabed left a visible gap between the water body
# and the real ground at the slope's lower edge. `seabed_floor_rows` instead takes the deeper of that
# tile's own TOP SURFACE at its left edge versus its right edge (`_sample_tile_seabed_offset()`,
# sharing a `_tile_top_surface_local_y()` helper with the center sampler), so the drawn bottom edge is
# never shallower than the real floor at either edge: at worst it over-draws slightly into solid
# ground at the slope's shallow edge, which is invisible since the settled body draws behind the
# tilemap anyway. An earlier version of this sampled the tile's single deepest VERTEX instead of
# probing edges' top surfaces specifically — caught in review as broken for a tile like a floating
# diagonal ledge (a thin solid band with open space both above and below it): the ledge's underside
# is a real vertex that sits deeper than either edge's actual top surface, so that version drew the
# seabed all the way down near the tile's bottom, visibly floating below the ledge with a gap between
# the drawn water and the ledge's real surface. Two arrays doing two different jobs from the same
# underlying tile data, not one array serving both — the same separate-query-methods principle the
# "Accurate basin floor mapping" v2 goal already asked for between the height query and the shape
# query now applies one level deeper, within the shape query's own sampling.
#
# BUG FIX (caught in-editor, first real playtest of Phase 10): `get_body_polygon_world()` originally
# still built ONE contour across every interior column, clamping a not-yet-submerged column's bottom
# point up to the surface line so it wouldn't poke above it — correct at either END of the wet
# stretch, but a column in the MIDDLE of the interior (a hump the rising water hasn't covered yet)
# got clamped too, pinching the whole contour to zero height at that point. Godot's triangulator
# rejects a self-touching contour like that outright ("Invalid polygon data, triangulation failed"),
# and since triangulation is all-or-nothing per contour, nothing drew anywhere in the basin — not
# just near the hump — until the fill rose enough to cover it. `get_body_polygon_world()` now returns
# `Array[PackedVector2Array]`: it walks columns left-to-right, splits the interior into maximal
# contiguous runs of columns actually below the current surface, and emits one separate, well-formed
# polygon per run — a dry hump is excluded rather than clamped, so a pinch can no longer happen.
# `_draw_settled_body()` draws each returned polygon. Purely a drawing-layer fix: this basin still has
# exactly one flat surface line and one `fill_volume`, same as 10.2's math already computes; a hump
# merely means the drawn water can be more than one visible piece at some fill levels.
#
# **`floor_rows`/`spill_column` must stay `@export_storage` (or `@export`), never a plain `var`** —
# a plain var is never written into a saved .tscn at all, so a runtime instance would silently start
# with floor_rows == [] / spill_column == OVERRIDE_NONE regardless of what the editor derived,
# making every runtime query read "empty and always full" no matter how the basin actually looks in
# the editor. This bit exactly these two fields during 1.4's first in-editor test — the same mistake
# would bite any future editor-only-derived field this script grows, if it's ever added as a plain
# var instead of @export_storage.
#
# Overrides: `floor_row_override_enabled` (bool) + `floor_row_overrides` (int) are a matched pair of
# per-column arrays (auto-kept in sync with width_tiles) — a column is overridden only where the
# first is true, and its value in the second is then a LOCAL row offset from this node's own origin
# row, the same numbers the debug draw already shows you. Both default to "no override" and are
# optional, per the "self-building with override" decision. See the comment on floor_row_overrides
# below for how this arrived at a two-array split rather than one array or a dictionary.
# (`spill_column` has no per-basin override any more — see its own comment below.)
#
# UNVERIFIED ASSUMPTION, still flagged: this treats the basin's two EDGE columns as its walls and
# everything between as open interior. That matches a basin shaped like a simple U-trough with a
# wall tile at each end, which is the common case, but won't hold for a more irregular basin shape.
# Revisit if a real level needs something the edge-column assumption can't express.

const MAX_SCAN_TILES := 64
	# how many tiles a column scan looks down before giving up and assuming there's no floor —
	# generous enough for any basin depth this game is likely to have; a warning fires if a column
	# genuinely has no solid tile within this range, which usually means the basin was placed over
	# open air by mistake.

const NO_INITIAL_FILL := -1.0
	# sentinel for initial_fill_depth_below_surface meaning "not authored, start empty" — the default
	# for every basin before this field existed and the default for one that doesn't care about it.
	# Deliberately NOT 0.0: 0.0 is already a meaningful, common value here (start completely full to
	# the brim), so it can't double as "unset" the way it does for some fields elsewhere. Any negative
	# value is treated as unset (see _initial_fill_volume()) — depth can't legitimately be negative, so
	# "negative" is free to mean "unset" without a separate enabled flag, the same reasoning
	# OVERRIDE_NONE uses below for spill_column.

const OVERRIDE_NONE := -1
	# sentinel meaning "not yet derived" for the live spill_column state (see _update_spill_column()).
	# -1 is never a valid column index, so it can't collide with a real value. (floor_row_overrides
	# below uses a separate enabled-flag array instead of a sentinel — see why there.)

const WIDTH_AUTO := -1
	# sentinel for width_tiles meaning "not manually authored — detect it instead" (see
	# _detect_width_by_wall_scan() and width_tiles' own comment). -1 is never a valid width (the
	# minimum is 2, the two wall columns), same reasoning OVERRIDE_NONE uses above.

const ELECTRIC_REACH := 1.0  # px: a spark whose lowest point is within this of the surface (or below it) has touched it
const ELECTRIC_SPLASH_VELOCITY := -90.0  # px/s: the cosmetic ripple kick at the strike (negative = a dip, as a diving swimmer's)
const ELECTRIC_FADE_TIME := 0.25  # s: the flash tapers off over the last of the electrified time
const ELECTRIC_FLICKER_HZ := 24.0
const ELECTRIC_TINT_DEPTH_TILES := 6.0  # the tint covers at most this far below the surface, so a deep pool does not turn solid cyan
const ELECTRIC_CORE := Color(0.85, 1.0, 1.0)
const ELECTRIC_GLOW := Color(0.35, 0.8, 1.0)
const BODY_COLOR_BY_TYPE := {
	# Phase 5.1's settled-liquid color, one flat/opaque value per LiquidType — generalized from a
	# single BODY_COLOR now that a second liquid exists. Each is a flatter, more opaque version of
	# that type's own LiquidConstants.profile().color_base (which is tuned for the flowing/jittered
	# particle look, not a solid settled mass). Placeholder pending a real art pass — no color/palette
	# decision has been made yet for either liquid's settled look, this is just "readably water" /
	# "readably slag" for now.
	LiquidConstants.LiquidType.WATER: Color(0.18, 0.45, 0.75, 0.95),
	LiquidConstants.LiquidType.SLAG: Color(0.75, 0.28, 0.08, 0.95),
}
const SKIN_BY_TYPE := {
	LiquidConstants.LiquidType.WATER: {"path": "res://sprites/liquids/spsh_water.png", "fps": 6.0},
	LiquidConstants.LiquidType.SLAG: {"path": "res://sprites/liquids/spsh_molten_steel.png", "fps": 4.0},
}
	# Top-of-liquid art per liquid type (16px frames stacked vertically, one tile tall, tileable sideways only;
	# see LiquidSkin): the art is the surface layer and the body below it is filled with the art's bottom-row
	# colour. `fps` is the loop speed — water runs faster than slag so it reads as less viscous. A type with no
	# entry, or whose file is missing, keeps its flat BODY_COLOR_BY_TYPE colour.
const CRUST_SKIN_PATH_BY_TYPE := {
	LiquidConstants.LiquidType.WATER: "res://sprites/liquids/spsh_solidifying_water.png",
	LiquidConstants.LiquidType.SLAG: "res://sprites/liquids/spsh_solidifying_steel.png",
}
	# Top-of-crust art, chosen by the liquid the basin holds (the one that solidified), so each can cool from its
	# own colour (16px frames, glowing/wet -> cold). A new crust plays the frames in order over CRUST_COOL_TIME
	# seconds and holds the last one; the body under the top layer follows the current frame's bottom-row colour.
	# Collision is unaffected: crust is solid from frame 0. A type whose file is missing falls back to the SLAG
	# crust art, and with none at all to the flat CRUST_COLOR below.
const CRUST_COOL_TIME := 2.0
const CRUST_SEAT_TOLERANCE := 0.5
	# px: a column whose seabed lies within this of the crust's bottom face (or above it) counts as resting on the floor when the
	# crust is drawn over a void, so its underside is filled down to the seabed (see _draw_crust_strips()).
const CRUST_COLOR := Color(0.35, 0.32, 0.3, 1.0)
	# Solidified crust's color — a dull, opaque, liquid-agnostic gray-brown rather than a
	# darker/cooled version of whichever liquid formed it: crust reads the same regardless of whether
	# it came from water hitting slag or slag hitting water, since it's meant to visually communicate
	# "safe solid ground," not "which liquid used to be here." Placeholder pending a real art pass,
	# same as BODY_COLOR_BY_TYPE above.

# --- Frozen crust (the freeze ray, roadmap N3.2) ---------------------------------------------------
const FROZEN_CRUST_SKIN_PATH := "res://sprites/liquids/spsh_freezing.png"
	# Cooling art of a FROZEN crust: the same frames as the slag/water crust art in another palette (liquid blue to pale
	# ice), read through the same LiquidSkin fringe cut. Used for both liquids. A missing file falls back to the liquid's
	# own crust art, and with none at all to FROZEN_CRUST_COLOR.
const FROZEN_CRUST_COLOR := Color(0.62, 0.82, 0.95, 1.0)
const FROST_DECAY_PER_SEC := 1.0
	# Seconds of frost (freeze ray) or heat (laser on a frozen crust) lost per second once the beam has left. Frost builds
	# at one second per second of beam, so a target loses what it gained at the same rate. Not authored: tuned here.
const BEAM_GRACE_FRAMES := 2
	# A beam hit this many physics frames ago or less still counts as on (the laser receiver's LIT_FRAMES), so the order the
	# turret and this basin are processed in never matters.
const THAW_GRACE_FRAMES := 4
	# A temporary frozen crust (frozen slag, LiquidProfile.frozen_is_temporary) thaws once this many physics frames have
	# passed since a freeze beam last ended on it (or since it formed, while the beam is first finding the new collision):
	# long enough that the order the turret and this basin run in never matters, short enough to read as "as soon as".
const FROZEN_STAND_TOLERANCE := 3.0
	# px: how far a player's feet may be above or below a frozen crust's collision top and still count as standing on it
	# (what the electrified-crust hazard asks).

@export var liquid_type: LiquidConstants.LiquidType = LiquidConstants.LiquidType.WATER
	# Which liquid this basin holds — determines what add_volume()/fill_volume actually mean for this
	# basin, what BODY_COLOR_BY_TYPE draws it as, and what a particle's OWN LiquidConstants.LiquidType
	# has to match to be absorbed as ordinary fill rather than triggering the crust reaction below.
	# STEAM is never a valid value here (no basin is ever authored to hold it); nothing currently
	# enforces that in the Inspector.
	#
	# This export is only the STARTING value, for a basin authored pre-filled (via
	# initial_fill_depth_below_surface) or as a fixed source/sink that's never meant to change. A
	# basin that is actually empty at runtime — fill_volume <= 0 and no crust, whether that's from
	# never having been filled or from having been fully drained — is fluid-agnostic: see
	# WaterManager._try_absorb(), which overwrites this the moment the first particle settles into it,
	# claiming the basin for whatever liquid arrived first. Once it holds anything (or has a crust),
	# it's committed to that type again exactly as before, mismatches trigger the crust reaction, until
	# it's drained back to empty.

@export var crust_collision_layer: int = 1
	# Physics layer the crust's walkable StaticBody2D sits on (see _ensure_crust_body() below) —
	# UNVERIFIED placeholder value; needs to actually match whatever physics layer world_tilemap's
	# real ground tiles use, so the player's floor detection and water particles' tile_collision_mask
	# both treat crust as ordinary solid ground rather than something invisible to one or the other.
	# Exposed as an export (rather than a hardcoded constant) specifically so this can be corrected
	# per-project without a code change once the real ground layer number is confirmed.

@export var width_tiles: int = WIDTH_AUTO:
	set(value):
		width_tiles = WIDTH_AUTO if value == WIDTH_AUTO else maxi(2, value)  # need at least the two wall columns
		_sync_override_array_size()
		_rebuild()
	# Left at its default (WIDTH_AUTO), the basin's width is DETECTED rather than authored: at edit
	# time, _rebuild() scans rightward from this node's own column, at this node's own row, for the
	# first solid ("ground") tile — see _detect_width_by_wall_scan() for the method and why
	# that row specifically. That covers the common case (a simple U-trough with a wall tile at each
	# end) with no authoring step at all. Set to a real width (>= 2, including both wall columns —
	# e.g. a trough three tiles wide with a wall tile on each side is width_tiles = 5) to override the
	# scan by hand, the same way floor_row_overrides overrides a single column's sampled floor: for a
	# basin shape the scan can't find a wall for (no tile within MAX_SCAN_TILES) or shouldn't be
	# trusted to find (an irregular footprint, a deliberately short/long span). resolved_width_tiles
	# below is what the rest of this file actually reads — see its own comment for why this field and
	# that one had to end up separate.

@export var world_tilemap_path: NodePath:
	set(value):
		world_tilemap_path = value
		_world_tilemap = get_node_or_null(value) as TileMapLayer if value != NodePath() else null
		_rebuild()
		# Was missing entirely before — assigning the tilemap in the Inspector silently did nothing
		# until width_tiles was also touched. Fixed: this now rebuilds immediately, same as
		# width_tiles's own setter.

@export var floor_row_override_enabled: Array[bool] = []:
	set(value):
		floor_row_override_enabled = value
		_rebuild()
@export var floor_row_overrides: Array[int] = []:
	set(value):
		floor_row_overrides = value
		_rebuild()
	# Two parallel per-column arrays, both auto-kept exactly resolved_width_tiles long (see
	# _sync_override_array_size()): a column is overridden only where _enabled is true, and its
	# value is then a LOCAL row offset from this node's own origin row — the same numbers the debug
	# draw already shows you — NOT an absolute tilemap row.
	#
	# Third attempt at this mechanism, each worth knowing about if it ever needs revisiting again:
	# (1) originally used absolute tilemap rows, meaningless to eyeball from the editor. (2) tried a
	# sparse Dictionary (column -> offset) to avoid a sentinel/length-sync entirely, but the
	# Inspector's Dictionary key/value type picker didn't reliably produce entries this script's
	# comparisons could see — root cause unconfirmed, reverted rather than debugged blind. (3) a
	# single Array[int] with a giant sentinel value (2147483647) for "no override" worked correctly,
	# but every un-overridden slot then showed that number by default, which is confusing/ugly to
	# author against even though it's functionally harmless. This two-array split removes the
	# sentinel entirely: an unused slot now just shows `false` / `0`, both unremarkable defaults.

@export var initial_fill_depth_below_surface: float = NO_INITIAL_FILL:
	set(value):
		initial_fill_depth_below_surface = value
		queue_redraw()
	# Roadmap step 14: lets a level designer author a basin that's already settled and full (or
	# partway full) of water the moment the scene loads — a lake that's simply there, not something
	# melt/faucet/overflow has to fill up during play. Left at NO_INITIAL_FILL (see that constant's own
	# comment), a basin behaves exactly as it did before this field existed: starts empty. Set to 0.0
	# or higher, it's a DEPTH IN TILES BELOW THIS BASIN'S OWN FULL SURFACE (the row the water would sit
	# at if the basin were topped up to its spill point): 0.0 means "start full," larger values mean
	# "start this many tiles short of full" — a level designer thinks in the same up/down terms they'd
	# use to eyeball a lake in the editor, not in the basin's internal tile-area cross-section units,
	# and this stays correct on a basin with an uneven floor (a wide basin and a narrow one need
	# different volumes to each sit N tiles below full, but the same depth value expresses "N tiles
	# below full" for both). `_initial_fill_volume()` converts this to the actual volume `add_volume()`
	# wants, once, right before it's used — see that function's own comment for the conversion. This
	# field only ever seeds `fill_volume` once at load; it is never touched again afterward and has no
	# bearing on how the basin fills or drains during play. In the editor it drives nothing but the
	# waterline tick in `_draw_editor_debug_bounds()` below — `fill_volume` itself stays 0 in the
	# editor (it's live runtime state, not `_rebuild()`-derived), so this is the only way to preview
	# where an authored starting level will actually sit before pressing play.

## Laser boiling (roadmap 5.4), opt-in: a LaserTurret with `boils_water` on boils this basin's liquid where its beam
## crosses it, but only if this is on too (both flags must be true) and the basin currently holds WATER (slag is never
## boiled; read at runtime, so it follows whatever liquid claimed an empty basin). Authored only: runtime code reads it.
@export var boilable: bool = false
## How fast boiling drains the pool, as a multiple of WaterManager.BOIL_DRAIN_VOLUME_PER_SEC: 0 boils (and steams) with
## no volume loss, 1 is nominal, above 1 exaggerates it. Steam output does not depend on it. At nominal a pool is a
## finite supply; a faucet refilling it settles where the beam meets the surface.
@export_range(0.0, 10.0, 0.05, "or_greater") var boil_volume_scale: float = 1.0
## Electrified water (on by default): a Spark (see rail_bot.gd) that reaches this basin's settled WATER surface
## electrifies the whole pool for `electrified_time` seconds. While electrified the liquid hurts the player like slag
## does (every frame submerged, paced by take_hit()'s i-frames) and a surfer can't skim it. Turn this off for a pool
## sparks should pass over untouched (they then fall through it as before). Authored only: runtime code reads it.
@export var conducts_sparks: bool = true
## How long one spark's zap keeps the pool electrified, in seconds. A later spark restarts the countdown rather than
## adding to it. Placeholder pending tuning against a rail bot's `drip_interval` (1.6 s by default).
@export_range(0.1, 5.0, 0.05, "or_greater") var electrified_time: float = 1.0
## Freeze ray (roadmap N3.2), opt-in: a FreezeTurret's beam freezes this basin's liquid (water or slag) where it crosses
## it, but only if this is on. Authored only: runtime code reads it. `freeze()` itself does not check it.
@export var freezable: bool = false
## Seconds of sustained freeze beam on this basin before it freezes (a beam that leaves loses its frost at
## FROST_DECAY_PER_SEC). Authored only.
@export_range(0.05, 30.0, 0.05, "or_greater", "suffix:s") var freeze_time: float = 2.0
## Seconds of sustained laser on a FROZEN crust before the whole crust thaws (a reaction crust is never melted). Authored only.
@export_range(0.05, 30.0, 0.05, "or_greater", "suffix:s") var melt_time: float = 2.0
## How far, in px, the drawn liquid and crust extend behind each wall column (rounded down to whole 4px strips, capped at one tile). Lets a wall sprite keep transparent padding on its open face without a gap showing between it and the settled liquid. Drawing only: collision, queries and the polygon shape queries are unchanged.
@export_range(0.0, 16.0, 1.0) var wall_overlap_px: float = 8.0
@export var debug_check_body: bool = false  ## Runtime diagnostic: warns whenever the old polygon form of the liquid body would have failed to triangulate (see _draw_settled_body()). Off = no cost.
@export var debug_draw_bounds: bool = true:
	set(value):
		debug_draw_bounds = value
		queue_redraw()
	# Editor-time-only overlay, same convention as conveyor_belt.gd's debug_draw_bounds: outlines
	# the derived column range and marks each column's floor height so the @tool derivation above
	# can be visually confirmed before pressing play. Nothing is drawn at runtime (see _draw()).

var _world_tilemap: TileMapLayer
var _origin_cell: Vector2i = Vector2i.ZERO  # cached each rebuild; used by both _rebuild() and _draw() so they can't disagree, same reasoning as the conveyor's shared _segment_layout()
var _tile_size: Vector2 = Vector2(16, 16)   # cached each rebuild from the tilemap's TileSet, reused by _draw()

@export_storage var resolved_width_tiles: int = 2
	# The basin's actual footprint width, INCLUDING both wall columns — what every other structural
	# field/query in this file (floor_rows' size, _footprint_width, is_column_in_range(), the debug
	# draw, ...) reads, as opposed to width_tiles itself, which is the AUTHORED field and may be left
	# at WIDTH_AUTO. Derived once per edit-time _rebuild(): copied straight from width_tiles when it
	# holds a manual override, or from _detect_width_by_wall_scan() when width_tiles == WIDTH_AUTO.
	# Kept as its own field, separate from width_tiles, for the same two reasons floor_rows/
	# spill_column are already split into "authored/live value" vs "@export_storage derived cache":
	# (1) @export_storage persistence — a fresh runtime instance never re-runs the tile scan, so the
	# result has to be serialized into the saved scene rather than recomputed, same as floor_rows; a
	# plain runtime var here would silently reset to the class default every time the scene loads.
	# (2) writing the resolved value back into width_tiles itself, from inside _rebuild(), would
	# re-enter width_tiles' own property setter (which itself calls _rebuild()) — width_tiles' setter
	# needs to stay free to run before _world_tilemap/_origin_cell are ready (same reasoning
	# world_tilemap_path's setter comment already covers), so the scan has to happen, and land, INSIDE
	# _rebuild() rather than in reaction to whatever value width_tiles happens to hold. Defaults to 2
	# (an empty, wall-only footprint) before the first successful rebuild, same spirit as floor_rows
	# defaulting to [] and spill_column defaulting to OVERRIDE_NONE.

@export_storage var floor_rows: Array[float] = []
	# Per-column floor height, one entry per column in [0, resolved_width_tiles), in tilemap row
	# coordinates (the tilemap's own map-space row index — NOT local to this node). Column 0 and
	# resolved_width_tiles - 1 are the wall columns; the rest are interior/open columns. This is the
	# DERIVED-OR-OVERRIDDEN value (floor_row_overrides already folded in) — nothing downstream needs to
	# know which source a given column's value came from. Consumed by WaterManager's basin-registration
	# pass (roadmap step 2.3).
	#
	# Array[float], not Array[int], since Phase 10.1: a column's value is a whole number only when
	# its floor tile is fully solid from the top; a half-height or sloped tile contributes a
	# fractional row instead (see _sample_tile_floor_offset()). An overridden column is still always
	# a whole number, since floor_row_overrides itself is authored as a whole-tile offset.
	#
	# @export_storage (not a plain var): this is derived by the expensive editor-only tile scan in
	# _rebuild(), so a fresh runtime instance has no way to recompute it and MUST have the editor's
	# last-computed value serialized into the saved scene instead. A plain var is never written into
	# a .tscn at all — the editor's live @tool derivation only ever exists in the editor's own
	# process, so a runtime instance loaded from a scene saved before this was exported would
	# silently start with floor_rows == [] regardless of what the editor showed. `@export_storage`
	# persists it like a normal @export without cluttering the Inspector with a field nobody should
	# hand-edit (needs Godot 4.3+; on an older engine, swap for a plain `@export` instead — visible in
	# the Inspector, but persists the same way).

@export_storage var seabed_floor_rows: Array[float] = []
	# Phase 10.3 refinement: a SEPARATE per-column sample from floor_rows above, used only by
	# get_body_polygon_world()'s drawn seabed — never by the height/volume math (get_surface_row()/
	# get_surface_height_tiles()/_capacity_volume all still read floor_rows, untouched by this field).
	# floor_rows samples each tile's collision polygon at the column's horizontal CENTER; this instead
	# takes the LOWER (deeper) of that same tile's own TOP SURFACE height at its left edge versus its
	# right edge (_sample_tile_seabed_offset()) — since a column is exactly one tile wide, "this
	# tile's left/right edges" are exactly the column's own left/right boundaries, no separate
	# per-column x-range bookkeeping needed. The two deliberately disagree on a sloped tile:
	# center-sampling is the right choice for gameplay height/volume (matches the player-facing "how
	# full is this basin" number to the tile's typical solid line, not its worst case), but for the
	# DRAWN seabed, a center sample left a visible gap between the drawn water body and the real
	# ground at a slope's lower edge — nothing was drawn there to cover it. Sampling the worse of the
	# two edges instead means the drawn polygon's bottom edge is never shallower than the real floor
	# at either edge of the column: at worst it over-draws slightly into solid ground at the slope's
	# shallow edge, which is invisible anyway (the settled body draws behind the tilemap — see
	# `z_index` in `_rebuild()`). A hidden overlap beats a visible gap, hence the bias.
	#
	# Specifically the TOP surface at each edge, not just any vertex there (an earlier version of
	# this sampled the tile's single deepest vertex overall, which broke on a tile like a floating
	# diagonal ledge — a thin solid band with open space both above AND below it: the ledge's
	# underside is a real vertex of the polygon and sits deeper than either edge's actual top surface,
	# so that version drew the seabed all the way down near the tile's bottom, well below the ledge
	# itself — visibly floating water sitting in the empty space beneath the ledge with a gap between
	# it and the ledge's real surface. Probing each edge's top surface specifically can't pick up an
	# underside no matter how deep it sits, since only the first solid boundary encountered from above
	# counts as "the top surface" there.
	#
	# Same @export_storage reasoning as floor_rows (see its own comment) — derived by the same
	# editor-only tile scan, so a runtime instance needs it serialized rather than recomputed.

@export_storage var spill_column: int = OVERRIDE_NONE
	# Which column (index into floor_rows) water spills over first once the basin is full — the
	# shorter/lower of the two wall columns, i.e. the one with the LARGER floor_rows value (a larger
	# tilemap row index sits physically lower, so it's the wall that's easier to overflow). Always
	# auto-derived — see _update_spill_column(). OVERRIDE_NONE until the first successful rebuild.
	# @export_storage for the same reason as floor_rows above — see its comment.

var fill_volume: float = 0.0
	# Live basin volume, in tile-AREA units (this is a 2D side-on game, so "volume" really means the
	# cross-sectional area a flat-bottomed fill would occupy): 1.0 = one full tile's height spread
	# across the basin's whole interior width. Distinct from the structural fields below — this is
	# the one piece of basin state that changes every frame during play, per "Basin fill state" in
	# water-mechanic.md, while everything else here is load-time-derived and frozen once the level
	# starts. Starts at 0 on every level load (this node is per-level, not an autoload — see
	# "Manager placement"). Only ever mutated through add_volume()/remove_volume()/convert_to_crust()
	# below so it can never drift outside [0, _max_fill_volume()]; nothing else should
	# assign to it directly. Basin code never touches LiquidConstants.PARTICLE_VOLUME itself (see
	# scripts/liquid_constants.gd) — it just deals in raw volume amounts; particle-to-volume conversion
	# is the caller's job (Phase 3.3's absorb step, Phase 3.4's overflow spawn).

var has_crust: bool = false
	# True once a water/slag reaction has formed a crust in this basin. The crust is STORED
	# geometry, not something derived from volumes: `crust_top_row`/`crust_bottom_row` below are its
	# two faces, set by convert_to_crust() and never moved by anything that happens to
	# `fill_volume` afterwards. Crust is a rigid, set-hard solid fused to the basin — draining the
	# liquid underneath leaves it hanging over empty space (a void), and nothing refills that void
	# from above (see WaterManager._try_absorb()).

var crust_top_row: float = 0.0
var crust_bottom_row: float = 0.0
	# The crust's upper and lower faces as fractional tilemap rows (same convention as
	# get_surface_row(); a larger row is physically lower). Only meaningful while `has_crust` is
	# true. A column carries crust only where its own seabed sits below `crust_top_row` (clipped at
	# `crust_bottom_row`), so a dry hump the liquid never covered simply has none.

var crust_volume: float:
	get:
		# Derived, for anyone who wants the crust's size in the same tile-area units as
		# fill_volume: the band between its two faces, via the same per-column volume<->row
		# machinery every other height query uses. Read-only in practice — geometry is the source
		# of truth, this follows it.
		if not has_crust or _footprint_width <= 0:
			return 0.0
		return maxf(0.0, _volume_for_surface_row(crust_top_row) - _volume_for_surface_row(crust_bottom_row))

var crust_frozen: bool = false
	# True when `has_crust` is a FROZEN crust (formed by freeze(), not by the water/slag reaction). Saved. A frozen crust has
	# its own skin, a laser thaws it (thaw()), and an arc or spark can electrify it; a reaction crust does none of these.
var _frost: float = 0.0  # seconds of freeze-beam contact so far; runtime only, rises while the beam is on, decays after
var _frost_hit_frame: int = -1000
var _heat: float = 0.0  # seconds of laser contact on a frozen crust so far; runtime only
var _heat_hit_frame: int = -1000
var _freeze_hold_frame: int = -1000  # physics frame a freeze beam last ended on a temporary frozen crust (or it formed); runtime only
var _embedded: bool = false
	# Runtime only. True from a freeze that found the player inside the crust band or under the surface until the player is
	# above the crust's top face: the crust body ignores the player (add_collision_exception_with()) for that long, the player
	# swims through the band as if it were water (get_swim_surface_world_y()), and is chilled while in it.
var _crust_body: StaticBody2D = null
	# Runtime-only walkable collision for this basin's crust (see _ensure_crust_body()/
	# _rebuild_crust_collision() below) — null in the editor and for the entire life of any basin
	# which never forms a crust.

# --- Skim floor (a surfing player, see player.gd) -----------------------------------------------------
# A thin one-way StaticBody2D laid flat on the settled liquid's surface, only while a surfer asks for it. It sits on
# physics layer 3 (bit value 4), which only the player's mask includes: particles (mask 1|2) and rigid blocks
# (mask 1|2) never see it, and it is not in "water_solid". The one-way margin lets a board whose feet are a few px
# under the line still be caught. The surface it follows is the flat liquid line (get_liquid_surface_world_y()), not
# the cosmetic ripple.
const SKIM_FLOOR_LAYER_BIT := 4
const SKIM_FLOOR_THICKNESS := 8.0
const SKIM_FLOOR_EDGE_OVERLAP := 2.0  # px past each interior edge, into the wall columns, so a full basin's floor meets the wall tops without a seam
var _skim_body: StaticBody2D = null
var _skim_shape: CollisionShape2D = null

func set_skim_floor(active: bool, catch_depth: float = 6.0) -> void:
	# Raises (active) or drops the skim floor. Raising it also re-places it on the current surface, so call it every
	# frame while a surfer is over the basin; dropping it just takes it off every layer. Runtime only.
	if Engine.is_editor_hint():
		return
	if not active:
		if _skim_body != null:
			_skim_body.collision_layer = 0
		return
	var interior_width := float(resolved_width_tiles - 2) * _tile_size.x
	if interior_width <= 0.0:
		return
	if _skim_body == null:
		_skim_body = StaticBody2D.new()
		_skim_body.name = "SkimFloor"
		_skim_body.top_level = true  # world-space placement, independent of this node's transform
		_skim_body.collision_layer = 0
		_skim_body.collision_mask = 0
		_skim_shape = CollisionShape2D.new()
		_skim_shape.shape = RectangleShape2D.new()
		_skim_shape.one_way_collision = true  # blocks only from above (up is the default direction)
		_skim_body.add_child(_skim_shape)
		add_child(_skim_body)
	_skim_shape.one_way_collision_margin = catch_depth
	var width := interior_width + SKIM_FLOOR_EDGE_OVERLAP * 2.0
	(_skim_shape.shape as RectangleShape2D).size = Vector2(width, SKIM_FLOOR_THICKNESS)
	_skim_body.global_position = Vector2(
		global_position.x + _tile_size.x + interior_width * 0.5,
		get_liquid_surface_world_y() + SKIM_FLOOR_THICKNESS * 0.5)
	_skim_body.collision_layer = SKIM_FLOOR_LAYER_BIT

var _footprint_width: int = 0
	# Interior (open-water) column count = resolved_width_tiles - 2, excluding the two wall columns.
	# Cached by _rebuild() alongside the rest of the structural data. A basin whose resolved width is
	# the minimum, 2 (walls touching, no interior at all), has this at 0, and every query below
	# correctly treats such a basin as having zero capacity rather than dividing by zero.

var _basin_floor_row: float = 0.0
	# The deepest (largest floor_rows value) interior column. Through Phase 9 this was also the flat
	# reference ALL volume<->surface-height math used; as of Phase 10.2, get_surface_row() no longer
	# treats the basin as flat, but this is still used as: (a) the origin `get_surface_height_tiles()`
	# measures "height" up from, so that value keeps its existing meaning for any caller (b) the
	# deepest-first starting point _sorted_interior_floor_rows below is built from. Meaningless (left
	# at 0) when _footprint_width is 0.

var _sorted_interior_floor_rows: Array[float] = []
	# Phase 10.2: this basin's interior floor_rows, sorted deepest-first (descending). Index 0 is
	# always _basin_floor_row. The real per-column cross-section (see _surface_row_for_volume() and
	# _update_runtime_query_cache()) fills the deepest column first, then widens to include the next-
	# deepest once the rising surface reaches its floor, and so on — this is the fill order that
	# walk needs. Rebuilt alongside the rest of the query cache; empty when _footprint_width is 0.

var _cum_volume_at_level: Array[float] = []
	# Phase 10.2: parallel to _sorted_interior_floor_rows — _cum_volume_at_level[i] is the total
	# basin volume at the moment the rising surface exactly reaches _sorted_interior_floor_rows[i]
	# (i.e. when that column's own floor first starts holding water). Index 0 is always 0.0 (an empty
	# basin's surface starts exactly at the deepest column's floor). Built once per rebuild so
	# _surface_row_for_volume() can invert volume -> surface row with a single cheap linear walk
	# instead of re-deriving these breakpoints on every particle's every frame.

var _capacity_volume: float = 0.0
	# Volume at which the basin is exactly full, i.e. the surface has risen to meet the spill
	# column's height. fill_volume is never allowed past this by add_volume(). Comes out to 0 for a
	# basin with no interior or no valid spill column, which correctly makes is_full() report true
	# for a basin that structurally can't hold any water in the first place. As of Phase 10.2, this
	# is computed via the same real per-column sum get_surface_height_tiles() uses (see
	# _update_runtime_query_cache()), not the old flat (_basin_floor_row - spill_row) * footprint —
	# kept consistent with that so is_full()/get_fill_fraction() never disagree with the accurate
	# surface height right at the spill point.

var _ripple_h := PackedFloat32Array()
	# Surface ripple (cosmetic; see the "Surface ripple" section): height of each surface sample above its
	# resting level, in px, + = up. RIPPLE_SUBDIVISIONS samples per interior column, plus one closing sample,
	# so sample p sits at x = origin + tile_width + p * (tile_width / RIPPLE_SUBDIVISIONS).
var _ripple_v := PackedFloat32Array()  # vertical speed of each sample, px/s
var _ripple_strip_wet := PackedByteArray()
	# One entry per strip (the span between two neighbouring samples): 1 if that strip lies over a column
	# the liquid currently covers. Ripples travel only through wet strips, so a dry hump reflects them.
static var _skins: Dictionary = {}        # LiquidType -> LiquidSkin, only for types whose art file exists
static var _crust_skins: Dictionary = {}  # LiquidType -> LiquidSkin
static var _frozen_crust_skin: LiquidSkin = null  # the frozen crust's art, shared by both liquids; null if its file is missing
static var _skins_loaded: bool = false
var _skin_time: float = 0.0       # seconds on the liquid skin's animation clock
var _skin_frame: int = 0
var _crust_cool_t: float = INF    # seconds since this crust formed; INF = fully cooled (also what a restore sets)
var _ripple_live: bool = false  # true while any ripple exists; _process runs while this or a skin/crust animation needs it
var _ripple_moving: bool = false
var _ripple_accum: float = 0.0
var _ripple_wet_frame: int = -1
var _electrified_left: float = 0.0  # seconds of electrification remaining; runtime only, never saved (a restore comes back calm)
var _zap_x: float = 0.0  # world x of the most recent spark strike, where the arc is drawn brightest
var _zap_age: float = 0.0  # seconds since that strike

func _ready() -> void:
	if _world_tilemap == null and world_tilemap_path != NodePath():
		_world_tilemap = get_node_or_null(world_tilemap_path) as TileMapLayer
	_rebuild()
	set_process(false)  # _process only runs while a ripple, a skin animation or a crust cooling needs it
	set_physics_process(false)  # _physics_process only runs while frost, heat, an embedded player or an electrified frozen crust needs it
	if Engine.is_editor_hint():
		set_notify_transform(true)
		# Otherwise moving/dragging this node in the 2D viewport changes global_position with
		# nothing listening for it — the debug draw would go stale until width_tiles (the only
		# other thing wired to _rebuild()) happened to get touched too.
	else:
		set_process(false)
		# No per-frame work needed here — WaterManager reads floor_rows once via the registration
		# pass (Phase 2.3) rather than this node doing anything per-frame, and fill_volume is mutated
		# directly by WaterManager's absorb/overflow code, not polled. _rebuild() above still runs at
		# runtime (see its own comment) purely to compute _origin_cell/_tile_size and the query cache
		# from whatever floor_rows/spill_column were baked in at edit time.
		add_to_group(&"saveable")
		var seed_volume := _initial_fill_volume()
		if seed_volume > 0.0:
			add_volume(seed_volume)
			# Roadmap step 14.2: seeds this basin's settled state directly through the same
			# add_volume() every other credit to fill_volume goes through — not a special-cased
			# assignment — so it gets the same capacity clamp and queue_redraw() as any other fill.
			# Deliberately NOT routed through WaterManager's spawn_particle()/melt/faucet/overflow
			# paths: this is a starting condition read once off this basin's own export, not a fill
			# EVENT those paths exist to represent, and it needs no particles to have ever existed for
			# the basin to already read as full (or partway full) on the very first frame.
		_register_with_water_manager.call_deferred()
		# Deferred, not called directly: _ready() order between sibling nodes in the same scene
		# isn't guaranteed to put WaterManager's _ready() (which is what adds it to the
		# "water_manager" group) before this basin's — if this basin happened to be earlier in the
		# tree, a direct call here could run before the manager exists in the group and silently find
		# nothing. Deferring runs this after every node's own _ready() has already completed for the
		# frame, so the manager is guaranteed to be registered in its group by the time this fires,
		# regardless of sibling order.
		_ensure_crust_body()
		_rebuild_crust_collision()
			# Empty (no polygon) at this point, since has_crust always starts false — no authored
			# "start with some crust already formed" field exists yet, unlike initial_fill_depth_below_
			# surface for liquid. Called here anyway so _crust_body/_crust_collision exist and are in a
			# known (empty) state from frame one, rather than only coming into existence the first time
			# convert_to_crust() ever actually fires.

## Saveable contract (see game.gd). The whole runtime state of a basin: which liquid currently claims it (an
## empty basin is claimed by whatever arrives first, so this can differ from the authored export), how much
## liquid is settled, and the crust's two stored faces. Structure (floor rows, walls, capacity) always comes
## from the scene. Flowing particles are not part of a basin and are not restored.
func save_state() -> Dictionary:
	if is_temporary_frozen():
		# A temporary freeze is held by a beam and is never checkpointed: it is saved as the liquid it was (the band the
		# crust holds returned to the pool), so a restore cannot drop anyone through a crust that nothing is holding.
		return {
			"liquid_type": int(liquid_type),
			"fill_volume": minf(fill_volume + crust_volume, _capacity_volume),
			"has_crust": false,
			"crust_top_row": 0.0,
			"crust_bottom_row": 0.0,
			"crust_frozen": false,
		}
	return {
		"liquid_type": int(liquid_type),
		"fill_volume": fill_volume,
		"has_crust": has_crust,
		"crust_top_row": crust_top_row,
		"crust_bottom_row": crust_bottom_row,
		"crust_frozen": crust_frozen,
	}

## Overwrites whatever _ready() seeded (including an authored pre-fill). The crust is set first because the
## fill limit depends on it; then the crust's collision is rebuilt from the stored faces, the ripple is
## cleared and the body redrawn. Needs no manager call: the manager only holds references to basins.
func load_state(d: Dictionary) -> void:
	liquid_type = int(d.get("liquid_type", int(liquid_type)))
	has_crust = d.get("has_crust", false)
	crust_top_row = d.get("crust_top_row", 0.0)
	crust_bottom_row = d.get("crust_bottom_row", 0.0)
	crust_frozen = has_crust and bool(d.get("crust_frozen", false))
	_frost = 0.0  # frost, heat, the embedded latch and electrification are runtime only: a restore comes back calm
	_heat = 0.0
	_freeze_hold_frame = Engine.get_physics_frames()
	_electrified_left = 0.0
	_release_embedded()
	fill_volume = clampf(d.get("fill_volume", 0.0), 0.0, _max_fill_volume())
	_crust_cool_t = INF  # a restored crust is already cold: no cooling replay
	_surface_vy_frame = -1000  # the surface jumped: restart the surface-speed estimate
	_rebuild_crust_collision()
	_clear_ripple()
	queue_redraw()

## The crust's StaticBody2D. Its only job beyond collision is to be a laser target: the beam ends on it and tells it so,
## and it forwards the hit to its basin (a frozen crust heats toward a thaw; a reaction crust just ignores it).
class CrustBody extends StaticBody2D:
	var basin: Node = null
	func on_laser_hit(_point: Vector2, _direction: Vector2) -> void:
		if basin != null and is_instance_valid(basin) and basin.has_method(&"on_crust_laser_hit"):
			basin.on_crust_laser_hit()
	func on_freeze_hit(_point: Vector2, _direction: Vector2) -> void:
		if basin != null and is_instance_valid(basin) and basin.has_method(&"on_crust_freeze_hit"):
			basin.on_crust_freeze_hit()

func _ensure_crust_body() -> void:
	# One StaticBody2D + CollisionPolygon2D pair, created once here and reused for this basin's whole
	# lifetime — _rebuild_crust_collision() below only ever replaces the CollisionPolygon2D's own
	# `polygon` arrays, never recreates the nodes themselves. Runtime-only (called from _ready()'s
	# non-editor branch), same as every other physics-relevant setup in this file — no crust collision
	# exists in the editor, only the debug-draw preview (see _draw_settled_body()).
	var body := CrustBody.new()
	body.basin = self
	_crust_body = body
	_crust_body.name = "CrustBody"
	_crust_body.add_to_group("crust")
		# Roadmap 6.1: lets player.gd tell crust apart from ground. Deliberately NOT "catwalk" (lasers, water and steam
		# step past that group, so they would pass through crust) and not "ground" (nothing grabs crust from the side).
		# The player's underside hang accepts it through is_underside_free() on this body's parent basin.
	_crust_body.add_to_group("water_solid")
		# Registers with WaterManager's own "water_solid" self-registration convention (see
		# moving_platform.gd/drop_platform.gd/crusher.gd/cannon.gd) — this is what makes a WATER/SLAG
		# particle able to rest/creep on crust the same as any other solid, with no special-casing in
		# water_manager.gd's collision code for "is this surface crust." Also solid to the player for
		# free, via Godot's own physics, once collision_layer below matches the ground layer.
	_crust_body.collision_layer = crust_collision_layer
	_crust_body.collision_mask = 0  # a static floor has nothing of its own to detect
	add_child(_crust_body)

func _rebuild_crust_collision() -> void:
	# Rebuilds every CollisionPolygon2D child of _crust_body — called whenever the crust's geometry changes
	# (only from convert_to_crust(); draining liquid never touches crust geometry, so it never needs this). Built as one simple, guaranteed-convex quad PER wet
	# interior column, rather than reusing get_crust_polygon_world()'s single merged multi-column
	# polygon (the rendering shape, still used unchanged by _draw_settled_body()). A merged run's
	# stepped bottom edge is a genuinely CONCAVE polygon whenever neighboring columns' seabed heights
	# differ, and Godot's CollisionPolygon2D decomposes its `polygon` via
	# Geometry2D.decompose_many_polygons_in_convex — which can fail outright ("Convex decomposing
	# failed!") on some concave/near-degenerate shapes, silently leaving the body with NO collision
	# shapes at all rather than an error the player can see: this, not polygon thinness, was the
	# actual cause of the player falling through a nearly-full basin's crust (see
	# CRUST_THICKNESS_TILES's own comment for the separate, also-real swim-probe issue that fix
	# addresses). A single rectangle per column can never hit that failure mode — four points, always
	# a simple, already-convex quad — at the cost of one CollisionPolygon2D node per wet column
	# instead of one per contiguous run, which is a non-issue since this only runs on a reaction
	# event, not every frame.
	if _crust_body == null:
		return
	for child in _crust_body.get_children():
		child.queue_free()
	if _footprint_width <= 0 or not has_crust:
		return
	var top_y := get_crust_collision_top_world_y()
	var bottom_cap_y := get_crust_bottom_world_y()
	for local_col in range(1, resolved_width_tiles - 1):
		var col_bottom_y: float = minf(
			global_position.y + (seabed_floor_rows[local_col] - _origin_cell.y) * _tile_size.y,
			bottom_cap_y)
		if col_bottom_y <= top_y:
			continue  # a dry hump — this column's own floor sits above the crust boundary entirely
		var col_left_x := global_position.x + local_col * _tile_size.x
		var col_right_x := col_left_x + _tile_size.x
		var world_points := PackedVector2Array([
			Vector2(col_left_x, top_y),
			Vector2(col_right_x, top_y),
			Vector2(col_right_x, col_bottom_y),
			Vector2(col_left_x, col_bottom_y),
		])
		var shape := CollisionPolygon2D.new()
		shape.polygon = _to_local_polygon(world_points)
		_crust_body.add_child(shape)

func _to_local_polygon(world_points: PackedVector2Array) -> PackedVector2Array:
	# CollisionPolygon2D.polygon is in the shape's OWN parent's local space, not world space —
	# get_crust_polygon_world() (like get_body_polygon_world()) deliberately returns world-space
	# points, per its own naming and so basin.gd's world-space math doesn't need to know or care where
	# _crust_body sits, so this is the one conversion point back to local space that call needs.
	var local_points := PackedVector2Array()
	for p in world_points:
		local_points.append(_crust_body.to_local(p))
	return local_points

func _register_with_water_manager() -> void:
	var manager := get_tree().get_first_node_in_group("water_manager") as WaterManager
	if manager == null:
		push_warning("WaterBasin at %s: no WaterManager found in the \"water_manager\" group — this basin will never register, and its water will never be simulated" % global_position)
		return
	manager.register_basin(self)

func get_registration_data() -> Dictionary:
	# Called once by WaterManager's registration pass (Phase 2.3, via register_basin() above): hands
	# over this basin's INTERIOR (open-water) columns in absolute tilemap space, paired with each
	# column's floor row — the "per-column floor height, per-column basin membership" half of the
	# fixed data shape the "kept swappable by design" decision describes. Walls (column 0 and
	# resolved_width_tiles - 1) are excluded, the same range is_column_in_range() already tests — they can
	# never hold a particle, so they'd just be dead entries in WaterManager's lookup. Returns parallel
	# arrays rather than one Dictionary keyed by column, matching floor_rows' own existing convention
	# in this file, and so WaterManager's registration loop can walk them by index without an extra
	# unpack per entry. Keys: "columns" (Array[int], absolute tilemap column indices), "floor_rows"
	# (Array[float] as of Phase 10.1's sub-tile precision, parallel — each column's own
	# floor_rows[local_col] value).
	var columns: Array[int] = []
	var rows: Array[float] = []
	if _footprint_width > 0:
		for local_col in range(1, resolved_width_tiles - 1):
			columns.append(_origin_cell.x + local_col)
			rows.append(floor_rows[local_col])
	return {"columns": columns, "floor_rows": rows}

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_rebuild()

func _rebuild() -> void:
	# Editor-only above the "always" line below: the tile-scan derivation of floor_rows (and, now,
	# resolved_width_tiles when width_tiles is left at WIDTH_AUTO) is expensive and design-time-only,
	# same as the conveyor's segments->Pieces rebuild being an editor-time-only concern once a level is
	# saved — at runtime we trust whatever floor_rows/resolved_width_tiles/spill_column were left
	# holding after the last edit-time rebuild (baked into the saved scene). But _origin_cell,
	# _tile_size, and the derived query cache (_footprint_width/_basin_floor_row/_capacity_volume)
	# ARE needed at runtime too, by the query API below — those get recomputed unconditionally.
	if _world_tilemap == null and world_tilemap_path != NodePath():
		_world_tilemap = get_node_or_null(world_tilemap_path) as TileMapLayer
	if _world_tilemap == null:
		floor_rows.clear()
		seabed_floor_rows.clear()
		spill_column = OVERRIDE_NONE
		_update_runtime_query_cache()
		if Engine.is_editor_hint():
			queue_redraw()
		return

	if _world_tilemap.tile_set:
		_tile_size = _world_tilemap.tile_set.tile_size
	_origin_cell = _world_tilemap.local_to_map(_world_tilemap.to_local(global_position))
	z_index = _world_tilemap.z_index - 1
		# Phase 5.1: keeps the settled-water body (drawn in _draw_settled_body() below) behind the
		# ground tiles regardless of whatever z_index convention the level's tilemap actually uses —
		# computed relative to it rather than a hardcoded constant, so this can't silently end up
		# in front just because some level's tilemap isn't left at the default 0. Harmless to also set
		# this in the editor (it only affects the editor-only debug overlay's own draw order there,
		# which doesn't care what z_index it has).

	if Engine.is_editor_hint():
		resolved_width_tiles = width_tiles if width_tiles != WIDTH_AUTO else _detect_width_by_wall_scan()
		_sync_override_array_size()
		floor_rows.resize(resolved_width_tiles)
		seabed_floor_rows.resize(resolved_width_tiles)
		for col in range(resolved_width_tiles):
			if floor_row_override_enabled[col]:
				var overridden := float(_origin_cell.y + floor_row_overrides[col])
				floor_rows[col] = overridden
				seabed_floor_rows[col] = overridden
				# An override is authored, not sampled from tile geometry — both fields get the same
				# whole-tile value, no separate deepest-point version to derive.
			else:
				var row := _scan_column_floor(_origin_cell.x + col, _origin_cell.y)
				var cell := Vector2i(_origin_cell.x + col, row)
				floor_rows[col] = float(row) + _sample_tile_floor_offset(cell)
				seabed_floor_rows[col] = float(row) + _sample_tile_seabed_offset(cell)
				# Phase 10.1: row is still which TILE the floor lives in (surface_type gate,
				# unchanged); the two added fractions are where within that tile the gameplay floor
				# vs. the drawn seabed each sit — see seabed_floor_rows' own comment for why they
				# deliberately differ.
		_update_spill_column()

	_update_runtime_query_cache()
	if Engine.is_editor_hint():
		queue_redraw()

func _update_runtime_query_cache() -> void:
	# Derives the runtime query API's structural fields (_footprint_width, _basin_floor_row,
	# _sorted_interior_floor_rows, _cum_volume_at_level, _capacity_volume) from whatever
	# floor_rows/spill_column currently hold — called from _rebuild() both in the editor (right after
	# a fresh derivation) and at runtime (against the baked-in values), so it never itself touches
	# the tilemap.
	_footprint_width = maxi(0, resolved_width_tiles - 2)
	_sorted_interior_floor_rows.clear()
	_cum_volume_at_level.clear()
	if _footprint_width <= 0 or floor_rows.is_empty():
		_basin_floor_row = 0.0
		_capacity_volume = 0.0
		return

	for col in range(1, resolved_width_tiles - 1):
		_sorted_interior_floor_rows.append(floor_rows[col])
	_sorted_interior_floor_rows.sort()
	_sorted_interior_floor_rows.reverse()  # deepest (largest row value) first
	_basin_floor_row = _sorted_interior_floor_rows[0]

	# Phase 10.2: cumulative volume at each column's own floor level, per the histogram-style
	# cross-section this basin now fills by (see _sorted_interior_floor_rows'/_cum_volume_at_level's
	# own comments) — width i+1 (columns 0..i already reached) for the band between level i and
	# level i+1, so cum[i+1] = cum[i] + (i+1) * (level[i] - level[i+1]).
	_cum_volume_at_level.resize(_footprint_width)
	_cum_volume_at_level[0] = 0.0
	for i in range(1, _footprint_width):
		var width := i  # columns 0..(i-1), i.e. i of them, are already wet by the time level[i] is reached
		var band_height: float = _sorted_interior_floor_rows[i - 1] - _sorted_interior_floor_rows[i]
		_cum_volume_at_level[i] = _cum_volume_at_level[i - 1] + width * band_height

	if spill_column == OVERRIDE_NONE:
		_capacity_volume = 0.0
		return
	var spill_row: float = floor_rows[spill_column]
	# Real per-column sum (each interior column contributes only the part of its own depth that's
	# actually below the spill line), not the old flat (_basin_floor_row - spill_row) * footprint —
	# see _capacity_volume's own comment for why this needs to stay consistent with the height query.
	var capacity := 0.0
	for floor_row in _sorted_interior_floor_rows:
		capacity += maxf(0.0, floor_row - spill_row)
	_capacity_volume = capacity

func _sync_override_array_size() -> void:
	# Keeps both override arrays exactly width_tiles long, padding new columns with false/0 (both
	# already the unremarkable "not overridden" defaults, so no sentinel juggling needed) rather than
	# leaving them short (index errors) or long (stale entries from a since-shrunk basin). Mutated in
	# place (.append()/.resize()) rather than reassigned, so this doesn't re-enter either array
	# property's own setter.
	while floor_row_override_enabled.size() < resolved_width_tiles:
		floor_row_override_enabled.append(false)
	if floor_row_override_enabled.size() > resolved_width_tiles:
		floor_row_override_enabled.resize(resolved_width_tiles)
	while floor_row_overrides.size() < resolved_width_tiles:
		floor_row_overrides.append(0)
	if floor_row_overrides.size() > resolved_width_tiles:
		floor_row_overrides.resize(resolved_width_tiles)

func _update_spill_column() -> void:
	if floor_rows.is_empty():
		spill_column = OVERRIDE_NONE
		return
	var left := floor_rows[0]
	var right := floor_rows[resolved_width_tiles - 1]
	# larger row index = physically lower = shorter wall = spills first; ties favor the left wall,
	# arbitrarily — revisit if a real basin ever actually ties and the choice matters
	spill_column = 0 if left >= right else (resolved_width_tiles - 1)

# --- runtime fill scalar + query API (roadmap step 1.4) -------------------------------------
# Everything below is safe to call at runtime (unlike the tile-scanning derivation above, which is
# editor-only): all of it reads either fill_volume directly or the small structural cache
# (_footprint_width/_basin_floor_row/_capacity_volume) that _rebuild() keeps current in both modes.

func _surface_row_for_volume(v: float) -> float:
	# Phase 10.2: inverts _cum_volume_at_level/_sorted_interior_floor_rows to find the surface row at
	# which this basin holds exactly volume v — the real cross-section integration replacing the old
	# flat (fill_volume / _footprint_width) division. Walks the cached breakpoints (deepest first) to
	# find which band v falls in, then solves linearly within that band (each band is a constant-
	# width trapezoid, so linear is exact, not an approximation within the band — see
	# _update_runtime_query_cache() for how the bands themselves are built). O(_footprint_width), not
	# O(log n): basins are small enough that a linear scan over the cache is simpler than a binary
	# search and costs nothing measurable per particle per frame.
	if v <= 0.0:
		return _sorted_interior_floor_rows[0]
	var last: int = _footprint_width - 1
	var i := 0
	while i < last and _cum_volume_at_level[i + 1] <= v:
		i += 1
	var width := i + 1  # columns 0..i are wet at this point
	var extra: float = v - _cum_volume_at_level[i]
	return _sorted_interior_floor_rows[i] - extra / width

func _volume_for_surface_row(target_row: float) -> float:
	# Roadmap step 14: the other direction of _surface_row_for_volume() above — given a target
	# surface row, how much volume raises the water to exactly that row. Walks the same
	# _sorted_interior_floor_rows/_cum_volume_at_level breakpoints, just searching by row instead of
	# by volume: finds the deepest band whose own floor row is still >= target_row (i.e. still
	# underwater at that target), then solves the same per-band linear relationship in reverse. A
	# target_row at or below the empty basin's own surface (_sorted_interior_floor_rows[0], the
	# deepest column's floor) correctly returns 0 — there's no such thing as negative volume. A
	# target_row shallower than every interior column's floor extrapolates past the last breakpoint
	# using the full footprint width, exactly mirroring how _surface_row_for_volume() itself keeps
	# extrapolating past _cum_volume_at_level's last entry rather than stopping there — the two
	# functions are exact inverses of each other over any row/volume this basin can actually reach.
	if _footprint_width <= 0 or target_row >= _sorted_interior_floor_rows[0]:
		return 0.0
	var last: int = _footprint_width - 1
	var i := 0
	while i < last and _sorted_interior_floor_rows[i + 1] >= target_row:
		i += 1
	var width := i + 1
	return _cum_volume_at_level[i] + (_sorted_interior_floor_rows[i] - target_row) * width

func _initial_fill_volume() -> float:
	# Roadmap step 14: converts initial_fill_depth_below_surface (authored in tiles, measured down
	# from THIS basin's own full/spill surface) into the fill_volume add_volume() actually wants.
	# "This basin's own full surface" is floor_rows[spill_column] — get_surface_row() already reaches
	# exactly that value once fill_volume == _capacity_volume (that's how _capacity_volume was
	# derived in the first place, see _update_runtime_query_cache()), so it's the correct zero point
	# without needing to re-derive it. Adding the authored depth moves the target row further FROM
	# that point (larger row = physically lower = less full), then _volume_for_surface_row() does the
	# real per-column cross-section conversion — the same one every other height<->volume query in
	# this file goes through, so "N tiles below full" means the same thing here as it would reading
	# get_surface_height_tiles() live during play, on any basin shape, not just a rectangular one.
	# NO_INITIAL_FILL (or any other negative value) means "not authored" — reads as 0 volume, same as
	# a basin that never had this field touched at all. A basin with no valid spill column (no real
	# interior, or nothing solid enough to have derived one) also has no "full" to measure down from —
	# reads as unfillable, same as _capacity_volume already treats that case.
	if _footprint_width <= 0 or spill_column == OVERRIDE_NONE or initial_fill_depth_below_surface < 0.0:
		return 0.0
	var full_row: float = floor_rows[spill_column]
	return _volume_for_surface_row(full_row + initial_fill_depth_below_surface)

func get_liquid_surface_row() -> float:
	# Where the still-liquid part of this basin sits, as a fractional tilemap row: the surface a body
	# of `fill_volume` would have resting on the real floor. Liquid is always floor-anchored, so this
	# is unaffected by crust; after a drain it can sit well below the crust's underside (the gap is
	# the void). A basin with no interior reports _basin_floor_row.
	if _footprint_width <= 0:
		return _basin_floor_row
	return _surface_row_for_volume(fill_volume)

func get_liquid_surface_world_y() -> float:
	return global_position.y + (get_liquid_surface_row() - _origin_cell.y) * _tile_size.y

const SURFACE_VELOCITY_SMOOTH_TIME := 0.25  # s: time constant of the surface-speed estimate (fill arrives in particle-sized steps)
const SURFACE_VELOCITY_MAX := 240.0  # px/s: a restore or a teleported fill can't read as a flood
const SURFACE_VELOCITY_GAP_FRAMES := 3  # physics frames without a query after which the estimate restarts from rest
var _surface_vy: float = 0.0  # runtime scratch, never saved
var _surface_prev_y: float = 0.0
var _surface_vy_frame: int = -1000

## Vertical velocity of the settled liquid surface in px/s (negative = rising), what a floating body rides. Estimated
## from the change of get_liquid_surface_world_y() between physics frames and smoothed over
## SURFACE_VELOCITY_SMOOTH_TIME, since fill arrives in particle-sized steps. Computed lazily, once per physics
## frame however many bodies ask, so a basin nobody floats on costs nothing; the first query, or one after a gap of
## more than SURFACE_VELOCITY_GAP_FRAMES frames, reads 0 and restarts the estimate. Ripple isn't part of it.
func get_liquid_surface_velocity_y() -> float:
	var frame := Engine.get_physics_frames()
	if frame == _surface_vy_frame:
		return _surface_vy
	var y := get_liquid_surface_world_y()
	var frames := frame - _surface_vy_frame
	if frames > SURFACE_VELOCITY_GAP_FRAMES:
		_surface_vy = 0.0
	else:
		var step := frames / float(Engine.physics_ticks_per_second)
		var raw := clampf((y - _surface_prev_y) / step, -SURFACE_VELOCITY_MAX, SURFACE_VELOCITY_MAX)
		_surface_vy += (raw - _surface_vy) * minf(1.0, step / SURFACE_VELOCITY_SMOOTH_TIME)
	_surface_prev_y = y
	_surface_vy_frame = frame
	return _surface_vy

## True while a spark's zap keeps this pool electrified (see `try_electrify_at()`).
func is_electrified() -> bool:
	return _electrified_left > 0.0

## Whether this basin's settled liquid hurts a body in it right now: a hazardous liquid (slag) always, or any liquid
## while electrified. The one question the player's swim check and the surf's skim lookup ask, so a new transient
## hazard is added here and nowhere else.
func is_hazardous_now() -> bool:
	return _electrified_left > 0.0 or LiquidConstants.profile(liquid_type).is_hazardous

## A spark at `world_point` (the lowest point of the ball) reports where it is; if that touches this basin's settled
## water surface the pool is electrified for `electrified_time` and true is returned (the spark is spent). Refused,
## so the spark carries on as it always did, when: `conducts_sparks` is off; the liquid is hazardous already (slag, frozen
## or not); the basin holds no liquid over that column; a REACTION crust seals the liquid (the spark lands on the crust, a
## solid); or the point is still above the surface. A FROZEN crust over water is the exception: it conducts, so a strike
## at or below its top face over a column that carries crust electrifies the basin, and while it lasts the crust's top
## hurts a player standing on it (see _poll_electric_crust()). A strike while already electrified restarts the countdown.
func try_electrify_at(world_point: Vector2) -> bool:
	if Engine.is_editor_hint() or not conducts_sparks or _world_tilemap == null:
		return false
	if has_crust and not crust_frozen:
		return false
	if LiquidConstants.profile(liquid_type).is_hazardous:
		return false
	var col := _world_tilemap.local_to_map(_world_tilemap.to_local(world_point)).x
	var surface_y: float
	if has_crust:
		if not _crust_at_column(col):
			return false
		surface_y = get_crust_top_world_y()
	else:
		if not has_liquid_at_column(col):
			return false
		surface_y = get_liquid_surface_world_y()
	if world_point.y < surface_y - ELECTRIC_REACH:
		return false
	_electrified_left = maxf(_electrified_left, electrified_time)
	_zap_x = world_point.x
	_zap_age = 0.0
	if not has_crust:
		disturb(world_point.x, ELECTRIC_SPLASH_VELOCITY, 10.0)
	Audio.play_at(&"interactive/basin_zap", Vector2(world_point.x, surface_y))
	set_process(true)
	_update_physics_state()
	queue_redraw()
	return true

# --- Freeze ray (roadmap N3.2) -----------------------------------------------------------------------

## True while a FROZEN crust (formed by freeze()) is on this basin. A reaction crust is not.
func is_frozen_crust() -> bool:
	return has_crust and crust_frozen

## Whether the freeze ray can act on this basin now: opted in (`freezable`), holds liquid and has no crust.
func can_freeze() -> bool:
	return freezable and not has_crust and fill_volume > 0.0 and _footprint_width > 0 and not Engine.is_editor_hint()

## The freeze ray's per-frame contact (WaterManager.freeze_along_beam()). Builds frost by `delta` seconds, and freezes the
## basin when it reaches `freeze_time`. Returns true on the frame it freezes. Frost decays on its own once the beam leaves.
func add_frost(delta: float) -> bool:
	if not can_freeze():
		return false
	_frost_hit_frame = Engine.get_physics_frames()
	_frost = minf(_frost + delta, freeze_time)
	_update_physics_state()
	if _frost >= freeze_time:
		return freeze()
	return false

## Freezes the settled liquid into a FROZEN crust: the same slab as the reaction crust (top face at the liquid surface,
## CRUST_THICKNESS_TILES thick, the liquid between the faces becomes crust, the liquid under it stays), but with no
## opposite liquid, no steam, its own skin, meltable by a laser and electrifiable. Valid for a crust-free basin that holds
## liquid (water or slag, electrified or not; an electrified pool keeps its remaining time on the crust). A player inside
## the new crust or under the surface of this basin is latched as embedded (_latch_embedded()) so it is never sealed in.
## Returns true if the crust formed. Does not check `freezable` (that gates the ray, not the call).
func freeze() -> bool:
	if Engine.is_editor_hint() or has_crust or fill_volume <= 0.0 or _footprint_width <= 0:
		return false
	convert_to_crust(0.0)
	if not has_crust:
		return false
	crust_frozen = true
	_frost = 0.0
	_heat = 0.0
	_freeze_hold_frame = Engine.get_physics_frames()  # the beam that froze it has THAW_GRACE_FRAMES to find the new crust
	_latch_embedded()
	Audio.play_at(&"interactive/basin_freeze", _basin_centre_at(get_crust_top_world_y()))
	_update_process_state()
	_update_physics_state()
	queue_redraw()
	return true

## The laser's contact with a frozen crust, forwarded by the crust body (CrustBody.on_laser_hit(), once per physics frame
## the beam ends on it). Builds heat; at `melt_time` the whole crust thaws. A reaction crust ignores it (and the beam just
## stops on it, as always).
func on_crust_laser_hit() -> void:
	if not is_frozen_crust():
		return
	_heat_hit_frame = Engine.get_physics_frames()
	_heat += get_physics_process_delta_time()
	_update_physics_state()
	if _heat >= melt_time:
		thaw()

## True while a FROZEN crust that needs the beam to hold it is on this basin: the liquid's profile says its frozen crust is
## temporary (slag). Frozen water is not: it stays until a laser melts it.
func is_temporary_frozen() -> bool:
	return is_frozen_crust() and LiquidConstants.profile(liquid_type).frozen_is_temporary

## The freeze ray's contact with a frozen crust, forwarded by the crust body (CrustBody.on_freeze_hit(), once per physics
## frame the beam ends on it). A temporary frozen crust is held for as long as this keeps arriving and thaws
## THAW_GRACE_FRAMES frames after it stops (see _physics_process()); any other crust ignores it.
func on_crust_freeze_hit() -> void:
	if is_temporary_frozen():
		_freeze_hold_frame = Engine.get_physics_frames()

## Reverses a frozen crust: the crust and its collision are removed and the band of liquid it held is returned (clamped
## to capacity), so the basin is an ordinary crust-free basin again. No steam, no particles. Only a frozen crust thaws;
## a reaction crust never thins. Returns true if it thawed.
func thaw() -> bool:
	if not is_frozen_crust():
		return false
	var band := crust_volume  # before the faces stop counting
	has_crust = false
	crust_frozen = false
	fill_volume = minf(fill_volume + band, _max_fill_volume())
	_crust_cool_t = INF
	_frost = 0.0
	_heat = 0.0
	_release_embedded()
	_rebuild_crust_collision()  # no crust: clears the body's shapes
	_clear_ripple()
	_surface_vy_frame = -1000  # the surface jumped: restart the surface-speed estimate
	Audio.play_at(&"interactive/basin_thaw", _basin_centre_at(get_liquid_surface_world_y()))
	_update_process_state()
	_update_physics_state()
	queue_redraw()
	return true

func _basin_centre_at(world_y: float) -> Vector2:
	return Vector2(global_position.x + _tile_size.x * resolved_width_tiles * 0.5, world_y)

## Whether this interior column carries crust (its own seabed lies below the crust's top face; a dry hump never does).
func _crust_at_column(map_col: int) -> bool:
	return has_crust and is_column_in_range(map_col) and get_column_seabed_world_y(map_col) > get_crust_top_world_y()

func _find_player() -> Node2D:
	var player := get_tree().get_first_node_in_group(&"player") as Node2D
	return player if player != null and is_instance_valid(player) else null

## The player's collider as a world rect (a swimming player's collider is rotated, so the shape's rect is transformed).
func _player_rect(player: Node) -> Rect2:
	var shape_node := player.get(&"collision_shape") as CollisionShape2D
	if shape_node == null or shape_node.shape == null:
		return Rect2((player as Node2D).global_position, Vector2.ZERO)
	return shape_node.global_transform * shape_node.shape.get_rect()

## Whether the world rect overlaps a column that carries crust, horizontally (the crust's own x extent).
func _rect_over_crust(rect: Rect2) -> bool:
	if not has_crust or _footprint_width <= 0 or _tile_size.x <= 0.0:
		return false
	var first := _origin_cell.x + floori((rect.position.x - global_position.x) / _tile_size.x)
	var last := _origin_cell.x + floori((rect.end.x - 0.001 - global_position.x) / _tile_size.x)
	for col in range(first, last + 1):
		if _crust_at_column(col):
			return true
	return false

## Latches the player as embedded if it is inside the new crust or submerged in this basin's liquid under it: some part of
## its collider is below the crust's collision top over a column that carries crust. The crust body then ignores the player
## until _tick_embedded() sees it above the top face. Set once, at the freeze; a player who arrives later meets solid crust.
func _latch_embedded() -> void:
	_embedded = false
	var player := _find_player()
	if player == null or _crust_body == null:
		return
	var rect := _player_rect(player)
	if _rect_over_crust(rect) and rect.end.y > get_crust_collision_top_world_y() + 0.5:
		_embedded = true
		_crust_body.add_collision_exception_with(player as PhysicsBody2D)

func _release_embedded() -> void:
	if not _embedded:
		return
	_embedded = false
	var player := _find_player()
	if player != null and _crust_body != null and is_instance_valid(_crust_body):
		_crust_body.remove_collision_exception_with(player as PhysicsBody2D)
	queue_redraw()  # the cooling frame held back for the embedded player shows now
	_update_process_state()

## True while the freeze that formed this crust has left the player embedded (see _latch_embedded()).
func is_player_embedded() -> bool:
	return _embedded

## The surface the swim check measures depth against for `body`: the liquid surface, except for the embedded player, for
## whom it is the crust's top face (so the player swims up through the crust band as if it were water, and leaves swimming
## at the top, where the crust turns solid under it). Read by the player's `_water_surface_depth()`.
func get_swim_surface_world_y(body: Node) -> float:
	if _embedded and body != null and body.is_in_group(&"player") and has_crust:
		return minf(get_liquid_surface_world_y(), get_crust_top_world_y())
	return get_liquid_surface_world_y()

## Each physics frame while embedded: ends the latch once the player's centre is above the crust's top face (the swim
## check's own exit line, so the crust turns solid as the player leaves the water) or has left the crust's columns, and
## chills the player while any of it overlaps the band.
func _tick_embedded(_delta: float) -> void:
	var player := _find_player()
	if player == null or not has_crust:
		_release_embedded()
		return
	var rect := _player_rect(player)
	var centre_y := rect.get_center().y
	if centre_y < get_crust_top_world_y() or not _rect_over_crust(rect):
		_release_embedded()
		return
	if rect.end.y > get_crust_top_world_y() and rect.position.y < get_crust_bottom_world_y() and player.has_method(&"apply_chill"):
		player.apply_chill(1.0)

## While a frozen crust is electrified, a player standing on its top is hurt, polled every physics frame (the crusher's
## pattern: take_hit()'s i-frames pace it, so a player who stays is hit again the moment they can be). Standing on it is
## feet within FROZEN_STAND_TOLERANCE of the collision top, on the floor, over a column that carries crust. A player in or
## under the crust is hurt by the electrified liquid through the swim check instead (is_hazardous_now()).
func _poll_electric_crust() -> void:
	var player := _find_player()
	if player == null or not player.has_method(&"take_hit") or not player.has_method(&"is_on_floor"):
		return
	if not player.is_on_floor():
		return
	var rect := _player_rect(player)
	if absf(rect.end.y - get_crust_collision_top_world_y()) > FROZEN_STAND_TOLERANCE or not _rect_over_crust(rect):
		return
	player.take_hit(int(player.get(&"ELECTRIC_CONTACT_DAMAGE")), (player as Node2D).global_position)

func _needs_physics() -> bool:
	if Engine.is_editor_hint():
		return false
	return _frost > 0.0 or _heat > 0.0 or _embedded or is_temporary_frozen() or (is_frozen_crust() and _electrified_left > 0.0)

func _update_physics_state() -> void:
	set_physics_process(_needs_physics())

func _physics_process(delta: float) -> void:
	var frames := Engine.get_physics_frames()
	if _frost > 0.0 and frames - _frost_hit_frame > BEAM_GRACE_FRAMES:
		_frost = maxf(_frost - FROST_DECAY_PER_SEC * delta, 0.0)
	if _heat > 0.0 and frames - _heat_hit_frame > BEAM_GRACE_FRAMES:
		_heat = maxf(_heat - FROST_DECAY_PER_SEC * delta, 0.0)
	if _embedded:
		_tick_embedded(delta)
	if is_frozen_crust() and _electrified_left > 0.0:
		_poll_electric_crust()
	if is_temporary_frozen() and frames - _freeze_hold_frame > THAW_GRACE_FRAMES:
		thaw()  # no freeze beam has ended on the crust for a moment: it lets go (frozen slag is molten slag again)
	if not _needs_physics():
		set_physics_process(false)

func get_surface_row() -> float:
	# The basin's OUTER surface as a fractional tilemap row — the line a particle has to reach to be
	# absorbed or to react. With a crust that's the crust's top face, wherever the liquid underneath
	# happens to sit; without one it's simply the liquid surface. (Same row convention as
	# floor_rows — the row number IS the world y in tile units, top edge of that cell.)
	if has_crust:
		return crust_top_row
	return get_liquid_surface_row()

func get_crust_bottom_row() -> float:
	# The crust's lower face. With no crust this equals the liquid surface, i.e. a zero-thickness
	# crust — so callers that only ask "where does solid end and open space/liquid begin" need no
	# special case.
	if has_crust:
		return crust_bottom_row
	return get_liquid_surface_row()

func get_crust_top_world_y() -> float:
	return global_position.y + (get_surface_row() - _origin_cell.y) * _tile_size.y

const CRUST_COLLISION_TOP_INSET := 1.0
	# Roadmap 6.1: px the crust's walkable collision starts below its top face (get_crust_top_world_y()), because the
	# crust art's first row is empty and a player standing on the exact face looked to float one pixel above the surface.
	# Collision only: the stored faces, the drawn crust, liquid and every other query still use the face itself.

func get_crust_collision_top_world_y() -> float:
	# The top of the crust's collision, i.e. the y a player's feet rest at on it. Never above the crust's bottom face.
	return minf(get_crust_top_world_y() + CRUST_COLLISION_TOP_INSET, get_crust_bottom_world_y())

func get_crust_bottom_world_y() -> float:
	return global_position.y + (get_crust_bottom_row() - _origin_cell.y) * _tile_size.y

func liquid_touches_crust() -> bool:
	# True while the liquid's surface is still level with (within LIQUID_CONTACT_TOLERANCE_TILES of)
	# the crust's underside — i.e. no void beneath it. While true, the liquid's own surface is hidden
	# (no skin, no ripple): it is just the body colour meeting the crust.
	if not has_crust or fill_volume <= 0.0:
		return false
	return get_liquid_surface_row() <= crust_bottom_row + LIQUID_CONTACT_TOLERANCE_TILES

func get_surface_height_tiles() -> float:
	# Current water height above the basin's deepest interior column, in tile units — 0 at empty,
	# rising toward however many tiles tall the basin's capacity is as fill_volume approaches
	# _capacity_volume. As of Phase 10.2 this no longer assumes every interior column fills at the
	# same rate (fill_volume / _footprint_width): a shallower column only starts contributing to the
	# visible rise once the real cross-section (get_surface_row()) actually reaches it. A basin with
	# no interior (_footprint_width == 0) has no meaningful height; reports 0 rather than indexing
	# into an empty cache.
	if _footprint_width <= 0:
		return 0.0
	return _basin_floor_row - get_surface_row()

func get_surface_world_y() -> float:
	# get_surface_row() (the OUTER surface: crust top if crusted, else liquid) as a world-space y — useful for anything that wants a
	# world position (e.g. Phase 3.4's full-basin creep-out contact, or the Phase 5 settled-water
	# rectangle) rather than a row number.
	return global_position.y + (get_surface_row() - _origin_cell.y) * _tile_size.y

func get_body_polygon_world() -> Array[PackedVector2Array]:
	# Phase 10.3: the "what shape do I draw for the seabed" query, deliberately kept SEPARATE from
	# the height/volume query methods above (get_surface_height_tiles()/get_surface_row()/
	# get_surface_world_y()) per the "Accurate basin floor mapping" v2 goal — replaces the old flat
	# get_body_rect_world() rectangle with real polygons traced from floor_rows' now per-column
	# (Phase 10.1) data, without changing what the height/volume methods return or who calls them.
	#
	# Returns a list of closed world-space polygons — USUALLY just one, but see the BUG FIX note
	# below for when it's more than one. Each polygon: a flat top edge at the current surface line
	# (the surface genuinely IS flat — only the floor varies per column, water finds its own level),
	# then a stepped bottom edge that walks the relevant interior columns' own seabed_floor_rows
	# value right-to-left, tracing the actual per-column floor height as a staircase rather than a
	# smooth curve — seabed_floor_rows holds one scalar per column, not a continuous sub-tile shape,
	# so a staircase is what that data honestly supports; smoothing it into a ramp would claim
	# precision this basin doesn't have. Deliberately reads seabed_floor_rows here, NOT floor_rows
	# (the height/volume math's own per-column sample) — see seabed_floor_rows' own comment for why
	# the drawn seabed needs the deepest point in each column rather than its center. A basin with no
	# interior (or nothing currently wet at all) has no shape to draw — returns an empty array rather
	# than something every caller has to special-case with its own footprint/is_full() check.
	#
	# BUG FIX: this used to build ONE contour across every interior column, clamping a not-yet-
	# submerged column's bottom point up to the surface line (maxf) so it wouldn't poke above it. That
	# clamp is exactly right at either END of the wet stretch (it's what makes the top edge meet the
	# staircase cleanly), but a column in the MIDDLE of the interior span whose own floor sits above
	# the current surface — a hump the rising water hasn't covered yet — got clamped too, pinching
	# the whole contour down to zero height at that one point. A single contour that touches itself
	# like that is a degenerate polygon Godot's triangulator can flatly reject (see
	# _draw_settled_body()'s own comment for the exact error this produced) — and since triangulation
	# either succeeds or fails for the WHOLE contour, nothing drew anywhere in the basin until the
	# fill rose enough to cover the hump too, not just near the hump itself. Fixed by walking columns
	# left-to-right, splitting the interior into maximal contiguous runs of columns that are actually
	# wet (their own true, unclamped seabed height sits below the surface), and emitting one separate,
	# well-formed polygon per run — a dry column (hump or otherwise) is simply excluded, never
	# clamped, so a pinch can no longer happen. This is a drawing-only fix: still one basin with one
	# flat surface line and one fill_volume, same as 10.2's math already computes; a hump merely means
	# that basin's drawn water can be more than one visible piece at some fill levels, same as it
	# always could hold water unevenly across an uneven floor.
	#
	# Liquid/crust split: the liquid's top edge is its OWN floor-anchored surface
	# (get_liquid_surface_world_y()), which after a drain can sit below the crust's underside — the
	# gap between them is simply not drawn (the void). Liquid always rests on the real seabed
	# (bottom_cap_y = INF, no cap).
	if _footprint_width <= 0:
		return []
	return _build_column_runs(get_liquid_surface_world_y(), INF)

func get_crust_polygon_world() -> Array[PackedVector2Array]:
	# The crust counterpart to get_body_polygon_world(): same run-splitting/staircase approach via
	# _build_column_runs(), but between the crust's own two stored faces — top face down to bottom
	# face, the bottom passed as bottom_cap_y so a column whose seabed sits inside the crust band is
	# clipped there. Used for drawing (see _draw_settled_body()) AND for the walkable collision shape
	# (see _rebuild_crust_collision()), which need the exact same extents.
	if _footprint_width <= 0 or not has_crust:
		return []
	return _build_column_runs(get_crust_top_world_y(), get_crust_bottom_world_y())

func _build_column_runs(top_y: float, bottom_cap_y: float, rippled: bool = false, with_walls: bool = false) -> Array[PackedVector2Array]:
	# rippled: bend each run's flat top edge along the live surface ripple (see "Surface ripple"); only the
	# drawn liquid body asks for it, never the crust or any shape query.
	# Shared by get_body_polygon_world() (liquid) and get_crust_polygon_world() (solidified liquid) —
	# both are "trace a stepped-bottom shape up to some flat surface line," differing only in which
	# surface line, and whether the bottom needs capping against a further layer sitting UNDER them
	# (bottom_cap_y; pass INF for "no cap"). The liquid body always wants no cap now — it sits directly
	# on the real seabed, whatever crust has formed above it — while crust caps against the liquid
	# boundary (get_crust_bottom_row()), since crust is the layer that stops short of the true floor.
	var polygons: Array[PackedVector2Array] = []
	for run_variant in _collect_runs(top_y, bottom_cap_y):
		var run_cols: Array[int] = run_variant
		polygons.append(_build_run_polygon(run_cols, top_y, bottom_cap_y, rippled, with_walls))
	return polygons

func _collect_runs(top_y: float, bottom_cap_y: float) -> Array:
	# The maximal contiguous runs of interior columns that actually hold something (their own seabed, capped at
	# bottom_cap_y, is strictly deeper than top_y), as lists of local column indices left-to-right. A dry column
	# is excluded, never clamped, so a run can't pinch. Shared by the polygon builder and the skin drawing, so
	# the two always cover the same columns.
	var runs: Array = []  # of Array[int]; untyped so callers can take each run as a Variant
	var run_cols: Array[int] = []
	for local_col in range(1, resolved_width_tiles - 1):
		var col_y := minf(
			global_position.y + (seabed_floor_rows[local_col] - _origin_cell.y) * _tile_size.y,
			bottom_cap_y)
		if col_y > top_y:  # strictly deeper than the surface — this column actually holds something
			run_cols.append(local_col)
		elif not run_cols.is_empty():
			runs.append(run_cols.duplicate())
			run_cols.clear()
	if not run_cols.is_empty():
		runs.append(run_cols)
	return runs

func _build_run_polygon(run_cols: Array[int], top_y: float, bottom_cap_y: float, rippled: bool = false, with_walls: bool = false) -> PackedVector2Array:
	# One contiguous run of actually-wet/crusted columns (see _build_column_runs() above) -> one
	# closed, well-formed polygon: flat top at top_y spanning the run's own left..right extent, stepped
	# bottom tracing each column's real (capped at bottom_cap_y, same as the run-finding check above —
	# every column here already satisfied that same condition, so no pinching is possible) seabed
	# height, right-to-left.
	var left_x := global_position.x + run_cols[0] * _tile_size.x
	var right_x := global_position.x + (run_cols[run_cols.size() - 1] + 1) * _tile_size.x
	var points := PackedVector2Array()
	var strips_padded := false  # the skinned top below already carries the wall pad
	if rippled and _liquid_skin() != null:
		# Skinned liquid: the top is a staircase of whole-pixel steps, one per ripple strip, exactly where the
		# skin's strips are drawn, so the body never pokes above or falls short of the art.
		var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
		for strip in _run_strips(run_cols, top_y, bottom_cap_y, true, with_walls):
			points.append(Vector2(strip.x, strip.y))
			points.append(Vector2(strip.x + spacing, strip.y))
		strips_padded = with_walls
	elif rippled and _ripple_live:
		_append_rippled_top(points, run_cols, left_x, top_y, bottom_cap_y)
	else:
		points.append(Vector2(left_x, top_y))
		points.append(Vector2(right_x, top_y))
	# Wall pad (drawing only): the run's edge columns continue into the wall columns at the same top and floor.
	var pad := _wall_pad_px() if with_walls else 0.0
	var pad_left := pad > 0.0 and _run_touches_left_wall(run_cols)
	var pad_right := pad > 0.0 and _run_touches_right_wall(run_cols)
	if strips_padded:
		pad_left = false
		pad_right = false
	if pad_left:
		points.insert(0, Vector2(left_x - pad, points[0].y))
	if pad_right:
		points.append(Vector2(right_x + pad, points[points.size() - 1].y))
	var first_col_y := 0.0
	for i in range(run_cols.size() - 1, -1, -1):  # right to left
		var local_col: int = run_cols[i]
		var col_left_x := global_position.x + local_col * _tile_size.x
		var col_right_x := col_left_x + _tile_size.x
		var col_y := minf(
			global_position.y + (seabed_floor_rows[local_col] - _origin_cell.y) * _tile_size.y,
			bottom_cap_y)
		if i == run_cols.size() - 1:
			if pad_right:
				points.append(Vector2(right_x + pad, col_y))
		first_col_y = col_y
		points.append(Vector2(col_right_x, col_y))
		points.append(Vector2(col_left_x, col_y))
	if pad_left:
		points.append(Vector2(left_x - pad, first_col_y))
	return points

func is_column_in_range(map_col: int) -> bool:
	# True only for this basin's INTERIOR columns (open water) — the two wall columns are solid and
	# can never hold a particle, so they're deliberately excluded. This is the "is this particle's
	# column inside a basin's range" check Phase 3.3's settle logic and Phase 4's push query both
	# need; map_col is an absolute tilemap column index, same space as floor_rows' derivation.
	if _footprint_width <= 0:
		return false
	var local_col := map_col - _origin_cell.x
	return local_col >= 1 and local_col <= resolved_width_tiles - 2

func get_rim_world_y() -> float:
	# World y of this basin's rim (top of its walls) — the same for every column, since all of a
	# basin's walls start at its single _origin_cell row regardless of how floor height varies
	# per-column. The upper bound in owns_world_point() below.
	return global_position.y

func owns_world_point(map_col: int, world_y: float, rim_margin: float = 0.0) -> bool:
	# True if (map_col, world_y) sits inside THIS basin's interior — used to pick the right basin
	# when two are registered on the same column but at different heights (one basin's floor sitting
	# directly above another's rim, e.g. a drain faucet's tile). Inclusive on both ends: the exact
	# world y of a floor tile's top edge belongs to the basin ABOVE it (that tile IS that basin's
	# seabed), never to whatever's registered one tile further down, since the basin below's rim
	# starts a full tile lower still.
	# rim_margin lowers the upper bound (px): a FULL basin's surface sits exactly at its rim when both
	# walls start at the basin's origin row, so a particle resting on that surface has its centre half a
	# particle ABOVE the rim. A particle lookup passes its own half-size so the resting particle still
	# resolves to this basin instead of dropping out of it (see WaterManager._basin_for_particle()).
	if not is_column_in_range(map_col):
		return false
	return world_y >= get_rim_world_y() - rim_margin and world_y <= get_column_seabed_world_y(map_col)

func get_column_seabed_world_y(map_col: int) -> float:
	# World y of the deepest point of this interior column's floor (from seabed_floor_rows, the same
	# per-column sample the drawn seabed uses). Anything whose TOP edge is below this has left the
	# basin through its bottom — WaterManager uses it so a drained particle isn't re-absorbed, and
	# player.gd uses it so standing in a room beneath a basin doesn't read as being submerged.
	# INF for a column outside this basin's interior.
	if not is_column_in_range(map_col):
		return INF
	var local_col := map_col - _origin_cell.x
	return global_position.y + (seabed_floor_rows[local_col] - _origin_cell.y) * _tile_size.y

func is_floor_cell(cell: Vector2i) -> bool:
	# True if `cell` is the tile forming the floor of one of this basin's interior columns — i.e.
	# the cell directly above it is that column's lowest cell of basin. A drain faucet sits in
	# such a cell. Uses floor_rows (the same per-column sample all height math uses): the floor
	# tile's own row is floor(floor_rows), whole for a full tile and fractional for a half/sloped
	# one.
	if not is_column_in_range(cell.x):
		return false
	var local_col := cell.x - _origin_cell.x
	return int(floorf(floor_rows[local_col] + 0.001)) == cell.y

func get_crust_underside_world_y_at(world_x: float) -> float:
	# Roadmap 6.2: world y of the crust collision's bottom face at `world_x`: the crust's bottom face, or the column's seabed
	# where that sits higher (the crust is clipped there, as in _rebuild_crust_collision()). INF when there is no crust.
	# What a hang from the crust's underside grips, asked from above when the player crouch+jumps down into it.
	if not has_crust or _footprint_width <= 0:
		return INF
	var map_col := _origin_cell.x + floori((world_x - global_position.x) / _tile_size.x)
	var bottom := get_crust_bottom_world_y()
	if is_column_in_range(map_col):
		bottom = minf(bottom, get_column_seabed_world_y(map_col))
	return bottom

func is_underside_free(world_x: float, span_top: float, span_bottom: float) -> bool:
	# Roadmap 6.1: true when no still-liquid occupies the vertical span [span_top, span_bottom] (world y) at `world_x`:
	# what the player's hang under this basin's crust asks, with the span the hanging body would fill. Liquid at a column
	# runs from its own surface (get_liquid_surface_world_y()) down to that column's seabed, so a void left by a drain
	# reads free and a basin the liquid has refilled up to the crust reads blocked. A column outside the interior, an
	# empty basin and a dry hump all read free. Read-only.
	if _footprint_width <= 0 or fill_volume <= 0.0:
		return true
	var map_col := _origin_cell.x + floori((world_x - global_position.x) / _tile_size.x)
	if not has_liquid_at_column(map_col):
		return true
	var liquid_top := get_liquid_surface_world_y()
	var seabed := get_column_seabed_world_y(map_col)
	return not (liquid_top < span_bottom - 0.5 and seabed > span_top)

func has_liquid_at_column(map_col: int) -> bool:
	# True if there is still-liquid lying over this interior column's floor right now. Crust and
	# void both read false: only real liquid can be drained.
	if not is_column_in_range(map_col) or fill_volume <= 0.0:
		return false
	var local_col := map_col - _origin_cell.x
	return get_liquid_surface_row() < floor_rows[local_col] - 0.001

func get_interior_column_count() -> int:
	# How many open (interior) columns the basin has: width minus its two wall columns. 0 for a basin with no
	# interior or one that hasn't been derived yet. What a BasinSensor's `column` is checked against.
	return _footprint_width

func get_liquid_depth_at_interior_column(index: int) -> float:
	# Depth, in tiles, of the still-liquid lying over the `index`-th interior column (0 = the column just inside
	# the left wall) above that column's own floor; 0 when there is none, the index is out of range, or the basin
	# is empty. Crust and a void read as no liquid, like has_liquid_at_column(). Read-only: the sensor's column
	# mode reads this rather than a map column so it never needs the basin's tilemap origin.
	if _footprint_width <= 0 or index < 0 or index >= _footprint_width or fill_volume <= 0.0:
		return 0.0
	return maxf(floor_rows[index + 1] - get_liquid_surface_row(), 0.0)

func get_fill_fraction() -> float:
	# 0..1, how full the basin currently is. A basin with no real capacity (_capacity_volume == 0)
	# reads as always full — see _capacity_volume's own comment for why that's the correct call, not
	# an edge-case oversight. Counts matter (liquid + crust) against capacity; a void left by a drain
	# is empty space and doesn't count.
	if _capacity_volume <= 0.0:
		return 1.0
	return clampf((fill_volume + crust_volume) / _capacity_volume, 0.0, 1.0)

func is_full() -> bool:
	# True when the basin's OUTER surface has reached its spill point — the trigger for same-type
	# liquid creeping out over the shorter wall. Without crust that's a plain volume comparison.
	# With crust it's the crust's top face reaching the rim, regardless of what's been drained
	# beneath it: a crust hanging at rim level is still a rim-level surface for anything above.
	# A basin with no capacity at all reads as always full.
	if _capacity_volume <= 0.0:
		return true
	if has_crust:
		return crust_top_row <= floor_rows[spill_column] + 0.001
	return fill_volume >= _capacity_volume

func _max_fill_volume() -> float:
	# The most liquid this basin can hold right now: up to the spill point, or — once crusted — only
	# up to the crust's underside, since the crust is rigid and the liquid can't lift it.
	if has_crust:
		return minf(_capacity_volume, _volume_for_surface_row(crust_bottom_row))
	return _capacity_volume

func add_volume(amount: float) -> float:
	# Credits liquid volume, clamped to _max_fill_volume(); returns whatever portion of amount
	# didn't fit (0.0 if it all fit). WaterManager's absorb step calls this with
	# LiquidConstants.PARTICLE_VOLUME per settled same-type particle (only ever on a crust-free
	# basin — see _try_absorb()); the leftover return is mostly a safety valve.
	var space: float = maxf(_max_fill_volume() - fill_volume, 0.0)
	var accepted: float = minf(amount, space)
	fill_volume += accepted
	queue_redraw()  # the drawn liquid body's height tracks fill_volume live
	if not is_processing():
		_update_process_state()  # a skinned liquid animates while there is any
	return amount - accepted

func remove_volume(amount: float) -> float:
	# Symmetric debit, clamped at 0; returns whatever portion of amount couldn't be removed (0.0 if
	# fill_volume covered it in full). This is the drain: WaterFaucet calls it once per drained
	# particle. It only ever touches fill_volume, never the crust — the crust is rigid stored
	# geometry, so lowering the liquid simply opens a void between the liquid surface and the
	# crust's underside. No redraw of crust or collision rebuild is needed, only the liquid body.
	var removed: float = minf(amount, fill_volume)
	fill_volume -= removed
	queue_redraw()
	if not is_processing():
		_update_process_state()  # a drain can uncover the skin under a crust, which then animates
	return amount - removed

const LIQUID_CONTACT_TOLERANCE_TILES := 0.05
	# How far (in tiles, ~0.8px) the liquid surface may sit below the crust's underside and still count
	# as touching it. Absorbs float noise and the sliver a single drained particle leaves in a wide
	# basin; a real drain opens a gap well past this.

const CRUST_THICKNESS_TILES := 0.75
	# The crust's fixed thickness: every crust is exactly this thick from the moment it forms and never grows,
	# thins or moves (matches the crust art, whose 12 visible rows are 0.75 of a tile). The thickness must stay
	# comfortably above ~0.5 tile: player.gd's swim probe sits only swim_probe_offset_y above the collider's
	# centre and compares against the liquid surface (level with the crust's underside while the two touch), so
	# with a paper-thin crust the probe ends up BELOW it while the player stands normally on the crust's top,
	# misreads them as submerged, flips is_swimming on, and swim's sink/gravity lets them descend straight
	# through solid ground to the basin floor. Only a basin too shallow to hold this much liquid ends up with a
	# thinner crust: it is clipped at the seabed like any other shape.

func convert_to_crust(_amount: float = 0.0) -> float:
	# The water/slag reaction: an opposite-type particle arriving solidifies the top of this basin's settled
	# liquid into a crust. It happens once per basin: the crust's top face is the liquid surface at that moment
	# and its bottom face is CRUST_THICKNESS_TILES below it, all at once. The liquid between those faces
	# becomes crust (fill_volume drops to what sits beneath), so the remaining liquid's own surface meets the
	# crust's underside exactly. An existing crust is never grown, thinned or moved, and this returns
	# `_amount` untouched (nothing converted); a basin with nothing to react with also returns it untouched.
	# `_amount` is unused now that the thickness is fixed; callers still pass one particle's volume.
	# Returns the portion of the request that couldn't be converted: 0.0 when the crust forms.
	if _footprint_width <= 0 or fill_volume <= 0.0 or has_crust:
		return _amount
	var top_row: float = get_liquid_surface_row()
	fill_volume = minf(fill_volume, _volume_for_surface_row(top_row + CRUST_THICKNESS_TILES))
	has_crust = true
	crust_top_row = top_row
	crust_bottom_row = get_liquid_surface_row()
	_crust_cool_t = 0.0  # the new crust plays its cooling frames
	queue_redraw()
	_rebuild_crust_collision()
	_lift_blocks_onto_crust()
	_clear_ripple()  # the liquid's top is now hidden under solid crust; nothing left to ripple
	return 0.0

## A crust forms exactly where blocks float: a buoyant block rides with most of its body under the surface, i.e. inside the
## new slab. Every block whose centre is in or above the slab and that overlaps it over a crust column is lifted straight up
## until its lowest point rests on the crust's collision top (MeltableBlock.lift_clear_of_crust(); the actors riding it go
## with it), for both kinds of crust. A block whose centre is already below the slab (sunk on the seabed, or hanging under it)
## is left where it is. Thawing needs no counterpart: with the crust gone the block falls in and floats again.
func _lift_blocks_onto_crust() -> void:
	if Engine.is_editor_hint() or not has_crust or not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(&"water_solid"):
		if node.has_method(&"lift_clear_of_crust"):
			node.lift_clear_of_crust(self)

## Public form of the column test the player's embedded latch uses: whether the world rect overlaps a column of this basin
## that carries crust.
func is_rect_over_crust(rect: Rect2) -> bool:
	return _rect_over_crust(rect)

func _detect_width_by_wall_scan() -> int:
	# Auto width detection for width_tiles == WIDTH_AUTO: scans rightward from this node's own column
	# (_origin_cell.x), at this node's own ROW (_origin_cell.y — not scanned downward like
	# _scan_column_floor() does), for the first column with a solid ("ground") tile there.
	# Relies on this file's own placement convention (see the top-of-file comment): the origin sits one
	# tile above (or level with) the basin's expected water surface, so AT that exact row an INTERIOR
	# column is still open air — its floor lies further down — while a WALL column, tall enough to
	# actually hold the liquid in, already has solid ground right there. The anchor's own column
	# (offset 0) is the left wall by definition of where this node was placed, so the scan starts at
	# offset 1; the first solid column found is the right wall, and width_tiles (both walls inclusive)
	# is that column's offset + 1. Falls back to whatever resolved_width_tiles already held (with a
	# warning), rather than a hardcoded guess, if nothing solid turns up within MAX_SCAN_TILES — most
	# likely a missing/misaligned wall tile, or a basin shape the scan's straight-line assumption can't
	# find at all, either way something width_tiles' own manual override exists to fix.
	for offset in range(1, MAX_SCAN_TILES):
		if SurfaceTypes.is_ground_like(SurfaceTypes.surface_at_cell(_world_tilemap, Vector2i(_origin_cell.x + offset, _origin_cell.y))):
			return offset + 1
	push_warning("WaterBasin at %s: auto width detection found no right wall within %d tiles — set width_tiles manually to override" % [global_position, MAX_SCAN_TILES])
	return maxi(2, resolved_width_tiles)

func _scan_column_floor(col: int, start_row: int) -> int:
	# Scans downward from start_row for the first solid tile (SurfaceTypes.is_ground_like()). Returns that tile's row, or start_row +
	# MAX_SCAN_TILES (with a warning) if nothing solid turns up in range.
	for row in range(start_row, start_row + MAX_SCAN_TILES):
		if SurfaceTypes.is_ground_like(SurfaceTypes.surface_at_cell(_world_tilemap, Vector2i(col, row))):
			return row
	push_warning("WaterBasin at %s: no floor found under column %d within %d tiles — check placement" % [global_position, col, MAX_SCAN_TILES])
	return start_row + MAX_SCAN_TILES

func _tile_top_surface_local_y(cell: Vector2i, sample_x: float) -> float:
	# Shared by _sample_tile_floor_offset() and _sample_tile_seabed_offset() below: where `cell`'s
	# own physics-layer-0 collision polygon's TOP surface sits, in tile-local space, at the vertical
	# line local x = sample_x — i.e. the y of the first solid boundary an object falling straight
	# down through that x would land on, not just any vertex the polygon happens to have below it.
	# This is what makes the seabed sampler below safe against a tile like a floating diagonal ledge
	# (solid band with open space both above AND below it): only an edge that's actually the top of
	# the solid region can be "the topmost crossing," so the ledge's underside is never mistaken for
	# a floor no matter how deep it sits in the tile.
	#
	# Reads TileData's own physics-layer collision-polygon points directly rather than a physics
	# query (PhysicsRayQueryParameters2D, as WaterManager's runtime particle collision uses) —
	# a @tool script has no guaranteed synced physics space to query at edit time, but this polygon
	# data is part of the TileSet resource itself and is available unconditionally. This project's
	# tileset defines exactly one physics layer (index 0; see the level scene's TileSetAtlasSource
	# resources), matching the "world" convention in objon.md's physics-layer notes.
	#
	# Returns INF if no edge of the polygon crosses sample_x at all (this x has no collision in this
	# tile whatsoever) — callers decide their own fallback for that, since "no collision here" means
	# different things to a center sample (this tile was already confirmed solid, so assume fully
	# solid) versus an edge sample (this tile may genuinely be open at that edge; see
	# _sample_tile_seabed_offset()'s own comment).
	var tile_data := _world_tilemap.get_cell_tile_data(cell)
	if tile_data == null:
		return INF
	const PHYSICS_LAYER := 0
	var top_local_y := INF
	for p in range(tile_data.get_collision_polygons_count(PHYSICS_LAYER)):
		var points := tile_data.get_collision_polygon_points(PHYSICS_LAYER, p)
		var n := points.size()
		for e in range(n):
			var a: Vector2 = points[e]
			var b: Vector2 = points[(e + 1) % n]
			if (a.x <= sample_x and b.x >= sample_x) or (a.x >= sample_x and b.x <= sample_x):
				var y: float
				if is_equal_approx(a.x, b.x):
					y = minf(a.y, b.y)  # vertical edge sitting exactly on sample_x: take its topmost point
				else:
					y = lerpf(a.y, b.y, (sample_x - a.x) / (b.x - a.x))
				top_local_y = minf(top_local_y, y)
	return top_local_y

func _sample_tile_floor_offset(cell: Vector2i) -> float:
	# Phase 10.1: how far into `cell` (already confirmed a surface_type ground tile by
	# _scan_column_floor above) the tile's own solid collision surface actually starts, as a fraction
	# of one tile height — 0.0 at the very top edge (a fully-solid tile; identical to every column's
	# value before this phase), toward 1.0 the closer the solid surface sits to the tile's bottom
	# edge. Sampled at the tile's horizontal center only — one scalar per column, not a continuous
	# curve across it (see the Phase 10.1 STATUS note near the top of this file for what that does
	# and doesn't capture for a sloped tile).
	var half_height := _tile_size.y * 0.5
	var top_local_y := _tile_top_surface_local_y(cell, 0.0)
	if is_inf(top_local_y):
		top_local_y = -half_height  # no polygon crosses the tile's own center — fall back to "fully solid"
		# (this tile was already confirmed ground by _scan_column_floor, so "no data" should
		# read as the least surprising case, not as "no floor")
	return clampf((top_local_y + half_height) / _tile_size.y, 0.0, 1.0)

func _sample_tile_seabed_offset(cell: Vector2i) -> float:
	# Phase 10.3 refinement: for seabed_floor_rows (see its own comment for why this needs to differ
	# from _sample_tile_floor_offset() above) — the LOWER (deeper, higher-y) of this tile's own top
	# surface at its left edge versus its right edge, per the fix worked out in review: taking any
	# vertex of the polygon (the original version of this function) picks up the UNDERSIDE of a tile
	# like a floating diagonal ledge — a solid band with open space both above and below it — since
	# the underside's vertices can sit deeper than anything at either actual edge, drawing the seabed
	# all the way down to near the tile's bottom with visible open space between the real ledge
	# surface and the drawn water. Probing only the two edges' TOP surfaces (via
	# _tile_top_surface_local_y(), which by construction can't return an underside) and keeping the
	# worse of the two still biases the drawn floor deep enough to avoid a gap at a sloped tile's
	# lower edge (the original goal this field was added for), without that bias also reaching all
	# the way down to a hollow shape's floor.
	var half_width := _tile_size.x * 0.5
	var half_height := _tile_size.y * 0.5
	var left_y := _tile_top_surface_local_y(cell, -half_width)
	var right_y := _tile_top_surface_local_y(cell, half_width)
	if is_inf(left_y):
		left_y = half_height  # this tile has no collision at all at its left edge — treat that edge as
		# fully open/deep rather than fully solid: unlike the center sample above, there's no prior
		# confirmation that THIS edge in particular is solid, and biasing deep is the same
		# no-visible-gaps call seabed_floor_rows already makes everywhere else
	if is_inf(right_y):
		right_y = half_height
	var deepest_edge_y := maxf(left_y, right_y)
	return clampf((deepest_edge_y + half_height) / _tile_size.y, 0.0, 1.0)

# --- Surface ripple (cosmetic) ---------------------------------------------------------------------
# A splash, a landing particle or a drain visibly disturbs the top edge of the settled liquid, and the
# disturbance travels sideways and dies away. Purely a drawing effect: fill_volume, the surface height
# every query returns, collision and the crust are all untouched, and get_body_polygon_world() still
# reports the flat shape. Only _draw_settled_body() bends the liquid's top edge (via _get_drawn_body_polygons()).
#
# Model: the interior is cut into RIPPLE_SUBDIVISIONS samples per tile column, each with a height and a
# vertical speed. Every fixed step (RIPPLE_STEP) a sample is accelerated by its neighbours (a discrete wave
# equation, so a wave crosses the basin at LiquidProfile.ripple_speed px/s), pulled back to rest by
# RIPPLE_RESTORE and slowed by LiquidProfile.ripple_damping. That is the "dynamic water" spring technique
# with the wave speed made explicit, so viscosity is data: slag's profile is slow, heavily damped and only
# weakly stirred, water's is fast and lively. Ripples travel only through strips over wet columns, so they
# reflect off walls and off a dry hump, and no ripple is ever drawn over crust.
#
# Cost: nothing while calm. disturb() switches _process on; once every sample has settled the arrays are
# zeroed and _process switches itself off again.
#
# Callers (all one-liners, all optional): WaterManager._try_absorb() for particles landing, WaterFaucet for
# a drain, the player for swim entry and a swimming wake, MeltableBlock for splashes.

func disturb(world_x: float, velocity_px_s: float, radius_px: float = 6.0) -> void:
	# Kicks the surface near world_x: adds velocity_px_s (negative = downward, what a falling object does)
	# to the samples within radius_px, fading out with a cosine falloff. Scaled by this liquid's
	# ripple_strength, so the same call stirs slag less than water. Ignored in the editor, on an empty
	# basin, and while the liquid is covered by crust.
	if Engine.is_editor_hint() or _ripple_blocked() or seabed_floor_rows.is_empty():
		return
	var profile := LiquidConstants.profile(liquid_type)
	var amount := velocity_px_s * profile.ripple_strength
	if is_zero_approx(amount) or profile.ripple_speed <= 0.0:
		return
	_ensure_ripple_arrays()
	if _ripple_wet_frame != Engine.get_physics_frames():
		_refresh_ripple_wet()
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	var first_x := global_position.x + _tile_size.x  # x of sample 0: the left edge of the first interior column
	radius_px = maxf(radius_px, spacing)
	var first := maxi(0, ceili((world_x - radius_px - first_x) / spacing))
	var last := mini(_ripple_h.size() - 1, floori((world_x + radius_px - first_x) / spacing))
	for p in range(first, last + 1):
		if not _ripple_point_wet(p):
			continue
		var distance := absf(first_x + p * spacing - world_x)
		if distance >= radius_px:
			continue
		var falloff := 0.5 * (1.0 + cos(PI * distance / radius_px))
		_ripple_v[p] = clampf(_ripple_v[p] + amount * falloff, -LiquidConstants.RIPPLE_MAX_VELOCITY, LiquidConstants.RIPPLE_MAX_VELOCITY)
	_ripple_live = true
	_ripple_moving = true
	set_process(true)

func _process(delta: float) -> void:
	var redraw := false
	if _ripple_live:
		if _ripple_blocked():
			_clear_ripple()
		else:
			_refresh_ripple_wet()
			_ripple_accum = minf(_ripple_accum + delta, 0.1)  # bounded so a long hitch can't queue a burst of steps
			while _ripple_accum >= LiquidConstants.RIPPLE_STEP:
				_ripple_accum -= LiquidConstants.RIPPLE_STEP
				_ripple_moving = _ripple_step(LiquidConstants.RIPPLE_STEP)
			if _ripple_moving:
				redraw = true
			else:
				_clear_ripple()
	if _electrified_left > 0.0:
		_electrified_left = maxf(0.0, _electrified_left - delta)
		_zap_age += delta
		redraw = true  # the flash flickers every frame, and one more redraw clears it when the time runs out
	if _advance_skin(delta):
		redraw = true
	if redraw:
		queue_redraw()
	if not _needs_process():
		set_process(false)

func _ripple_blocked() -> bool:
	# Nothing to ripple: no interior, no liquid, or the liquid's top is level with (hidden by) a crust.
	return _footprint_width <= 0 or fill_volume <= 0.0 or (has_crust and liquid_touches_crust())

func _ensure_ripple_arrays() -> void:
	var strips := _footprint_width * LiquidConstants.RIPPLE_SUBDIVISIONS
	if _ripple_h.size() != strips + 1:
		_ripple_h.resize(strips + 1)
		_ripple_v.resize(strips + 1)
		_ripple_strip_wet.resize(strips)
		_ripple_h.fill(0.0)
		_ripple_v.fill(0.0)

func _clear_ripple() -> void:
	_ripple_live = false
	_ripple_moving = false
	_ripple_accum = 0.0
	_ripple_h.fill(0.0)
	_ripple_v.fill(0.0)
	_update_process_state()  # a skin animation may still need _process
	queue_redraw()

func _refresh_ripple_wet() -> void:
	# A strip is wet when its column's seabed sits below the liquid surface: the same test
	# _build_column_runs() uses to decide which columns are drawn, so a ripple exists exactly where liquid does.
	_ripple_wet_frame = Engine.get_physics_frames()
	var sub := LiquidConstants.RIPPLE_SUBDIVISIONS
	var surface_y := get_liquid_surface_world_y()
	for col in range(_footprint_width):
		var seabed_y := global_position.y + (seabed_floor_rows[col + 1] - _origin_cell.y) * _tile_size.y
		var wet := 1 if (fill_volume > 0.0 and seabed_y > surface_y) else 0
		for k in range(sub):
			_ripple_strip_wet[col * sub + k] = wet

func _ripple_point_wet(p: int) -> bool:
	# A sample is live if either strip touching it is wet.
	return (p > 0 and _ripple_strip_wet[p - 1] == 1) or (p < _ripple_strip_wet.size() and _ripple_strip_wet[p] == 1)

func _ripple_step(dt: float) -> bool:
	# One fixed step of the wave. Returns true while anything is still moving. Every acceleration is computed
	# from the old heights before any height moves (semi-implicit Euler), which keeps it stable.
	var profile := LiquidConstants.profile(liquid_type)
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	# Wave speed is capped so a wave never crosses more than 0.9 of a sample per step (the stability limit
	# for this scheme is 1.0), whatever a profile asks for.
	var reach := minf(profile.ripple_speed * dt / spacing, 0.9)
	var c2 := (reach / dt) * (reach / dt)  # (wave speed / sample spacing)^2
	var strips := _ripple_strip_wet.size()
	var samples := _ripple_h.size()
	for p in range(samples):
		if not _ripple_point_wet(p):
			_ripple_v[p] = 0.0
			continue
		var h := _ripple_h[p]
		var laplacian := 0.0
		if p > 0 and _ripple_strip_wet[p - 1] == 1:
			laplacian += _ripple_h[p - 1] - h
		if p < strips and _ripple_strip_wet[p] == 1:
			laplacian += _ripple_h[p + 1] - h
		var accel := c2 * laplacian - LiquidConstants.RIPPLE_RESTORE * h - profile.ripple_damping * _ripple_v[p]
		_ripple_v[p] = clampf(_ripple_v[p] + accel * dt, -LiquidConstants.RIPPLE_MAX_VELOCITY, LiquidConstants.RIPPLE_MAX_VELOCITY)
	# A full basin's surface is level with its shorter wall's top, so a crest may not rise above it.
	var max_up := 0.0 if is_full() else LiquidConstants.RIPPLE_MAX_HEIGHT_PX
	var moving := false
	for p in range(samples):
		if not _ripple_point_wet(p):
			_ripple_h[p] = 0.0
			continue
		_ripple_h[p] = clampf(_ripple_h[p] + _ripple_v[p] * dt, -LiquidConstants.RIPPLE_MAX_HEIGHT_PX, max_up)
		if absf(_ripple_h[p]) > LiquidConstants.RIPPLE_SETTLE_HEIGHT or absf(_ripple_v[p]) > LiquidConstants.RIPPLE_SETTLE_VELOCITY:
			moving = true
	return moving

func _wall_pad_px() -> float:
	# The drawn overlap into each wall column, whole strips only, never more than one tile.
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	return floorf(clampf(wall_overlap_px, 0.0, _tile_size.x) / spacing) * spacing

func _run_touches_left_wall(run_cols: Array[int]) -> bool:
	return run_cols[0] == 1

func _run_touches_right_wall(run_cols: Array[int]) -> bool:
	return run_cols[run_cols.size() - 1] == resolved_width_tiles - 2

func _run_strips(run_cols: Array[int], top_y: float, bottom_cap_y: float, rippled: bool, with_walls: bool = false) -> PackedVector3Array:
	# One entry per ripple-sample strip (RIPPLE_SUBDIVISIONS per column) of a run: x = the strip's left edge, y = the
	# top of the skin there, z = the bottom of what the strip may draw (its column's seabed, capped). Tops are
	# whole world pixels, so the art stays pixel-crisp as the fill level and ripple move continuously. A live
	# ripple offsets each strip by the mean of its two samples; the clamp keeps a strip above its own seabed.
	var sub := LiquidConstants.RIPPLE_SUBDIVISIONS
	var spacing := _tile_size.x / float(sub)
	var live := rippled and _ripple_live
	var first_sample := (run_cols[0] - 1) * sub
	var strips := PackedVector3Array()
	for i in range(run_cols.size()):
		var col_y := minf(
			global_position.y + (seabed_floor_rows[run_cols[i]] - _origin_cell.y) * _tile_size.y,
			bottom_cap_y)
		var col_left := global_position.x + run_cols[i] * _tile_size.x
		for k in range(sub):
			var y := top_y
			if live:
				var j := first_sample + i * sub + k
				y = minf(top_y - 0.5 * (_ripple_h[j] + _ripple_h[j + 1]), maxf(col_y - 0.5, top_y))
			y = minf(roundf(y), col_y - 0.5)
			strips.append(Vector3(col_left + k * spacing, y, col_y))
	if with_walls:
		# Pad strips behind the wall columns: each copies the height and floor of the edge strip it continues, so
		# the extension is a flat continuation hidden behind the wall tile.
		var pad := _wall_pad_px()
		var pad_count := roundi(pad / spacing)
		if pad_count > 0:
			var left_pad := PackedVector3Array()
			if _run_touches_left_wall(run_cols):
				var edge := strips[0]
				for n in range(pad_count, 0, -1):
					left_pad.append(Vector3(edge.x - n * spacing, edge.y, edge.z))
			var right_pad := PackedVector3Array()
			if _run_touches_right_wall(run_cols):
				var edge := strips[strips.size() - 1]
				for n in range(1, pad_count + 1):
					right_pad.append(Vector3(edge.x + n * spacing, edge.y, edge.z))
			left_pad.append_array(strips)
			left_pad.append_array(right_pad)
			strips = left_pad
	return strips

func _draw_body_strips(color: Color, top_y: float) -> void:
	# The liquid body below the skin as filled rectangles, one per ripple strip, from the strip's (rippled) top
	# down to its column's seabed: exactly the area the stepped polygon covered. Strip x positions are multiples
	# of the strip width from the basin's own left edge, so neighbours share edges with no seam.
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	for run_variant in _collect_runs(top_y, INF):
		var run_cols: Array[int] = run_variant
		for strip in _run_strips(run_cols, top_y, INF, true, true):
			var height := strip.z - strip.y
			if height <= 0.0:
				continue
			draw_rect(Rect2(to_local(Vector2(strip.x, strip.y)), Vector2(spacing, height)), color)

func _debug_check_body_polygons() -> void:
	# Diagnostic (debug_check_body): would the OLD polygon body have failed to triangulate this frame? Logs the
	# ripple state when it would. Warnings that line up with a visible flicker confirm the cause.
	for world_points in _get_drawn_body_polygons():
		var local_points := PackedVector2Array()
		local_points.resize(world_points.size())
		for i in range(world_points.size()):
			local_points[i] = to_local(world_points[i])
		if Geometry2D.triangulate_polygon(local_points).is_empty():
			push_warning("%s: body polygon would fail triangulation (frame %d, ripple_live=%s, %d points): %s" % [name, Engine.get_process_frames(), _ripple_live, local_points.size(), local_points])

func _draw_skin_strips(skin: LiquidSkin, frame: int, top_y: float, bottom_cap_y: float, rippled: bool) -> void:
	# Draws the skin art over the body: for each strip, the art's opaque rows starting at the strip's top, cut off
	# at the strip's own bottom so a shallow column (or a thin crust) never shows art past its floor. The
	# source x is relative to the basin's own left edge, so the sideways tiling lines up across columns.
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	for run_variant in _collect_runs(top_y, bottom_cap_y):
		var run_cols: Array[int] = run_variant
		for strip in _run_strips(run_cols, top_y, bottom_cap_y, rippled, true):
			var rows := mini(skin.visible_rows, floori(strip.z - strip.y))
			if rows <= 0:
				continue
			var src_x := fposmod(strip.x - global_position.x, float(LiquidSkin.TILE))
			draw_texture_rect_region(
				skin.texture,
				Rect2(to_local(Vector2(strip.x, strip.y)), Vector2(spacing, rows)),
				Rect2(src_x, frame * LiquidSkin.TILE + skin.headroom, spacing, rows))

func _draw_crust_strips(skin: LiquidSkin, frame: int, top_y: float, bottom_y: float, over_void: bool) -> void:
	# The crust art, strip by strip like _draw_skin_strips(), from the crust's top face down to its bottom face. Over liquid
	# (over_void false) it is the cut art: the fringe is transparent and the liquid body drawn behind shows through. Over a void
	# it is the art's backed texture, whose interior fringe is neutral and whose underside fringe (below each column's last
	# neutral pixel) is transparent, so the crust is exactly as thick as its neutral pixels and never filled down to the face.
	# A column the seabed clips short of the crust's bottom face is the exception: it rests on the floor, so a transparent
	# underside there would show a gap above the floor tile, and that strip gets a neutral rect down to the seabed first.
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	var texture: Texture2D = skin.backed_texture if over_void else skin.texture
	var backing := skin.neutral_color(frame)
	for run_variant in _collect_runs(top_y, bottom_y):
		var run_cols: Array[int] = run_variant
		var strips := _run_strips(run_cols, top_y, bottom_y, false, true)
		for i in range(strips.size()):
			var strip := strips[i]
			var rows := mini(skin.visible_rows, floori(strip.z - strip.y))
			if rows <= 0:
				continue
			var left := to_local(Vector2(strip.x, strip.y))
			# The strip's own column, clamped to the interior so a pad strip behind a wall reads its neighbour's floor.
			var column := clampi(floori((strip.x - global_position.x) / _tile_size.x), 1, resolved_width_tiles - 2)
			if over_void and _seabed_world_y(column) <= bottom_y + CRUST_SEAT_TOLERANCE:
				draw_rect(Rect2(left, Vector2(spacing, strip.z - strip.y)), backing)
			var src_x := fposmod(strip.x - global_position.x, float(LiquidSkin.TILE))
			draw_texture_rect_region(
				texture,
				Rect2(left, Vector2(spacing, rows)),
				Rect2(src_x, frame * LiquidSkin.TILE + skin.headroom, spacing, rows))

func _seabed_world_y(local_col: int) -> float:
	# World y of an interior column's real floor (not capped by any crust or liquid layer).
	return global_position.y + (seabed_floor_rows[local_col] - _origin_cell.y) * _tile_size.y

func _load_skins() -> void:
	_skins_loaded = true
	if ResourceLoader.exists(FROZEN_CRUST_SKIN_PATH):
		_frozen_crust_skin = LiquidSkin.new(load(FROZEN_CRUST_SKIN_PATH) as Texture2D, 0.0, true)  # fringe cut: see LiquidSkin
	for type in SKIN_BY_TYPE:
		var entry: Dictionary = SKIN_BY_TYPE[type]
		if ResourceLoader.exists(entry["path"]):
			_skins[type] = LiquidSkin.new(load(entry["path"]) as Texture2D, entry["fps"])
	for type in CRUST_SKIN_PATH_BY_TYPE:
		if ResourceLoader.exists(CRUST_SKIN_PATH_BY_TYPE[type]):
			_crust_skins[type] = LiquidSkin.new(load(CRUST_SKIN_PATH_BY_TYPE[type]) as Texture2D, 0.0, true)  # fringe cut: see LiquidSkin

func _liquid_skin() -> LiquidSkin:
	# The skin of this basin's liquid, or null (flat BODY_COLOR_BY_TYPE colour). Runtime only: the editor draws
	# its debug overlay instead of the settled body.
	if Engine.is_editor_hint():
		return null
	if not _skins_loaded:
		_load_skins()
	return _skins.get(liquid_type)

func _crust_skin_art() -> LiquidSkin:
	# The crust art for the liquid this basin holds, else the slag crust art, else null (flat CRUST_COLOR).
	if Engine.is_editor_hint():
		return null
	if not _skins_loaded:
		_load_skins()
	if crust_frozen and _frozen_crust_skin != null:
		return _frozen_crust_skin
	return _crust_skins.get(liquid_type, _crust_skins.get(LiquidConstants.LiquidType.SLAG))

func _crust_frame(skin: LiquidSkin) -> int:
	# The last frame is the cold, settled crust. While the player is embedded in a freshly frozen crust the cooling holds on the
	# frame before it, and the last frame shows once the crust has gone solid for the player (_release_embedded() redraws).
	var last := skin.frame_count - 1
	if _embedded:
		last = maxi(last - 1, 0)
	if _crust_cool_t >= CRUST_COOL_TIME:
		return last
	return mini(int(_crust_cool_t / CRUST_COOL_TIME * skin.frame_count), last)

func _liquid_hidden_by_crust() -> bool:
	# True while the liquid touches the crust's underside: it has no exposed surface of its own, so the skin
	# (and any ripple) is not drawn, and the slag under the crust is just the flat body colour. The skin
	# appears the moment a drain opens a gap past LIQUID_CONTACT_TOLERANCE_TILES.
	return has_crust and liquid_touches_crust()

func _needs_process() -> bool:
	# What keeps _process running: a live ripple, a crust still cooling, or a skinned liquid that is visible.
	if Engine.is_editor_hint():
		return false
	if _ripple_live or _electrified_left > 0.0:
		return true
	if has_crust and _crust_cool_t < CRUST_COOL_TIME and _crust_skin_art() != null:
		return true
	var skin := _liquid_skin()
	return skin != null and skin.fps > 0.0 and fill_volume > 0.0 and not _liquid_hidden_by_crust()

func _update_process_state() -> void:
	set_process(_needs_process())

func _advance_skin(delta: float) -> bool:
	# Steps the liquid skin's clock and the crust's cooling; true if either changed the frame to draw.
	var changed := false
	var skin := _liquid_skin()
	if skin != null and skin.fps > 0.0 and fill_volume > 0.0:
		_skin_time += delta
		var frame := int(_skin_time * skin.fps) % skin.frame_count
		if frame != _skin_frame:
			_skin_frame = frame
			changed = true
	var crust_skin := _crust_skin_art()
	if has_crust and crust_skin != null and _crust_cool_t < CRUST_COOL_TIME:
		var before := _crust_frame(crust_skin)
		_crust_cool_t += delta
		if _crust_frame(crust_skin) != before:
			changed = true
	return changed

func _get_drawn_body_polygons(top_y: float = INF) -> Array[PackedVector2Array]:
	# What _draw_settled_body() paints for the liquid: the same runs get_body_polygon_world() reports, but
	# with the top edge following the live ripple. Identical to it while no ripple is live.
	if _footprint_width <= 0:
		return []
	if is_inf(top_y):
		top_y = get_liquid_surface_world_y()  # the default: the liquid's own surface
	return _build_column_runs(top_y, INF, true, true)

func _append_rippled_top(points: PackedVector2Array, run_cols: Array[int], left_x: float, top_y: float, bottom_cap_y: float) -> void:
	# Left-to-right top edge of one run, one vertex per ripple sample. Each vertex is clamped to stay above
	# the seabed of both strips it touches (but never above the flat surface line, so it can't pop when the
	# ripple ends): the polygon can then never fold over its own stepped bottom, which Godot's triangulator
	# would reject (see the BUG FIX note on get_body_polygon_world()).
	var sub := LiquidConstants.RIPPLE_SUBDIVISIONS
	var spacing := _tile_size.x / float(sub)
	var strips := run_cols.size() * sub
	var first_sample := (run_cols[0] - 1) * sub
	var strip_bottoms := PackedFloat32Array()
	strip_bottoms.resize(strips)
	for i in range(run_cols.size()):
		var col_y := minf(
			global_position.y + (seabed_floor_rows[run_cols[i]] - _origin_cell.y) * _tile_size.y,
			bottom_cap_y)
		for k in range(sub):
			strip_bottoms[i * sub + k] = col_y
	for j in range(strips + 1):
		var limit := INF
		if j > 0:
			limit = minf(limit, strip_bottoms[j - 1])
		if j < strips:
			limit = minf(limit, strip_bottoms[j])
		var y := minf(top_y - _ripple_h[first_sample + j], maxf(limit - 0.5, top_y))
		points.append(Vector2(left_x + j * spacing, y))

func _draw() -> void:
	# Phase 5.1: this callback now serves two unrelated purposes gated on which mode is running —
	# see the STATUS note near the top of this file for why they're kept as two separate functions
	# below rather than merged into one long body: the editor overlay is a dev tool (bounds/
	# floor-height/waterline ticks), the settled body is what the player actually sees at runtime.
	if Engine.is_editor_hint():
		_draw_editor_debug_bounds()
	else:
		_draw_settled_body()
		if _electrified_left > 0.0 and is_frozen_crust():
			# A frozen crust conducts: the flash runs along its top face, drawn after the crust art so it is not covered.
			_draw_electric_layer(get_crust_top_world_y(), get_crust_bottom_world_y(), false)

func _draw_editor_debug_bounds() -> void:
	if not debug_draw_bounds or _world_tilemap == null or floor_rows.is_empty():
		return
	var tile_size := _tile_size

	var deepest_local_row := 0.0
	for col in range(resolved_width_tiles):
		deepest_local_row = maxf(deepest_local_row, floor_rows[col] - _origin_cell.y)
		# floor_rows entries are fractional as of Phase 10.1 (sub-tile floor position); the overlay
		# below draws each column's tick at its real fractional height rather than snapping to the
		# tile's top edge, which is a small accuracy bonus this debug view gets for free.

	# overall footprint: from this node's origin row down to the deepest column's floor, one tile
	# past it so the floor tile itself reads as "inside" the outline rather than sitting on its edge
	var extent := Rect2(Vector2.ZERO, Vector2(resolved_width_tiles * tile_size.x, (deepest_local_row + 1.0) * tile_size.y))
	draw_rect(extent, Color(0.2, 0.6, 1.0, 0.15), true)
	draw_rect(extent, Color(0.2, 0.6, 1.0, 0.6), false, 1.0)

	for col in range(resolved_width_tiles):
		var is_wall := col == 0 or col == resolved_width_tiles - 1
		var is_overridden := col < floor_row_override_enabled.size() and floor_row_override_enabled[col]
		var local_row := floor_rows[col] - _origin_cell.y
		var x := col * tile_size.x
		var y := local_row * tile_size.y
		var color := Color(0.9, 0.3, 0.2, 0.9) if is_wall else Color(0.3, 1.0, 0.4, 0.9)
		draw_line(Vector2(x, y), Vector2(x + tile_size.x, y), color, 2.0)
		# floor-height tick: horizontal line at the top of the detected floor tile in this column,
		# red for the two wall columns, green for interior/open columns
		if is_overridden:
			# small magenta square straddling the tick, so an overridden column reads differently
			# from an auto-derived one at a glance
			var mark_center := Vector2(x + tile_size.x * 0.5, y)
			draw_rect(Rect2(mark_center - Vector2(3, 3), Vector2(6, 6)), Color(1.0, 0.2, 1.0, 0.95), true)

	if initial_fill_depth_below_surface >= 0.0 and spill_column != OVERRIDE_NONE and _footprint_width > 0:
		# Roadmap step 14: cyan waterline across the interior span, at the surface row this basin's
		# authored starting depth actually targets. Computed directly from floor_rows[spill_column] +
		# the authored depth (the same "full row + depth" this basin's own _initial_fill_volume() uses
		# as its zero point) rather than round-tripping through a volume, and clamped to the empty
		# basin's own deepest floor row so an over-authored depth (deeper than this basin can hold)
		# draws sitting at the true floor instead of an impossible point below it — same bound
		# _volume_for_surface_row() enforces on the volume side, kept in sync here without needing to
		# actually call it. Replaces the old spill-column triangle that used to live here (see the
		# STATUS note near the top of this file for why that was removed rather than kept alongside
		# this).
		var full_row: float = floor_rows[spill_column]
		var target_row: float = minf(full_row + initial_fill_depth_below_surface, _sorted_interior_floor_rows[0])
		var fill_row := target_row - _origin_cell.y
		var fill_y := fill_row * tile_size.y
		var left_x := tile_size.x               # interior starts after column 0 (the left wall)
		var right_x := (resolved_width_tiles - 1) * tile_size.x  # interior ends before the right wall column
		var waterline_color := Color(0.3, 0.95, 1.0, 0.95)
		draw_line(Vector2(left_x, fill_y), Vector2(right_x, fill_y), waterline_color, 2.0)
		draw_line(Vector2(left_x, fill_y - 3), Vector2(left_x, fill_y + 3), waterline_color, 2.0)
		draw_line(Vector2(right_x, fill_y - 3), Vector2(right_x, fill_y + 3), waterline_color, 2.0)

func _draw_electric() -> void:
	# Placeholder look for an electrified pool (cosmetic only, nothing here is read by gameplay): a flickering tint over
	# the liquid, a bright line along its surface, short zigzag arcs jumping up from it, and a brighter bolt at the strike
	# point for the first moments. Everything follows the rippled surface: it is drawn from the same per-strip tops as
	# the liquid body (_collect_runs() / _run_strips()), so a ripple from the strike or a swimmer bends the line with
	# the water instead of leaving a straight line across it. The flicker step comes from the time since the strike, so
	# no randomness is stored and a pause freezes it.
	if _liquid_hidden_by_crust():
		return
	_draw_electric_layer(get_liquid_surface_world_y(), INF, true)

func _draw_electric_layer(top_y: float, bottom_cap_y: float, rippled: bool) -> void:
	# One flash layer (the tint, the surface line, the arcs and the strike's bolt) along a surface: the liquid's rippled surface,
	# or a frozen crust's flat top face (tinted down to its bottom face).
	var fade := clampf(_electrified_left / ELECTRIC_FADE_TIME, 0.0, 1.0)
	var step := int(_zap_age * ELECTRIC_FLICKER_HZ)
	var on := step % 2 == 0
	var spacing := _tile_size.x / float(LiquidConstants.RIPPLE_SUBDIVISIONS)
	var tint := Color(ELECTRIC_GLOW.r, ELECTRIC_GLOW.g, ELECTRIC_GLOW.b, (0.30 if on else 0.14) * fade)
	var line_color := Color(ELECTRIC_CORE.r, ELECTRIC_CORE.g, ELECTRIC_CORE.b, (1.0 if on else 0.55) * fade)
	var tops: Array[Vector2] = []  # (x of the strip's left edge, its rippled top y)
	var bolt := clampf(1.0 - _zap_age / 0.2, 0.0, 1.0)
	var bolt_top := Vector2.INF
	for run_variant in _collect_runs(top_y, bottom_cap_y):
		var run_cols: Array[int] = run_variant
		for strip in _run_strips(run_cols, top_y, bottom_cap_y, rippled):
			var depth := minf(strip.z - strip.y, ELECTRIC_TINT_DEPTH_TILES * _tile_size.y)
			if depth <= 0.0:
				continue
			draw_rect(Rect2(to_local(Vector2(strip.x, strip.y)), Vector2(spacing, depth)), tint)
			draw_rect(Rect2(to_local(Vector2(strip.x, strip.y)), Vector2(spacing, 1.0)), line_color)
			tops.append(Vector2(strip.x, strip.y))
			if _zap_x >= strip.x and _zap_x < strip.x + spacing:
				bolt_top = Vector2(_zap_x, strip.y)
	# Arcs: a few zigzags above the surface, their positions changing each flicker step.
	if not tops.is_empty():
		for a in range(maxi(2, tops.size() / 4)):
			var h := absi(hash(Vector3i(step, a, int(global_position.x))))
			var base: Vector2 = tops[h % tops.size()]
			var height := 2.0 + float((h >> 10) % 5)
			var p0 := base + Vector2(spacing * 0.5, 0.0)
			var p1 := p0 + Vector2(float((h >> 3) % 5) - 2.0, -height * 0.5)
			var p2 := p1 + Vector2(float((h >> 6) % 5) - 2.0, -height * 0.5)
			draw_polyline(PackedVector2Array([to_local(p0), to_local(p1), to_local(p2)]), line_color, 1.0)
	# The strike: a short vertical bolt at the spark's x that dies over the first 0.2 s, standing on the surface there.
	if bolt > 0.0 and bolt_top != Vector2.INF:
		draw_line(to_local(bolt_top + Vector2(0.0, -10.0 * bolt)), to_local(bolt_top + Vector2(0.0, 3.0)), Color(1, 1, 1, bolt), 2.0)

func _draw_settled_body() -> void:
	# Phase 5.1 (shape updated by 10.3): the actual gameplay-visible settled water — NOT the editor
	# debug overlay above (that one is explicitly scoped as an editor-time-only dev tool per "Debug
	# visualization" in water-mechanic.md, which rules out a runtime fill/volume overlay for TOOLING
	# purposes; this is production rendering of the water itself, a different thing entirely, just
	# sharing the same _draw() callback). As of Phase 10.3, get_body_polygon_world() traces the real
	# per-column floor instead of a flat-bottomed rectangle — any remaining mismatch (the sample is
	# per-column, not sub-column) is still hidden behind the tilemap regardless (z_index is set below
	# the tilemap's own in _rebuild()).
	#
	# get_body_polygon_world() can return more than one polygon (see its own BUG FIX note: a hump in
	# the middle of the interior that the current fill hasn't covered yet splits the drawn body into
	# separate pieces) — each is drawn with its own draw_colored_polygon() call. A single contour that
	# tried to cover a still-dry hump anyway used to pinch to zero height there, which Godot's
	# triangulator rejects outright with "Invalid polygon data, triangulation failed" — and because
	# triangulation is all-or-nothing for a contour, that failure meant NOTHING drew anywhere in the
	# basin, not just near the hump, until the fill rose enough to cover it. Splitting into one
	# well-formed polygon per actually-wet run fixes that at the source rather than working around the
	# triangulator.
	#
	# get_body_polygon_world() returns world-space points; draw_colored_polygon() below needs this
	# node's LOCAL space, so each point is converted with to_local(). This assumes the basin node
	# itself is unrotated and unscaled (true of every basin so far — they're placed tile-aligned like
	# the rest of this project's authored geometry) — a rotated/scaled basin would need the points'
	# full transform applied, not just to_local()'s translation.
	var skin := _liquid_skin()
	var liquid_color: Color = BODY_COLOR_BY_TYPE.get(liquid_type, BODY_COLOR_BY_TYPE[LiquidConstants.LiquidType.WATER])
	if skin != null:
		liquid_color = skin.bottom_color(_skin_frame)  # the body below the skin is the art's own bottom colour
	# Crust art has its fringe cut out (see LiquidSkin), so what is drawn behind it shows through. While the liquid still
	# touches the crust's underside that is the liquid itself: its body fill extends up to the crust's top face (the same
	# whole pixel the crust art starts at), and the liquid's surface art stays hidden, so the cut pixels read as the liquid
	# glowing through and there is only ever one surface. Once a drain opens a gap the body drops to its own surface (with
	# its surface art) and the crust is backed by its own neutral fill instead, so the underside over the void is neutral.
	var crust_skin := _crust_skin_art()
	var crust_top := roundf(get_crust_top_world_y())
	var liquid_behind_crust := has_crust and crust_skin != null and liquid_touches_crust()
	var body_top := crust_top if liquid_behind_crust else get_liquid_surface_world_y()
	if skin != null:
		# Skinned liquid: the body is one filled rectangle per ripple strip (the same staircase the polygon
		# traced), not a polygon. draw_colored_polygon() triangulates a contour all-or-nothing, and a ripple's
		# whole-pixel staircase occasionally produced a contour it rejected, which blanked the entire body for
		# that one frame. Rectangles have nothing to triangulate.
		_draw_body_strips(liquid_color, body_top)
		if debug_check_body:
			_debug_check_body_polygons()
	else:
		for world_points in _get_drawn_body_polygons(body_top):
			var local_points := PackedVector2Array()
			local_points.resize(world_points.size())
			for i in range(world_points.size()):
				local_points[i] = to_local(world_points[i])
			draw_colored_polygon(local_points, liquid_color)
	if skin != null and not _liquid_hidden_by_crust():
		_draw_skin_strips(skin, _skin_frame, get_liquid_surface_world_y(), INF, true)
	if _electrified_left > 0.0:
		_draw_electric()

	# Crust draws the same way, over the same _draw() callback, after the liquid so it is never occluded by
	# it (see the note on the liquid's void above). Its two faces are stored geometry: after a drain the
	# liquid's own top edge sits below the crust's underside and the gap between them is simply not drawn.
	# With crust art the top face is snapped to a whole pixel (collision keeps the exact value) and the art is the top layer,
	# its fringe transparent: over liquid the liquid body drawn above shows through; over a void the fringe inside the crust is
	# neutral (the art's backed texture) while the fringe below a column's last neutral pixel stays transparent, so the underside
	# is the art's own edge and not a flat line 1-2 px lower (see _draw_crust_strips()). Without the art, flat CRUST_COLOR.
	if not has_crust:
		return
	if crust_skin == null:
		for world_points in _build_column_runs(get_crust_top_world_y(), get_crust_bottom_world_y(), false, true):
			var local_points := PackedVector2Array()
			local_points.resize(world_points.size())
			for i in range(world_points.size()):
				local_points[i] = to_local(world_points[i])
			draw_colored_polygon(local_points, FROZEN_CRUST_COLOR if crust_frozen else CRUST_COLOR)
		return
	var frame := _crust_frame(crust_skin)
	var crust_bottom := roundf(get_crust_bottom_world_y())  # both faces on whole pixels: the 0.75-tile crust is exactly the art's 12 rows
	_draw_crust_strips(crust_skin, frame, crust_top, crust_bottom, not liquid_behind_crust)
