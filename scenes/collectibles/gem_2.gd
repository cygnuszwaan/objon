@tool
extends Area2D
# Bonus gem: a stretch-goal pickup worth `points`, not part of the level's completion requirement. Deliberately NOT in
# group "gem" (that group is what the player counts as the level's gem total and what Finish's unlock percentage is
# measured against), so collecting or skipping it never changes whether the finish unlocks. Same shape as gem_1.gd.
# Whatever touches it just needs add_points(amount) -> bool (duck-typed like collect_gem()/collect_medkit()).
#
# Power (roadmap 7.1, gem trails): a device in the power contract (see power_target.gd). Powered = present and
# collectible; unpowered = hidden with monitoring off. Unwired it is simply present, as it always was. `invert` is
# exported here, like the door's. The gem keeps no power state of its own to save: an uncollected gem re-derives from
# its restored sources through set_powered_initial(), and a collected one is absent from the snapshot.
# @tool only for the configuration warning below; nothing but that runs in the editor.

## Points awarded on pickup. Needs a `p<points>` animation in points_popup.tscn to show feedback (5, 10 and 50 exist).
@export var points: int = 50:
	set(value):
		points = value
		if is_node_ready():
			update_configuration_warnings()
## Inverts the power contract: present while unpowered, hidden while powered.
@export var invert: bool = false

const POPUP_SCENE := "res://scenes/effects/points_popup.tscn"
const RECHECK_FRAMES := 3  # physics frames after reappearing in which overlapping bodies are collected by polling

@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

var _present: bool = true  # runtime state: false while a power source has hidden it
var _taken: bool = false  # set on pickup so a second overlap in the same frame can't award twice
var _recheck_frames: int = 0

func _ready() -> void:
	set_physics_process(false)
	if Engine.is_editor_hint():
		update_configuration_warnings()
		return
	add_to_group(&"bonus_gem")
	add_to_group(&"saveable")
	sprite.play(&"idle")
	body_entered.connect(_on_body_entered)

# Authoring check as a plain method (the habit in objon.md) so a level validator can reuse it.
func get_points_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var art := _popup_art_points()
	if not art.is_empty() and not art.has(points):
		var existing := PackedStringArray()
		for value in art:
			existing.append(str(value))
		warnings.append("No points popup art for %d points (only %s exist), so pickup feedback shows nothing. Add a p%d animation to points_popup.tscn or use one of those values." % [points, ", ".join(existing), points])
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_points_warnings()

# The point values the popup scene has art for, read from its animations named `p<N>`.
func _popup_art_points() -> PackedInt32Array:
	var found := PackedInt32Array()
	var scene := load(POPUP_SCENE) as PackedScene
	if scene == null:
		return found
	var popup := scene.instantiate() as AnimatedSprite2D
	if popup == null:
		return found
	if popup.sprite_frames != null:
		for anim in popup.sprite_frames.get_animation_names():
			var text := String(anim)
			if text.begins_with("p") and text.substr(1).is_valid_int():
				found.append(text.substr(1).to_int())
	popup.free()
	found.sort()
	return found

# Saveable contract (see game.gd): no state beyond "still here" — a collected gem is absent from the snapshot and
# Game.apply() frees the fresh copy on restore, so points banked before a checkpoint can't be farmed again. Whether
# the gem is currently shown is power state, re-derived by PowerTarget after the restore, so it is not saved.
func save_state() -> Dictionary:
	return {}

func load_state(_d: Dictionary) -> void:
	pass

## Power contract: powered = present and collectible. PowerTarget has already applied `invert`.
func set_powered(on: bool) -> void:
	_set_present(on)

## The startup / restore apply: same state, and there is nothing to animate or play, so it is the same call.
func set_powered_initial(on: bool) -> void:
	_set_present(on)

func _set_present(on: bool) -> void:
	if on == _present or _taken:
		return
	_present = on
	visible = on
	# Deferred: a source such as a timed button can change state inside a physics callback, where Godot refuses to
	# change monitoring.
	set_deferred("monitoring", on)
	_recheck_frames = RECHECK_FRAMES if on else 0
	set_physics_process(on)

# A player standing where the gem reappears never "enters" it again, so poll for a few frames after it comes back.
func _physics_process(_delta: float) -> void:
	if _recheck_frames <= 0:
		set_physics_process(false)
		return
	_recheck_frames -= 1
	if not monitoring:
		return  # the deferred switch-on hasn't landed yet
	for body in get_overlapping_bodies():
		_on_body_entered(body)

func _on_body_entered(body: Node2D) -> void:
	if _taken or not _present:
		return
	if not body.has_method("add_points"):
		return
	if not body.add_points(points):
		return  # ignored (player dead or dancing): leave the gem where it is
	_taken = true
	# collectible2 is this pickup's sound: collectible1-3 are distinct sounds picked by number (variant 1 = collectible2;
	# the variant index wraps, so it plays collectible1 until the file exists).
	Audio.play(&"collectibles/collectible", 0.0, 1)
	set_deferred("monitoring", false)  # same double-collect guard as gem_1.gd
	hide()
	queue_free()
