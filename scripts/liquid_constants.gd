class_name LiquidConstants

# Single source of truth for the particle-size/count/volume relationship AND (as of the water/slag
# split) every per-liquid-type physical property the rest of the liquid system reads from —
# water_manager.gd, basin.gd, player.gd. Renamed from water_constants.gd/WaterConstants now that a
# second liquid (slag) exists: nothing here is water-specific any more except the historical name of
# the default LiquidType entry. Lives in res://scripts/ per the project's own convention for shared
# helpers with no single owning scene.
#
# WHY THIS FILE EXISTS (particle size/count/volume): one tile of melting ice/metal always represents
# the same physical amount of liquid — but how many particles that splits into, and therefore how
# big/chunky each one renders and how hard each one shoves the player, is a feel question. Changing
# ACTIVE_PRESET is the one edit needed to try a different point on that spectrum; every liquid type
# shares the same particle granularity, since that's a rendering/performance choice, not a material
# property of water vs. slag.
#
# WHY A PER-TYPE PROFILE (creep speed, bounce, friction, push force, hazard, color): these ARE
# material properties, and per the design goal of minimal bifurcation between water and slag, they
# live as DATA (one entry per LiquidType) rather than as a second copy of water_manager.gd's physics
# code. Every place that used to read a flat constant now reads `profile(type).some_field` instead —
# the simulation code itself has exactly one implementation, branching on a type value it already
# carries per-particle/per-basin, not two parallel scripts.

enum ParticlesPerTilePreset { FOUR, FIVE, SEVEN, TEN, SIXTEEN, TWENTY_EIGHT, SIXTY_FOUR }

const ACTIVE_PRESET := ParticlesPerTilePreset.SIXTEEN
	# <<< THE ONE CONSTANT TO CHANGE to try a different particle size/count feel. Shared by every
	# LiquidType — see "WHY A PER-TYPE PROFILE" above for why this one stays flat instead of
	# per-type. Placeholder pending an in-editor tuning pass, not a considered final value.

const _PRESETS := {
	# preset -> [particles_per_tile, particle_pixel_size]. Sizes are hand-picked, not derived by a
	# formula: only FOUR (2x2), SIXTEEN (4x4), and SIXTY_FOUR (8x8) divide a 16px tile into a perfect
	# square grid. The rest are the closest whole-pixel size to an N-way even split of one tile's
	# area (16*16 = 256px²) that still renders as a clean integer pixel size.
	ParticlesPerTilePreset.FOUR: [4, 8],
	ParticlesPerTilePreset.FIVE: [5, 7],
	ParticlesPerTilePreset.SEVEN: [7, 6],
	ParticlesPerTilePreset.TEN: [10, 5],
	ParticlesPerTilePreset.SIXTEEN: [16, 4],
	ParticlesPerTilePreset.TWENTY_EIGHT: [28, 3],
	ParticlesPerTilePreset.SIXTY_FOUR: [64, 2],
}

# Derived as `static var`, not `const` — see the original file's own note: GDScript const
# initializers can't reliably index into another const Dictionary by a const key across all engine
# versions, while a static var's initializer runs as ordinary code once at script load.
static var PARTICLES_PER_TILE: int = _PRESETS[ACTIVE_PRESET][0]
static var PARTICLE_PIXEL_SIZE: int = _PRESETS[ACTIVE_PRESET][1]

static var PARTICLE_VOLUME: float = 1.0 / PARTICLES_PER_TILE
	# One particle's volume, in the same tile-area units basin.gd's fill_volume/crust_volume/
	# add_volume()/remove_volume()/convert_to_crust() use. Also the melt-spawn count for a whole-tile
	# burst (ice→water or metal→slag): one melting tile spawns PARTICLES_PER_TILE particles, each
	# worth PARTICLE_VOLUME, so the two conversions always agree by construction, for either liquid.

# --- Liquid types and per-type profile -----------------------------------------------------------

enum LiquidType { WATER, SLAG, STEAM }
	# STEAM is not a fillable basin liquid — no basin is ever authored with liquid_type = STEAM, and
	# it never accrues fill_volume/crust_volume anywhere. It's included in this enum rather than
	# given its own separate flag specifically so a particle's existing `_liquid_type` slot (one
	# PackedInt32Array entry, already needed to tell water and slag particles apart) can also carry
	# "this one's just a decorative puff," with nothing else in the particle-array shape needing to
	# grow — see "is_gas" below for what that unlocks.

