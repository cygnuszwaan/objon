extends AnimatedSprite2D
## One-shot "+N points" feedback. The caller sets `points` before adding it to the tree, positions it in world space
## (above the player's head) and forgets it: it plays the matching `p<points>` animation once at its authored fps,
## drifts `rise_px` further up over exactly that time (on top of the art's own upward motion), and frees itself on
## the last frame. A points value with no art logs a warning and shows nothing.

@export var points: int = 5
## Extra upward drift (px) over the animation. 0 = rely only on the motion drawn into the art.
@export var rise_px: float = 16.0

func _ready() -> void:
	# Moved from a tween in idle time, so physics interpolation would only make it stutter.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	z_index = 20  # in front of the player and the world
	var anim := StringName("p%d" % points)
	if not sprite_frames.has_animation(anim):
		push_warning("points_popup: no animation '%s' (no art for %d points)" % [anim, points])
		queue_free()
		return
	animation_finished.connect(queue_free)
	play(anim)
	_start_rise.call_deferred(anim)  # deferred: the spawner sets global_position after add_child(), i.e. after this runs

func _start_rise(anim: StringName) -> void:
	var duration := float(sprite_frames.get_frame_count(anim)) / sprite_frames.get_animation_speed(anim)
	if rise_px != 0.0 and duration > 0.0:
		create_tween().tween_property(self, "position:y", position.y - rise_px, duration)
