@tool
class_name MetalBlock
extends MeltableBlock
## Meltable metal — the counterpart to IceBlock (shared body, heat, kick, hang and rider behaviour: see
## MeltableBlock). Heavy: not slippery, and a kick shunts it only slowly (metal_block.tscn sets a lower
## `shunt_speed` than the base default, so a kick is a nudge of about one tile). Turns into molten SLAG when
## heated:
##
##   - Laser: melts while a beam is on it (`melt_time`), like ice. Progress drains at `cool_rate` while
##     nothing is heating it.
##   - Slag: it floats on a SLAG basin (buoyancy below), but the slag is what melts it: while its bottom edge
##     is below the slag's liquid surface, progress rises over `slag_melt_time`. A block floated into slag is a
##     temporary raft; the timer is the level-design pressure to cross it quickly.
##   - Water: it doesn't float at all — it sinks to the basin floor, only slowed by drag.
##
## Melt output: one spawn_melt_particles(cell, SLAG) per 16px cell it covers. Slag on a water basin is the
## water-meets-slag reaction, so it crusts the water surface; slag landing on a slag basin (the normal end
## of a raft melting) simply rejoins it.
##
## Buoyant in SLAG only, via MeltableBlock._buoyant_accel() (`float_depth_fraction` 0.6 in the scene, plus
## rider load; the carrying-capacity lever works as on ice). Standing on it in slag is safe: the block's top
## sits above the surface, and the slag hazard only tests the player's own position. Liquid drag scales with
## the submerged fraction: `slag_drag` settles the bob, `water_drag` sets how fast it sinks (terminal speed
## about GRAVITY / water_drag, capped at MAX_FALL_SPEED). The same coefficients damp sideways motion, so a
## kicked block in liquid stops quickly.
##
## Bullets: `absorbs_bullets` is true in metal_block.tscn, so a cannon bullet is consumed with a ping and the block is unharmed
## (MeltableBlock.on_bullet_hit()): a metal block is a bullet shield.
##
## Placeholder art: grey steel that glows orange and sags toward transparency as melt_progress rises.

@export_group("Liquid drag")
@export var slag_drag: float = 6.0 ## 1/s damping in slag, scaled by the submerged fraction. Higher = less bob.
@export var water_drag: float = 3.0 ## 1/s damping in water, scaled by the submerged fraction. Sets how fast it sinks.
@export_group("")

var _slag_fraction: float = 0.0 ## submerged fraction in slag this frame, read by _touching_slag()

func _apply_forces(delta: float, riders: int) -> void:
	_slag_fraction = _submerged_fraction(LiquidConstants.LiquidType.SLAG)
	var in_water := _submerged_fraction(LiquidConstants.LiquidType.WATER)

	# gravity, or slag buoyancy in place of it (stops on landing: the base class zeroes a downward velocity
	# while it rests on a floor). Water doesn't float it: plain gravity, slowed by drag below.
	var accel_y := GRAVITY
	if buoyant and _slag_fraction > 0.0:
		accel_y = _buoyant_accel(_slag_fraction, riders, LiquidConstants.LiquidType.SLAG)
	var in_liquid := _slag_fraction > 0.0 or in_water > 0.0
	if in_liquid and not _was_submerged and velocity.y > SPLASH_MIN_SPEED:
		Audio.play_at(&"interactive/metal_splash", global_position)
		_splash_ripple(velocity.y)
	_was_submerged = in_liquid
	_integrate_gravity(accel_y, delta)

	var drag := 0.0
	if _slag_fraction > 0.0:
		drag = slag_drag * _slag_fraction
	elif in_water > 0.0:
		drag = water_drag * in_water
	if drag > 0.0:
		# implicit damping: stable at any drag/frame time
		if buoyant and _slag_fraction > 0.0:
			# floating: vertical drag is relative to the slag's own motion, so a raft at its rest fraction rides a
			# rising or draining level (MeltableBlock._damp_vertical_in_liquid())
			velocity.x /= 1.0 + drag * delta
			_damp_vertical_in_liquid(slag_drag, _slag_fraction, riders, LiquidConstants.LiquidType.SLAG, delta)
		else:
			velocity /= 1.0 + drag * delta
		if absf(velocity.x) < 0.5:
			velocity.x = 0.0  # the exponential tail never reaches zero on its own

func _touching_slag() -> bool:
	return _slag_fraction > 0.0

## Metal stalls a crusher's piston: the crusher sweeps its stroke for this (see MeltableBlock.jams_crusher()). A block
## that has melted is gone and no longer counts, though a jam it already caused stays latched.
func jams_crusher() -> bool:
	return not _melted

func _melt_liquid_type() -> int:
	return LiquidConstants.LiquidType.SLAG

func _melt_sound() -> StringName:
	return &"interactive/metal_melt"

func _shunt_sound() -> StringName:
	return &"interactive/metal_shunt"

func _draw_block(rect: Rect2) -> void:
	var size := rect.size
	var steel := Color(0.46, 0.5, 0.56)
	var hot := Color(1.0, 0.45, 0.1)
	var body := steel.lerp(hot, melt_progress)
	body.a = 1.0 - 0.3 * melt_progress
	draw_rect(rect, body)
	draw_rect(rect, Color(0.25, 0.28, 0.33, body.a).lerp(Color(1.0, 0.75, 0.3, body.a), melt_progress), false, 1.0)
	# rivets in each cell corner
	var rivet := Color(0.2, 0.22, 0.27, body.a).lerp(Color(1.0, 0.8, 0.4, body.a), melt_progress)
	for cy in size_tiles.y:
		for cx in size_tiles.x:
			var cell := rect.position + Vector2(cx, cy) * TILE
			for corner in [Vector2(3, 3), Vector2(13, 3), Vector2(3, 13), Vector2(13, 13)]:
				draw_rect(Rect2(cell + corner - Vector2(0.5, 0.5), Vector2(1, 1)), rivet)
	# highlight streak
	draw_line(rect.position + Vector2(2, 1.5), rect.position + Vector2(size.x - 2, 1.5), Color(1, 1, 1, 0.3 * body.a), 1.0)