class LiquidProfile:
	var creep_speed: float
	var bounce_restitution: float
	var slope_slide_friction: float
	var push_force_per_tile_volume: float
	var color_base: Color
	var is_hazardous: bool   # true => touching this liquid (flowing or settled) should hurt the player
	var is_gas: bool         # true => skips collision/absorb/push/hazard entirely; drifts and fades (STEAM)
	var lifetime: float      # seconds before force-despawn; liquids use the shared long safety-net
							  # value, STEAM uses a short one so a puff actually dissipates
	# Cosmetic surface ripple of a settled basin (see basin.gd's ripple section). Viscosity lives here:
	# slag's waves travel slowly, die fast, and are barely stirred; water's are the opposite.
	var ripple_speed: float      # px/s, how fast a wave travels along the surface
	var ripple_damping: float    # 1/s, velocity damping; higher = ripples die sooner
	var ripple_strength: float   # multiplier on every disturbance that stirs this liquid
	# Weight per tile of volume, in the same units as a MeltableBlock's `mass` (per 16px tile: ice 1, metal 4), which is
	# what a pool of this liquid weighs when it rests on a RotatingBody (see WaterManager.get_resting_torque()).
	var weight_per_tile_volume: float
	# Swimming in this liquid: px/s UPWARD the passive (no input) vertical velocity eases toward, so a
	# swimmer floats up instead of sinking. 0 = no buoyancy, the player's own swim_sink_speed applies.
	var swim_float_speed: float
	# Freeze ray (roadmap N3.2): true => a FROZEN crust of this liquid is only held while a freeze beam ends on it, and thaws
	# (WaterBasin.thaw()) a few physics frames after the last hit. False => it stays frozen until a laser melts it.
	var frozen_is_temporary: bool

	func _init(p_creep_speed: float, p_bounce_restitution: float, p_slope_slide_friction: float,
			p_push_force_per_tile_volume: float, p_color_base: Color, p_is_hazardous: bool,
			p_is_gas: bool, p_lifetime: float, p_ripple_speed: float = 0.0,
			p_ripple_damping: float = 0.0, p_ripple_strength: float = 0.0, p_weight_per_tile_volume: float = 0.0,
			p_swim_float_speed: float = 0.0, p_frozen_is_temporary: bool = false) -> void:
		creep_speed = p_creep_speed
		bounce_restitution = p_bounce_restitution
		slope_slide_friction = p_slope_slide_friction
		push_force_per_tile_volume = p_push_force_per_tile_volume
		color_base = p_color_base
		is_hazardous = p_is_hazardous
		is_gas = p_is_gas
		lifetime = p_lifetime
		ripple_speed = p_ripple_speed
		ripple_damping = p_ripple_damping
		ripple_strength = p_ripple_strength
		weight_per_tile_volume = p_weight_per_tile_volume
		swim_float_speed = p_swim_float_speed
		frozen_is_temporary = p_frozen_is_temporary

const PARTICLE_LIFETIME := 20.0
	# Shared safety-net lifetime for every non-gas liquid (an enclosed non-basin span, a particle
	# stuck against a wall, one that fell off the level) — kept as one flat constant, not part of the
	# per-type profile, since it isn't a material property water and slag would plausibly want to
	# differ on; only STEAM's profile below overrides it with something much shorter.
const PARTICLE_SHRINK_TIME := 16.0
	# Seconds before its lifetime cap over which a LIQUID particle's drawn size shrinks linearly to nothing, so a
	# stuck or stray particle fades out rather than popping. Render-only: collision, absorb and volume still use
	# the full PARTICLE_PIXEL_SIZE until the despawn. STEAM is excluded (it disperses by its own short lifetime).
const STEAM_LIFETIME := 1.6
	# Seconds before a steam particle is force-despawned regardless of position — this IS how a steam
	# column ends: there's no separate fade/alpha system, a particle that has not hit a ceiling just gets
	# removed. With STEAM_RISE_SPEED it sets the column's height (see STEAM_COLUMN_HEIGHT). Placeholder, untuned.
const STEAM_RISE_SPEED := 80.0
	# px/s, the constant speed a steam particle rises at (a terminal speed, not a ballistic arc: no gravity,
	# no deceleration). Placeholder, untuned; the surfer's lift (roadmap 4.3) is tuned against it.
const STEAM_COLUMN_HEIGHT := STEAM_RISE_SPEED * STEAM_LIFETIME
	# px, how far a particle rises over its life: 128 px, 8 tiles, an open column's height. Derived, never set.

static var _profiles: Dictionary = {}
	# LiquidType -> LiquidProfile, built lazily by profile() below (a static var initializer running
	# at script-load time couldn't yet safely reference PARTICLE_LIFETIME/STEAM_LIFETIME above in
	# every engine ordering guarantee — lazy init sidesteps that entirely, same caution as
	# PARTICLES_PER_TILE's own static-var-not-const reasoning above).

