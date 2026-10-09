#pragma once

#include <godot_cpp/classes/editor_plugin.hpp>
#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/tile_set.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot
{

class Node;
class Timer;
class PopupMenu;
class MenuButton;
class BulkCopyDialog;
class LayerCopyDialog;

// Editor plugin that augments the stock TileSet editor with copy/paste helpers.
// Because Godot's TileSet editor UI is internal (not exposed as GDExtension
// types) but its controls and the polygon editor's methods are registered in
// ClassDB, this plugin walks the editor node tree, finds the relevant menus by
// class name plus a known item label, and drives them through their bound
// methods/signals. All injection is idempotent and self-heals across rebuilds.
class TileSetHelperPlugin : public EditorPlugin
{
	GDCLASS(TileSetHelperPlugin, EditorPlugin);

	// Menu item ids kept well above the native ids so the editor's own handlers
	// ignore them (their switch statements fall through to default).
	enum MenuId
	{
		COPY_SHAPES = 10001,
		PASTE_SHAPES = 10002,
		BULK_COPY = 10003,
		LAYER_COPY = 10004,
	};

	Timer *scan_timer = nullptr;
	Ref<TileSet> current_tile_set;
	BulkCopyDialog *bulk_dialog = nullptr;
	LayerCopyDialog *layer_dialog = nullptr;

	// Shape clipboard (one PackedVector2Array per copied polygon). Held as a
	// member, not a global: godot::Array's constructor calls into the binding,
	// which is only valid after the extension is initialized.
	Array shape_clipboard;

	// Diagnostics (written to res://tileset_helper_debug.log).
	int _dbg_ticks = 0;
	int _scan_poly = 0;
	int _scan_tse = 0;
	int _last_poly = -1;
	int _last_tse = -1;
	bool _dbg_warned_poly_mb = false;
	bool _dbg_warned_src_mb = false;
	bool _dbg_injected_poly = false;
	bool _dbg_injected_src = false;

	void _scan_node(Node *p_node);
	void _inject_polygon_menu(Node *p_polygon_editor);
	void _inject_sources_menu(Node *p_tileset_editor);

	void _copy_shapes(Object *p_polygon_editor);
	void _paste_shapes(Object *p_polygon_editor);

	// Returns the shape editor the Ctrl+C / Ctrl+V hotkeys should act on: the
	// focused one, else the hovered one, else the single visible one (the common
	// case - usually only one polygon editor is shown at a time).
	Node *_find_active_polygon_editor() const;

	static MenuButton *_find_menu_button(Node *p_root, const String &p_item_substr);
	static int _find_item_by_text(PopupMenu *p_popup, const String &p_text_substr);

	// Resolve the TileSet to act on at click time. _edit() only fires when the
	// TileSet *resource* is the edited object; editing a tileset through a
	// TileMapLayer/TileMap node (the common case) never sets current_tile_set, so
	// we fall back to the inspector's edited object and then the node selection.
	Ref<TileSet> _resolve_tile_set() const;
	static Ref<TileSet> _tile_set_from_object(Object *p_obj);

protected:
	static void _bind_methods();

public:
	void _enter_tree() override;
	void _exit_tree() override;
	void _shortcut_input(const Ref<InputEvent> &p_event) override;
	String _get_plugin_name() const override;
	bool _handles(Object *p_object) const override;
	void _edit(Object *p_object) override;

	void _on_scan_timeout();
	void _on_polygon_menu_pressed(int p_id, Object *p_polygon_editor);
	void _on_sources_menu_pressed(int p_id, Object *p_tileset_editor);

	TileSetHelperPlugin();
};

} // namespace godot
