class_name PauseMenu
extends CanvasLayer
## Placeholder pause menu, built in code like the level-complete overlay, until real UI art exists; replace the whole
## scene then. Three pages share one centred column:
##   Main      Resume, Restart level, Select level
##   Chapters  one button per chapter in `LevelCatalog.chapters()`, and Back
##   Levels    one button per level of the chosen chapter, and Back (to Chapters)
## The level list scrolls if a chapter outgrows the screen.
##
## `Game` owns it: it instances this on the `menu` action (Escape), pauses the tree, and frees it on resume or on
## a level pick. The scene's process mode is ALWAYS so its buttons work while the tree is paused. It does not read
## Escape itself (Game does, in both directions, and Escape always resumes from any page), so one press can't be
## handled twice.
##   `resume_requested`   the Resume button; Game closes the menu.
##   `level_chosen(id)`   Restart level (the current id) or a level button; Game clears the checkpoint and loads it
##                        (`Game.load_level()`, which restarts when the id is the current level).

signal resume_requested
signal level_chosen(id: StringName)

const LIST_HEIGHT := 380.0  # height of the scrolling chapter and level lists, px

var _box: VBoxContainer

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
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 12)
	center.add_child(_box)

	_show_main()

## Empties the column for the next page.
func _clear_page() -> void:
	for child in _box.get_children():
		_box.remove_child(child)
		child.queue_free()

func _show_main() -> void:
	_clear_page()
	_box.add_child(_label("PAUSED", 48))
	var resume := _button("Resume")
	resume.pressed.connect(func() -> void:
		Audio.play(&"ui/menu_select")
		resume_requested.emit())
	_box.add_child(resume)

	var restart := _button("Restart level")
	restart.pressed.connect(func() -> void:
		Audio.play(&"ui/menu_select")
		level_chosen.emit(Game.current_level_id))
	_box.add_child(restart)

	var select := _button("Select level")
	select.pressed.connect(func() -> void:
		Audio.play(&"ui/menu_select")
		_show_chapters())
	_box.add_child(select)

	_box.add_child(_label("Esc to resume", 18))
	resume.grab_focus.call_deferred()  # keyboard and gamepad navigation start on Resume

func _show_chapters() -> void:
	_clear_page()
	_box.add_child(_label("Select chapter", 36))
	var current_chapter := LevelCatalog.chapter_of(Game.current_level_id)
	var list := _scrolling_list()
	var focus: Button = null
	for chapter in LevelCatalog.chapters():
		var number: int = chapter["number"]
		var text := "Chapter %d: %s" % [number, chapter["title"]]
		if number == current_chapter:
			text += "  (current)"
		var button := _button(text)
		button.pressed.connect(func() -> void:
			Audio.play(&"ui/menu_select")
			_show_levels(number))
		list.add_child(button)
		if focus == null or number == current_chapter:
			focus = button
	_add_back_button(_show_main)
	if focus != null:
		focus.grab_focus.call_deferred()

func _show_levels(chapter_number: int) -> void:
	_clear_page()
	var title := "Chapter %d" % chapter_number
	for chapter in LevelCatalog.chapters():
		if chapter["number"] == chapter_number:
			title = "Chapter %d: %s" % [chapter_number, chapter["title"]]
	_box.add_child(_label(title, 36))
	var current: StringName = Game.current_level_id
	var list := _scrolling_list()
	var focus: Button = null
	for row in LevelCatalog.entries_in_chapter(chapter_number):
		var id: StringName = row["id"]
		var button := _button(row["title"] + ("  (current)" if id == current else ""))
		button.pressed.connect(func() -> void:
			Audio.play(&"ui/menu_select")
			level_chosen.emit(id))
		list.add_child(button)
		if focus == null or id == current:
			focus = button
	_add_back_button(_show_chapters)
	if focus != null:
		focus.grab_focus.call_deferred()

## A scroll area (fixed height, so the page doesn't jump between short and long lists) with a column inside; returns
## the column to add buttons to.
func _scrolling_list() -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320.0, LIST_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 12)
	scroll.add_child(list)
	return list

func _add_back_button(target: Callable) -> void:
	var back := _button("Back")
	back.pressed.connect(func() -> void:
		Audio.play(&"ui/menu_select")
		target.call())
	_box.add_child(back)

func _label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	return label

func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(320.0, 44.0)
	button.add_theme_font_size_override("font_size", 24)
	return button