static func profile(type: LiquidType) -> LiquidProfile:
	if _profiles.is_empty():
		_profiles[LiquidType.WATER] = LiquidProfile.new(
			44.0,                       # creep_speed (CREEP_SPEED, unchanged from the water-only era)
			0.35,                       # bounce_restitution
			0.9,                        # slope_slide_friction
			24.0,                       # push_force_per_tile_volume (PUSH_FORCE_PER_TILE_VOLUME, unchanged)
			Color(0.2, 0.55, 0.9, 0.85),  # color_base (PARTICLE_COLOR_BASE, unchanged)
			false, false, PARTICLE_LIFETIME,
			60.0, 0.5, 1.0,             # ripple: quick, lively waves that take a couple of seconds to die
			1.0)                        # weight_per_tile_volume: a tile of water weighs what a tile of ice does
		_profiles[LiquidType.SLAG] = LiquidProfile.new(
			10.0,                       # creep_speed — slower than water per the design goal; also
										# kept below BOUNCE_MIN_IMPACT_SPEED same as water's, so a
										# creeping slag particle meeting a wall still resolves as a
										# slide rather than a bounce (see water_manager.gd's own note)
			0.15,                       # bounce_restitution — molten slag shouldn't bounce like water
			0.6,                        # slope_slide_friction — thicker, loses more speed per frame
			36.0,                       # push_force_per_tile_volume — hazardous liquid should read as
										# more insistent/dangerous to wade near than water, not less
			Color(0.95, 0.35, 0.1, 0.95), # color_base — molten orange, distinct from water's blue
			true, false, PARTICLE_LIFETIME,
			22.0, 2, 1.2,             # ripple: viscous — slow waves (~1/4 of water's speed), heavily damped, barely stirred
			3.0,                      # weight_per_tile_volume: molten metal, heavier than water but under solid metal's 4
			60.0,                     # swim_float_speed: strongly buoyant, so a player in slag drifts up toward the surface (and an escape) faster than water's slow sink
			true)                     # frozen_is_temporary: frozen slag holds only while a freeze beam is on it; frozen water stays until a laser melts it
		_profiles[LiquidType.STEAM] = LiquidProfile.new(
			0.0, 0.0, 0.0, 0.0,        # unused — is_gas below skips every code path that would read these
			Color(0.9, 0.9, 0.92, 0.5), # color_base — pale, translucent
			false, true, STEAM_LIFETIME)
	return _profiles[type]

const PUSH_CAP := 220.0
	# px/s, outer ceiling on the summed push vector's magnitude — see water_manager.gd's own comment
	# for the full reasoning (unchanged from the water-only era; the per-type push_force above scales
	# each particle's individual contribution, this remains the flat total-cap safety valve on top of
	# that, shared by every liquid type).

const FAUCET_JITTER_SPEED := 12.0
	# px/s — a spawned drip's initial horizontal velocity is randomized to ±this, regardless of which
	# liquid the faucet drips.

# --- Surface ripple (cosmetic) ---------------------------------------------------------------------
# Tuning shared by every liquid; the per-liquid parts (speed, damping, strength) are in profile().
# Nothing here touches fill_volume, collision or any gameplay query: it only bends the DRAWN top edge
# of a settled basin (see basin.gd, "Surface ripple").

const RIPPLE_SUBDIVISIONS := 4
	# Surface samples per 16px tile column. 4 = one every 4px, matching the default particle size.
const RIPPLE_STEP := 1.0 / 120.0
	# Fixed simulation timestep (s); the basin runs as many as the frame needs, so ripples look the same
	# at any frame rate.
const RIPPLE_RESTORE := 8.0
	# 1/s^2 spring pulling each sample back to the resting level, so a disturbance always settles flat
	# instead of leaving the surface permanently raised or lowered.
const RIPPLE_MAX_HEIGHT_PX := 3.0
	# Hard cap on how far a sample may leave the resting level (px).
const RIPPLE_MAX_VELOCITY := 90.0
	# Hard cap on a sample's vertical speed (px/s); keeps stacked disturbances from blowing up.
const RIPPLE_SETTLE_HEIGHT := 0.02
const RIPPLE_SETTLE_VELOCITY := 0.4
	# Below both of these everywhere, a basin's ripple is cleared and its per-frame work stops.
const RIPPLE_PARTICLE_IMPULSE := 0.05
	# A particle landing on a settled surface pushes it down by (particle speed * this) px/s, scaled by
	# PARTICLE_VOLUME so a finer preset (more, lighter particles) stirs the surface the same in total.
const RIPPLE_REFERENCE_PARTICLES_PER_TILE := 16.0
	# The preset RIPPLE_PARTICLE_IMPULSE was tuned against (SIXTEEN).
