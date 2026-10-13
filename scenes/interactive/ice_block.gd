@tool
class_name IceBlock
extends MeltableBlock
## Meltable ice (shared body, heat, kick, hang and rider behaviour: see MeltableBlock). Bursts into WATER.
##
## Slag melts it much faster than the beam: while the block's bottom edge is below a SLAG basin's liquid
## surface (_touching_slag(): the rotated corners and bottom midpoint, each against its own column's basin; crust doesn't count) progress
## rises over `slag_melt_time`. The burst of water lands on the slag and crusts it.
##
## Slippery: is_slippery() -> true is the floor contract player.gd checks (see _floor_is_slippery()), so
## standing on any ice block gives the player ice-rink acceleration and friction.
##
## Buoyant in settled WATER: while its bottom edge is below the liquid surface of a WATER basin, gravity is
## replaced by MeltableBlock._buoyant_accel() (ice floats at ~80% submerged, `float_depth_fraction`), plus drag
## proportional to the submerged fraction: heavy vertically so the bob settles, light horizontally so a shunt
## or an underside push keeps drifting. Pushed under, it rises back with a small bob; dropped in, it sinks to
## the equilibrium waterline; resting on the seabed, it lifts off. Only the centre column is sampled, so a
## wide block half over a wall floats as if over its centre. Slag does not float it.
##
## Floating blocks can be nudged from below: an actor pressing on the underside of a block in water drags it
## sideways, toward `underside_push_factor` times the actor's own horizontal speed (never braking it — the
## water's drag does that). This is the only contact-driven horizontal influence an actor has (the block
## never rides an actor and MeltableBlock's shove guard discards sideways contact pushes), so removing
## _apply_underside_push() makes floating blocks immovable by swimming. A wide block is only sampled at its
## centre.
##
## Brittle (`brittle` true in ice_block.tscn): a crusher's spike or a cannon bullet breaks it through the ordinary melt path
## (see MeltableBlock.shatter() and on_bullet_hit()), so it bursts into water.

const ART := preload("res://sprites/interactive/ice.png") ## 16x112: frame 0 = solid block, frames 1-6 = melting.
const FRAME_COUNT := 7

const UNDERSIDE_PUSH_ACCEL := 300.0 ## px/s^2 the block accelerates toward the pushed speed at.

@export_range(0.05, 1.0) var surf_friction_scale: float = 0.25 ## Multiplier on a surfboard's ground friction while riding this block (0.25 = about four times the coasting distance of dry ground; lower = slicker).
@export_range(0.0, 1.0) var underside_push_factor: float = 0.25 ## How much of a swimmer's horizontal speed a floating block picks up when the swimmer pushes along its underside (0 = immovable, 1 = moves as fast as the swimmer).
@export_group("Liquid drag")
@export var water_drag: float = 6.0 ## 1/s vertical damping while submerged, scaled by the submerged fraction. Higher = less bob.
@export var water_drag_horizontal: float = 1.2 ## 1/s sideways damping while submerged, scaled by the submerged fraction. Deliberately much lower than water_drag so a shunt or a push from below keeps drifting (speed halves roughly every 0.6s / submerged fraction); higher = stops sooner, 0 = drifts until it hits something.
@export_group("")

## Floor contract read by player.gd's _floor_is_slippery().
func is_slippery() -> bool:
	return true

## Surf contract read by player.gd's _surf_floor_friction_scale(): multiplies the surfboard's ground friction while it
## rides this block, so ice coasts further than dry ground.
func get_surf_friction_scale() -> float:
	return surf_friction_scale

func _apply_forces(delta: float, riders: int) -> void:
	var submerged := _submerged_fraction(LiquidConstants.LiquidType.WATER) if buoyant else 0.0
	var accel_y := GRAVITY
	if submerged > 0.0:
		_apply_underside_push(delta)
		accel_y = _buoyant_accel(submerged, riders, LiquidConstants.LiquidType.WATER)
		if not _was_submerged and velocity.y > SPLASH_MIN_SPEED:
			Audio.play_at(&"interactive/ice_splash", global_position)
			_splash_ripple(velocity.y)
	_was_submerged = submerged > 0.0
	_integrate_gravity(accel_y, delta)
	if submerged > 0.0:
		# implicit damping: stable at any drag/frame time. Separate rates per axis: bobbing wants heavy
		# vertical damping, while sideways drift should carry on for a while.
		# (vertical drag is relative to the water's own motion, so a block at its rest fraction rides a rising or
		# draining level at any speed: see MeltableBlock._damp_vertical_in_liquid())
		_damp_vertical_in_liquid(water_drag, submerged, riders, LiquidConstants.LiquidType.WATER, delta)
		velocity.x /= 1.0 + water_drag_horizontal * submerged * delta
		if absf(velocity.x) < 0.5:
			velocity.x = 0.0  # the exponential tail never reaches zero on its own

## Accelerates the block toward the horizontal speed of an actor pressing on its underside (a thin band just
## under the bottom face), scaled by underside_push_factor. Only ever speeds the block up toward the push.
func _apply_underside_push(delta: float) -> void:
	if underside_push_factor <= 0.0:
		return
	var target := 0.0
	for body in _actors_in_band(_upright_size().y + 1.0, 4.0):
		var actor_vx: float = body.get("velocity").x if body.get("velocity") is Vector2 else 0.0
		if absf(actor_vx) > absf(target):
			target = actor_vx
	target *= underside_push_factor
	if target != 0.0:
		velocity.x = move_toward(velocity.x, target, UNDERSIDE_PUSH_ACCEL * delta)

## True while any part of the block is below the still-liquid surface of a SLAG basin (crust doesn't count, so
## a block resting on crust over slag is safe). See MeltableBlock._touching_liquid().
func _touching_slag() -> bool:
	return _touching_liquid(LiquidConstants.LiquidType.SLAG)

func _melt_liquid_type() -> int:
	return LiquidConstants.LiquidType.WATER

func _melt_sound() -> StringName:
	return &"interactive/ice_melt"

func _shunt_sound() -> StringName:
	return &"interactive/ice_shunt"

func _draw_block(rect: Rect2) -> void:
	# melt_progress picks the frame: 0 = solid, then the melt animation. Progress drains when the block cools,
	# so a refreezing block plays the animation backwards. A block bigger than one tile ping-pongs the middle of
	# the tile art (MeltableBlock._draw_art()) so it reads as one block, not a grid of tiles.
	var frame := clampi(int(melt_progress * FRAME_COUNT), 0, FRAME_COUNT - 1)
	_draw_art(ART, Vector2(0.0, frame * TILE), rect)
