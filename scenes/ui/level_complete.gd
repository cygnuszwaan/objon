extends CanvasLayer
## Placeholder level-complete overlay, spawned by Finish once the level is won. Built in code (a dimmer, a
## title, the gem tally and a prompt) until real UI art exists; a proper results screen replaces this file.
## Input is ignored for ACCEPT_DELAY seconds so the jump the player was holding can't skip it.
##   `jump`     continues to the next level (`Game.load_level()`) when there is one.
##   `restart`  (R) is handled by the Game autoload as always, and is the replay when there is no next level.

const ACCEPT_DELAY := 0.6

var _next_id: StringName = &""
var _accepting: bool = false

func _init() -> void:
	layer = 10

func show_result(gems: int, total: int, next_id: StringName) -> void:
	_next_id = next_id
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	box.add_child(_label("LEVEL COMPLETE", 48))
	if total > 0:
		box.add_child(_label("Gems  %d / %d" % [gems, total], 28))
	box.add_child(_label("Press Jump to continue" if _next_id != &"" else "Press R to play again", 22))

	get_tree().create_timer(ACCEPT_DELAY, false).timeout.connect(func() -> void: _accepting = true)

func _label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	return label

func _unhandled_input(event: InputEvent) -> void:
	if _accepting and _next_id != &"" and event.is_action_pressed("jump"):
		get_viewport().set_input_as_handled()
		_accepting = false  # one press loads once
		Game.load_level(_next_id)
