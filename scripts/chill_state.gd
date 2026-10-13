class_name ChillState
extends RefCounted
## The one chill model, shared by the player and every enemy (roadmap N3.2). A node that can be chilled keeps one of
## these, forwards `apply_chill(strength)` to `apply()`, calls `update(delta)` once per physics frame, multiplies its own
## walking / flying / sliding speed by `speed_scale()` and hands its sprite (or placeholder art) to `apply_tint_to()`.
##
## `level` (0..1) is the control effect: it rises at once to the strongest strength received since the last `update()`
## (overlapping sources take the MAXIMUM, never the sum) and fades linearly to nothing over DECAY_TIME after the last one,
## the shape of surf wetness. `speed_scale()` is `lerp(1, MIN_SCALE, level)`: chill slows and never roots, because
## MIN_SCALE is above zero. Runtime only, never saved: a restore calls `reset()`.
##
## `tint` (0..1) is the blue hue. It is a dwell: while a source is on the target it rises at 1 / TINT_RISE_TIME per second
## toward `level`, so a freshly lit target turns blue over TINT_RISE_TIME while its speed is already cut, and once the source
## leaves it follows `level` down, so the hue is gone as the speed returns. Hit flashes tween `modulate`; the tint uses
## `self_modulate`, so the two multiply and neither overwrites the other.

const MIN_SCALE := 0.5 ## Speed scale at full chill. Above zero: chill never removes control. One constant for the player and every enemy.
const DECAY_TIME := 0.5 ## s: from full chill to none after the last source.
const TINT_RISE_TIME := 1.0 ## s of sustained chill for the hue to reach full.
const TINT_COLOR := Color(0.45, 0.72, 1.0) ## What a node's own colours are multiplied by at full tint.

var level: float = 0.0 ## 0..1, smoothed
var tint: float = 0.0 ## 0..1, rises over TINT_RISE_TIME while chilled, never above `level`

var _input: float = 0.0 ## the strongest strength received since update() last ran
var _applied_tint: float = -1.0 ## the tint last written to a node, so an idle node costs nothing

## The chill contract's body: called every physics frame by whatever is chilling this node.
func apply(strength: float) -> void:
	_input = maxf(_input, clampf(strength, 0.0, 1.0))

## Once per physics frame, near the top of the owner's `_physics_process()`.
func update(delta: float) -> void:
	var lit := _input > 0.0
	level = maxf(_input, level - delta / DECAY_TIME)
	if lit:
		tint = minf(tint + delta / TINT_RISE_TIME, level)
	else:
		tint = minf(tint, level)
	_input = 0.0

## 1 when unchilled, MIN_SCALE at full chill.
func speed_scale() -> float:
	return lerpf(1.0, MIN_SCALE, level)

func is_chilled() -> bool:
	return level > 0.0

## The colour the node's `self_modulate` should be.
func tint_color() -> Color:
	return Color.WHITE.lerp(TINT_COLOR, tint)

## Writes the hue to `item.self_modulate`, only when it changed since the last write.
func apply_tint_to(item: CanvasItem) -> void:
	if item == null or not is_instance_valid(item) or is_equal_approx(tint, _applied_tint):
		return
	_applied_tint = tint
	item.self_modulate = tint_color()

## A restore, a respawn: no chill, no hue. Pass the node so its colour is put back at once.
func reset(item: CanvasItem = null) -> void:
	level = 0.0
	tint = 0.0
	_input = 0.0
	_applied_tint = -1.0
	if item != null:
		apply_tint_to(item)
