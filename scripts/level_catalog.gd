class_name LevelCatalog
extends RefCounted
## The playable levels as data, in play order: `id` (stable identity, what `Game` scopes checkpoints to), `title`
## (what a menu shows), `chapter` (the menu's grouping) and `path` (the scene file). The pause menu lists them by chapter, `Game.load_level(id)` loads one, and
## `next_after()` is what \"continue\" follows, so the order of a set of levels belongs here, not to each level. Add a
## level by adding a row; nothing else needs to know about it.
##
## This is the built-in provider. A level pack or a player-made level would be one more ordered list of the same
## rows (with a source other than a res:// path); `Game.load_level()` already takes a path or a PackedScene.
## An id is permanent once levels are shared: renaming one orphans anything that refers to it.

## Chapters, in play order: `number` (a level row's `chapter`) and `title`. `chapters()` lists only chapters that
## have at least one existing level.
const CHAPTERS: Array[Dictionary] = [
	{"number": 1, "title": "Footing"},
	{"number": 2, "title": "Momentum"},
	{"number": 3, "title": "Light"},
]

const LEVELS: Array[Dictionary] = [
	{"id": &"Level 1-1", "title": "Level 1-1", "chapter": 1, "path": "res://scenes/levels/level_1-1.tscn"},
	{"id": &"Level 1-2", "title": "Level 1-2", "chapter": 1, "path": "res://scenes/levels/level_1-2.tscn"},
	{"id": &"Level 1-3", "title": "Level 1-3", "chapter": 1, "path": "res://scenes/levels/level_1-3.tscn"},
	{"id": &"Level 1-4", "title": "Level 1-4", "chapter": 1, "path": "res://scenes/levels/level_1-4.tscn"},
	{"id": &"Level 1-5", "title": "Level 1-5", "chapter": 1, "path": "res://scenes/levels/level_1-5.tscn"},
	{"id": &"Level 1-6", "title": "Level 1-6", "chapter": 1, "path": "res://scenes/levels/level_1-6.tscn"},
	{"id": &"Level 1-7", "title": "Level 1-7", "chapter": 1, "path": "res://scenes/levels/level_1-7.tscn"},
	{"id": &"Level 1-8", "title": "Level 1-8", "chapter": 1, "path": "res://scenes/levels/level_1-8.tscn"},
	{"id": &"Level 2-1", "title": "Level 2-1", "chapter": 2, "path": "res://scenes/levels/level_2-1.tscn"},
	{"id": &"Level 2-2", "title": "Level 2-2", "chapter": 2, "path": "res://scenes/levels/level_2-2.tscn"},
	{"id": &"Level 2-3", "title": "Level 2-3", "chapter": 2, "path": "res://scenes/levels/level_2-3.tscn"},
	{"id": &"Level 2-4", "title": "Level 2-4", "chapter": 2, "path": "res://scenes/levels/level_2-4.tscn"},
	{"id": &"Level 2-5", "title": "Level 2-5", "chapter": 2, "path": "res://scenes/levels/level_2-5.tscn"},
	{"id": &"Level 2-6", "title": "Level 2-6", "chapter": 2, "path": "res://scenes/levels/level_2-6.tscn"},
	{"id": &"Level 3-1", "title": "Level 3-1", "chapter": 3, "path": "res://scenes/levels/level_3-1.tscn"},
]

## Prefix of the id made for a level that has no catalog row (a `Finish.next_level` path, or a scene the editor
## started): `path:res://...`. `source_of()` turns it back into the path.
const PATH_ID_PREFIX := "path:"

## The rows whose scene file exists (a row for a level that isn't there yet is skipped, with a warning if `warn`).
static func entries(warn: bool = true) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for row in LEVELS:
		if ResourceLoader.exists(row["path"]):
			found.append(row)
		elif warn:
			push_warning("LevelCatalog: no scene at '%s' (level '%s')." % [row["path"], row["id"]])
	return found

## The chapters that have at least one existing level, in order.
static func chapters() -> Array[Dictionary]:
	var present := {}
	for row in entries(false):
		present[row.get("chapter", 0)] = true
	var found: Array[Dictionary] = []
	for chapter in CHAPTERS:
		if present.has(chapter["number"]):
			found.append(chapter)
	return found

## The existing level rows of chapter `number`, in play order.
static func entries_in_chapter(number: int) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for row in entries(false):
		if row.get("chapter", 0) == number:
			found.append(row)
	return found

## The chapter number of level `id` (0 if it has no catalog row or no chapter).
static func chapter_of(id: StringName) -> int:
	return entry(id).get("chapter", 0)

## The row for `id`, or an empty Dictionary.
static func entry(id: StringName) -> Dictionary:
	for row in LEVELS:
		if row["id"] == id:
			return row
	return {}

## What `Game.load_level()` builds the level from: the row's path, the path inside a `path:` id, or null if unknown.
static func source_of(id: StringName) -> Variant:
	var row := entry(id)
	if not row.is_empty():
		return row["path"]
	var text := String(id)
	if text.begins_with(PATH_ID_PREFIX):
		return text.substr(PATH_ID_PREFIX.length())
	return null

## The id for a scene path: the catalog row with that path, else a `path:` id.
static func id_for_path(path: String) -> StringName:
	for row in LEVELS:
		if row["path"] == path:
			return row["id"]
	return StringName(PATH_ID_PREFIX + path)

## The id of the existing row after `id`, or &"" if `id` is last or not in the catalog.
static func next_after(id: StringName) -> StringName:
	var rows := entries(false)
	for i in rows.size():
		if rows[i]["id"] == id:
			return rows[i + 1]["id"] if i + 1 < rows.size() else &""
	return &""
