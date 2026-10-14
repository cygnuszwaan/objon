class_name LevelCatalog
extends RefCounted
## The playable levels as data, in play order: `id` (stable identity, what `Game` scopes checkpoints to), `title`
## (what a menu shows) and `path` (the scene file). The pause menu lists these, `Game.load_level(id)` loads one, and
## `next_after()` is what \"continue\" follows, so the order of a set of levels belongs here, not to each level. Add a
## level by adding a row; nothing else needs to know about it.
##
## This is the built-in provider. A level pack or a player-made level would be one more ordered list of the same
## rows (with a source other than a res:// path); `Game.load_level()` already takes a path or a PackedScene.
## An id is permanent once levels are shared: renaming one orphans anything that refers to it.

const LEVELS: Array[Dictionary] = [
	{"id": &"Level 1-1", "title": "Level 1-1", "path": "res://scenes/levels/level_1-1.tscn"},
	{"id": &"Level 1-2", "title": "Level 1-2", "path": "res://scenes/levels/level_1-2.tscn"},
	{"id": &"Level 1-3", "title": "Level 1-3", "path": "res://scenes/levels/level_1-3.tscn"},
	{"id": &"Level 1-4", "title": "Level 1-4", "path": "res://scenes/levels/level_1-4.tscn"},
	{"id": &"Level 1-5", "title": "Level 1-5", "path": "res://scenes/levels/level_1-5.tscn"},
	{"id": &"Level 1-6", "title": "Level 1-6", "path": "res://scenes/levels/level_1-6.tscn"},
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
