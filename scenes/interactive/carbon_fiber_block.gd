@tool
class_name CarbonFiberBlock
extends MeltableBlock
## Carbon fiber: the light block that lasts (shared body, kick, hang, rider and launch behaviour: see MeltableBlock).
##
##   - Never melts. A beam only stops on it (on_laser_hit() does nothing, no melt progress, no `melt_time`), slag does not heat
##     it (_touching_slag() is false), and `_update_melt()` is empty, so a carbon fiber block is a permanent laser shield and,
##     on slag, a permanent raft. A level that wants a disposable shield or a timed raft offers no carbon fiber block.
##   - Light: `mass` 0.5 per tile in carbon_fiber_block.tscn (ice 1, metal 4). A lone 1x1 cannot press a weight plate whose
##     threshold is 2, and a see-saw reads it as a small load. A jump pad's vector is divided by max(mass, 1)^exponent, so a
##     1x1 carbon fiber block is launched like a 1x1 ice block and a bigger one lifts less.
##   - Buoyant in both water and slag (`float_depth_fraction` 0.6 in the scene, plus rider load): water and slag each float it, with
##     the drag of the liquid it is in (`liquid_drag` vertically, `liquid_drag_horizontal` sideways).
##   - Brittle (`brittle` true in the scene): a cannon bullet or a crusher's spike breaks it through dissolve(): a quiet fade,
##     no liquid, no steam. It jams nothing (jams_crusher() stays false).
##   - Walk-pushable (`walk_push_speed` 75 in the scene, half of walk speed): the one block a walking player can push
##     (see walk_shoved() in MeltableBlock). It coasts after the push only on a slippery floor.
##
## Placeholder art: a black woven tile drawn in code until sprites exist.

@export_group("Liquid drag")
@export var liquid_drag: float = 6.0 ## 1/s vertical damping while submerged, scaled by the submerged fraction. Higher = less bob.
@export var liquid_drag_horizontal: float = 1.2 ## 1/s sideways damping while submerged, scaled by the submerged fraction.
@export_group("")

## A beam stops on the block and does nothing else.
func on_laser_hit(_point: Vector2, _direction: Vector2) -> void:
	pass

## Never melts: no beam and no slag heats it.
func _update_melt(_delta: float) -> void:
	pass

func _apply_forces(delta: float, riders: int) -> void:
	var in_water := _submerged_fraction(LiquidConstants.LiquidType.WATER) if buoyant else 0.0
	var in_slag := _submerged_fraction(LiquidConstants.LiquidType.SLAG) if buoyant else 0.0
	var submerged := maxf(in_water, in_slag)
	var liquid_type: int = LiquidConstants.LiquidType.WATER if in_water >= in_slag else LiquidConstants.LiquidType.SLAG
	var accel_y := GRAVITY
	if submerged > 0.0:
		accel_y = _buoyant_accel(submerged, riders, liquid_type)
		if not _was_submerged and velocity.y > SPLASH_MIN_SPEED:
			_splash_ripple(velocity.y)
	_was_submerged = submerged > 0.0
	_integrate_gravity(accel_y, delta)
	if submerged > 0.0:
		_damp_vertical_in_liquid(liquid_drag, submerged, riders, liquid_type, delta)
		velocity.x /= 1.0 + liquid_drag_horizontal * submerged * delta
		if absf(velocity.x) < 0.5:
			velocity.x = 0.0  # the exponential tail never reaches zero on its own

## Breaks quietly: a fade, no liquid (see MeltableBlock._break_apart()).
func _break_apart() -> void:
	Audio.play_at(&"interactive/carbon_break", global_position)
	dissolve()

func _shunt_sound() -> StringName:
	return &"interactive/carbon_shunt"

func _draw_block(rect: Rect2) -> void:
	var ink := Color(0.09, 0.1, 0.12)
	var weave := Color(0.2, 0.22, 0.26)
	draw_rect(rect, ink)
	# a woven look: a checkerboard of 4px squares in each cell
	for cy in size_tiles.y:
		for cx in size_tiles.x:
			var cell := rect.position + Vector2(cx, cy) * TILE
			for gy in 4:
				for gx in 4:
					if (gx + gy) % 2 == 0:
						draw_rect(Rect2(cell + Vector2(gx, gy) * 4.0 + Vector2.ONE, Vector2(3, 3)), weave)
	draw_rect(rect, Color(0.32, 0.35, 0.4), false, 1.0)
