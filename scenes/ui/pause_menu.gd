class_name PauseMenu
extends CanvasLayer
## Placeholder pause menu: a dimmer, a title, one button per level in `LevelCatalog` and a Resume button. Built in
## code like the level-complete overlay, until real UI art exists; replace the whole scene then.
##
## `Game` owns it: it instances this on the `menu` action (Escape), pauses the tree, and frees it on resume or on
## a level pick. The scene's process mode is ALWAYS so its buttons work while the tree is paused. It does not read
## Escape itself (Game does, in both directions), so one press can't be handled twice.
##   `resume_requested`   the Resume button; Game closes the menu.
##   `level_chosen(id)`   a level button; Game clears the checkpoint and loads it (`Game.load_level()`).

signal resume_requested
signal level_chosen(id: StringName)

func _init() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.7)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # clicks never reach anything behind the menu
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	box.add_child(_label("PAUSED", 48))
	var resume := _button("Resume")
	resume.pressed.connect(func() -> void:
		Audio.play(&"ui/menu_select")
		resume_requested.emit())
	box.add_child(resume)

	box.add_child(_label("Levels", 22))
	var current: StringName = Game.current_level_id
	for row in LevelCatalog.entries():
		var id: StringName = row["id"]
		var text: String = row["title"] + ("  (restart)" if id == current else "")
		var button := _button(text)
		button.pressed.connect(func() -> void:
			Audio.play(&"ui/menu_select")
			level_chosen.emit(id))
		box.add_child(button)

	box.add_child(_label("Esc to resume", 18))
	resume.grab_focus.call_deferred()  # keyboard and gamepad navigation start on Resume

func _label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	return label

func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(280.0, 44.0)
	button.add_theme_font_size_override("font_size", 24)
	return button
