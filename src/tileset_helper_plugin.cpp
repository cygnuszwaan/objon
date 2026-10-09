#include "tileset_helper_plugin.h"

#include "bulk_copy_dialog.h"
#include "layer_copy_dialog.h"

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/editor_inspector.hpp>
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/editor_selection.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/menu_button.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/popup_menu.hpp>
#include <godot_cpp/classes/timer.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

// Diagnostics: append a line to a project-local log file (rewritten in full each
// call; volume is low because callers only log on state transitions) and also
// echo to the editor Output panel. The accumulation buffer is a function-local
// static so its godot::PackedStringArray is constructed on first call (after the
// extension binding is initialized), never at DLL load time.
static void dbg_log(const String &p_line)
{
	static PackedStringArray lines;
	lines.push_back(p_line);
	Ref<FileAccess> f = FileAccess::open("res://tileset_helper_debug.log", FileAccess::WRITE);
	if (f.is_valid())
	{
		for (int i = 0; i < lines.size(); i++)
		{
			f->store_line(lines[i]);
		}
		f->close();
	}
	UtilityFunctions::print("[TileSetHelper] ", p_line);
}

// Item labels we inject, used both to create and to detect-our-own items. The
// Ctrl+C / Ctrl+V hint is shown as a real popup accelerator (right-aligned), set
// after the items are added. The accelerator fires while the menu is open;
// _shortcut_input covers the same keys while a shape editor is hovered and the
// menu is closed (the open menu consumes the event, so the two never double up).
static const char *POLY_COPY_LABEL = "Copy Shape(s)";
static const char *POLY_PASTE_LABEL = "Paste Shape(s)";
static const char *SOURCES_BULK_LABEL = "Copy Physics/Navigation to Other Sources...";
static const char *SOURCES_LAYER_LABEL = "Copy Between Physics/Navigation...";

// Substrings of native menu labels used to locate the right MenuButton. Matching
// on the English editor labels is acceptable for this workspace.
static const char *POLY_MENU_PROBE = "Reset to default";
static const char *SOURCES_MENU_PROBE = "Atlas Merging";

TileSetHelperPlugin::TileSetHelperPlugin()
{
}

void TileSetHelperPlugin::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("_on_scan_timeout"), &TileSetHelperPlugin::_on_scan_timeout);
	ClassDB::bind_method(D_METHOD("_on_polygon_menu_pressed", "id", "polygon_editor"), &TileSetHelperPlugin::_on_polygon_menu_pressed);
	ClassDB::bind_method(D_METHOD("_on_sources_menu_pressed", "id", "tileset_editor"), &TileSetHelperPlugin::_on_sources_menu_pressed);
}

void TileSetHelperPlugin::_enter_tree()
{
	scan_timer = memnew(Timer);
	scan_timer->set_wait_time(0.4);
	scan_timer->set_one_shot(false);
	add_child(scan_timer);
	scan_timer->connect("timeout", Callable(this, "_on_scan_timeout"));
	scan_timer->start();
	// Needed for _shortcut_input to be delivered to this node.
	set_process_shortcut_input(true);
	dbg_log("enter_tree: plugin alive, scan timer started");
}

void TileSetHelperPlugin::_exit_tree()
{
	if (scan_timer)
	{
		scan_timer->stop();
	}
	if (bulk_dialog)
	{
		bulk_dialog->queue_free();
		bulk_dialog = nullptr;
	}
	if (layer_dialog)
	{
		layer_dialog->queue_free();
		layer_dialog = nullptr;
	}
}

void TileSetHelperPlugin::_shortcut_input(const Ref<InputEvent> &p_event)
{
	Ref<InputEventKey> key = p_event;
	if (key.is_null() || !key->is_pressed() || key->is_echo())
	{
		return;
	}
	if (!key->is_command_or_control_pressed())
	{
		return;
	}
	const Key code = key->get_keycode();
	const bool is_copy = (code == Key::KEY_C);
	const bool is_paste = (code == Key::KEY_V);
	if (!is_copy && !is_paste)
	{
		return;
	}

	Node *editor = _find_active_polygon_editor();
	if (!editor)
	{
		// No shape editor is active; let the event pass through untouched.
		return;
	}

	if (is_copy)
	{
		_copy_shapes(editor);
	}
	else
	{
		_paste_shapes(editor);
	}
	get_viewport()->set_input_as_handled();
}

static void collect_visible_poly_editors(Node *p_root, Vector<Control *> &r_out)
{
	if (p_root->get_class() == "GenericTilePolygonEditor")
	{
		Control *c = Object::cast_to<Control>(p_root);
		if (c && c->is_visible_in_tree())
		{
			r_out.push_back(c);
		}
	}
	const int count = p_root->get_child_count();
	for (int i = 0; i < count; i++)
	{
		collect_visible_poly_editors(p_root->get_child(i), r_out);
	}
}

Node *TileSetHelperPlugin::_find_active_polygon_editor() const
{
	EditorInterface *ei = EditorInterface::get_singleton();
	if (!ei)
	{
		return nullptr;
	}
	Control *base = ei->get_base_control();
	if (!base)
	{
		return nullptr;
	}

	Vector<Control *> editors;
	collect_visible_poly_editors(base, editors);
	if (editors.is_empty())
	{
		return nullptr;
	}

	Viewport *vp = base->get_viewport();
	if (vp)
	{
		// Prefer the editor that holds keyboard focus (you clicked into it).
		Control *focus = vp->gui_get_focus_owner();
		if (focus)
		{
			for (int i = 0; i < editors.size(); i++)
			{
				if (editors[i] == focus || editors[i]->is_ancestor_of(focus))
				{
					return editors[i];
				}
			}
		}
		// Otherwise the one the mouse is over (uses the GUI's own hover tracking).
		Control *hovered = vp->gui_get_hovered_control();
		if (hovered)
		{
			for (int i = 0; i < editors.size(); i++)
			{
				if (editors[i] == hovered || editors[i]->is_ancestor_of(hovered))
				{
					return editors[i];
				}
			}
		}
	}

	// Fall back to the single visible shape editor - almost always the case.
	if (editors.size() == 1)
	{
		return editors[0];
	}
	return nullptr;
}

String TileSetHelperPlugin::_get_plugin_name() const
{
	return "TileSetHelper";
}

bool TileSetHelperPlugin::_handles(Object *p_object) const
{
	return Object::cast_to<TileSet>(p_object) != nullptr;
}

void TileSetHelperPlugin::_edit(Object *p_object)
{
	TileSet *ts = Object::cast_to<TileSet>(p_object);
	if (ts)
	{
		current_tile_set = Ref<TileSet>(ts);
	}
}

void TileSetHelperPlugin::_on_scan_timeout()
{
	_dbg_ticks++;
	EditorInterface *ei = EditorInterface::get_singleton();
	if (!ei)
	{
		if (_dbg_ticks <= 3)
		{
			dbg_log("tick: no EditorInterface singleton");
		}
		return;
	}
	Control *base = ei->get_base_control();
	if (!base)
	{
		if (_dbg_ticks <= 3)
		{
			dbg_log("tick: no base control");
		}
		return;
	}

	_scan_poly = 0;
	_scan_tse = 0;
	_scan_node(base);

	if (_dbg_ticks <= 3 || _scan_poly != _last_poly || _scan_tse != _last_tse)
	{
		dbg_log("tick " + itos(_dbg_ticks) + ": base=" + base->get_class() + " polyEditors=" + itos(_scan_poly) + " tileSetEditors=" + itos(_scan_tse));
		_last_poly = _scan_poly;
		_last_tse = _scan_tse;
	}
}

void TileSetHelperPlugin::_scan_node(Node *p_node)
{
	if (!p_node)
	{
		return;
	}

	const String cls = p_node->get_class();
	if (cls == "GenericTilePolygonEditor")
	{
		_scan_poly++;
		_inject_polygon_menu(p_node);
	}
	else if (cls == "TileSetEditor")
	{
		_scan_tse++;
		_inject_sources_menu(p_node);
	}

	const int count = p_node->get_child_count();
	for (int i = 0; i < count; i++)
	{
		_scan_node(p_node->get_child(i));
	}
}

MenuButton *TileSetHelperPlugin::_find_menu_button(Node *p_root, const String &p_item_substr)
{
	if (!p_root)
	{
		return nullptr;
	}

	MenuButton *mb = Object::cast_to<MenuButton>(p_root);
	if (mb)
	{
		PopupMenu *popup = mb->get_popup();
		if (popup)
		{
			for (int i = 0; i < popup->get_item_count(); i++)
			{
				if (popup->get_item_text(i).contains(p_item_substr))
				{
					return mb;
				}
			}
		}
	}

	const int count = p_root->get_child_count();
	for (int i = 0; i < count; i++)
	{
		MenuButton *found = _find_menu_button(p_root->get_child(i), p_item_substr);
		if (found)
		{
			return found;
		}
	}
	return nullptr;
}

int TileSetHelperPlugin::_find_item_by_text(PopupMenu *p_popup, const String &p_text_substr)
{
	if (!p_popup)
	{
		return -1;
	}
	for (int i = 0; i < p_popup->get_item_count(); i++)
	{
		if (p_popup->get_item_text(i).contains(p_text_substr))
		{
			return i;
		}
	}
	return -1;
}

void TileSetHelperPlugin::_inject_polygon_menu(Node *p_polygon_editor)
{
	MenuButton *mb = _find_menu_button(p_polygon_editor, POLY_MENU_PROBE);
	if (!mb)
	{
		if (!_dbg_warned_poly_mb)
		{
			dbg_log("polygon editor found, but advanced MenuButton (probe '" + String(POLY_MENU_PROBE) + "') NOT located");
			_dbg_warned_poly_mb = true;
		}
		return;
	}
	PopupMenu *popup = mb->get_popup();
	if (!popup)
	{
		return;
	}

	// Keep the connection alive independently of the items: the editor may rebuild
	// the popup contents (wiping our items) without dropping the connection, or
	// vice versa. Re-add whichever is missing.
	const Callable cb = Callable(this, "_on_polygon_menu_pressed").bind(p_polygon_editor);
	if (!popup->is_connected("id_pressed", cb))
	{
		popup->connect("id_pressed", cb);
	}

	if (_find_item_by_text(popup, POLY_COPY_LABEL) == -1)
	{
		popup->add_separator();
		popup->add_item(POLY_COPY_LABEL, COPY_SHAPES);
		popup->add_item(POLY_PASTE_LABEL, PASTE_SHAPES);
		// Show the shortcut as a proper right-aligned accelerator hint.
		const Key copy_accel = (Key)((int64_t)KeyModifierMask::KEY_MASK_CMD_OR_CTRL | (int64_t)Key::KEY_C);
		const Key paste_accel = (Key)((int64_t)KeyModifierMask::KEY_MASK_CMD_OR_CTRL | (int64_t)Key::KEY_V);
		popup->set_item_accelerator(popup->get_item_index(COPY_SHAPES), copy_accel);
		popup->set_item_accelerator(popup->get_item_index(PASTE_SHAPES), paste_accel);
		if (!_dbg_injected_poly)
		{
			dbg_log("injected Copy/Paste into polygon editor menu");
			_dbg_injected_poly = true;
		}
	}
}

void TileSetHelperPlugin::_inject_sources_menu(Node *p_tileset_editor)
{
	MenuButton *mb = _find_menu_button(p_tileset_editor, SOURCES_MENU_PROBE);
	if (!mb)
	{
		if (!_dbg_warned_src_mb)
		{
			dbg_log("TileSetEditor found, but sources advanced MenuButton (probe '" + String(SOURCES_MENU_PROBE) + "') NOT located");
			_dbg_warned_src_mb = true;
		}
		return;
	}
	PopupMenu *popup = mb->get_popup();
	if (!popup)
	{
		return;
	}

	const Callable cb = Callable(this, "_on_sources_menu_pressed").bind(p_tileset_editor);
	if (!popup->is_connected("id_pressed", cb))
	{
		popup->connect("id_pressed", cb);
	}

	if (_find_item_by_text(popup, "Copy Physics/Navigation to Other") == -1)
	{
		popup->add_separator();
		popup->add_item(SOURCES_BULK_LABEL, BULK_COPY);
		popup->add_item(SOURCES_LAYER_LABEL, LAYER_COPY);
		if (!_dbg_injected_src)
		{
			dbg_log("injected bulk-copy and layer-copy items into Tile Sources menu");
			_dbg_injected_src = true;
		}
	}
}

void TileSetHelperPlugin::_on_polygon_menu_pressed(int p_id, Object *p_polygon_editor)
{
	if (p_id == COPY_SHAPES)
	{
		_copy_shapes(p_polygon_editor);
	}
	else if (p_id == PASTE_SHAPES)
	{
		_paste_shapes(p_polygon_editor);
	}
}

void TileSetHelperPlugin::_copy_shapes(Object *p_polygon_editor)
{
	if (!p_polygon_editor)
	{
		return;
	}
	shape_clipboard.clear();
	const int n = (int)(int64_t)p_polygon_editor->call("get_polygon_count");
	for (int i = 0; i < n; i++)
	{
		const PackedVector2Array poly = p_polygon_editor->call("get_polygon", i);
		shape_clipboard.push_back(poly);
	}
	UtilityFunctions::print("[TileSetHelper] Copied ", n, " shape(s).");
}

void TileSetHelperPlugin::_paste_shapes(Object *p_polygon_editor)
{
	if (!p_polygon_editor || shape_clipboard.is_empty())
	{
		return;
	}
	p_polygon_editor->call("clear_polygons");
	int pasted = 0;
	for (int i = 0; i < shape_clipboard.size(); i++)
	{
		const PackedVector2Array poly = shape_clipboard[i];
		if (poly.size() < 3)
		{
			continue;
		}
		p_polygon_editor->call("add_polygon", poly, -1);
		pasted++;
	}
	// Mirrors what user edits do: the owning TileData editor listens for
	// polygons_changed and commits the working polygons back to the tile.
	p_polygon_editor->emit_signal("polygons_changed");
	UtilityFunctions::print("[TileSetHelper] Pasted ", pasted, " shape(s).");
}

Ref<TileSet> TileSetHelperPlugin::_tile_set_from_object(Object *p_obj)
{
	if (!p_obj)
	{
		return Ref<TileSet>();
	}
	// The object itself is a TileSet (standalone resource being edited)...
	if (TileSet *ts = Object::cast_to<TileSet>(p_obj))
	{
		return Ref<TileSet>(ts);
	}
	// ...or it owns one through a "tile_set" property (TileMapLayer, TileMap).
	const Variant v = p_obj->get("tile_set");
	if (v.get_type() == Variant::OBJECT)
	{
		Object *o = v;
		if (TileSet *ts = Object::cast_to<TileSet>(o))
		{
			return Ref<TileSet>(ts);
		}
	}
	return Ref<TileSet>();
}

Ref<TileSet> TileSetHelperPlugin::_resolve_tile_set() const
{
	if (current_tile_set.is_valid())
	{
		return current_tile_set;
	}

	EditorInterface *ei = EditorInterface::get_singleton();
	if (!ei)
	{
		return Ref<TileSet>();
	}

	// What the inspector is showing right now: the TileSet resource, or a node
	// (TileMapLayer / TileMap) that owns one. This is the case _edit() misses.
	if (EditorInspector *insp = ei->get_inspector())
	{
		Ref<TileSet> ts = _tile_set_from_object(insp->get_edited_object());
		if (ts.is_valid())
		{
			return ts;
		}
	}

	// Last resort: a selected node that owns a TileSet.
	if (EditorSelection *sel = ei->get_selection())
	{
		const TypedArray<Node> nodes = sel->get_selected_nodes();
		for (int i = 0; i < nodes.size(); i++)
		{
			Object *n = nodes[i];
			Ref<TileSet> ts = _tile_set_from_object(n);
			if (ts.is_valid())
			{
				return ts;
			}
		}
	}
	return Ref<TileSet>();
}

void TileSetHelperPlugin::_on_sources_menu_pressed(int p_id, Object *p_tileset_editor)
{
	if (p_id != BULK_COPY && p_id != LAYER_COPY)
	{
		return;
	}
	Ref<TileSet> resolved = _resolve_tile_set();
	if (resolved.is_null())
	{
		UtilityFunctions::push_warning("[TileSetHelper] No edited TileSet is available.");
		return;
	}
	// Cache so the dialogs (and any follow-up press) use the same instance.
	current_tile_set = resolved;

	EditorInterface *ei = EditorInterface::get_singleton();
	if (!ei)
	{
		return;
	}

	if (p_id == BULK_COPY)
	{
		if (!bulk_dialog)
		{
			bulk_dialog = memnew(BulkCopyDialog);
			ei->get_base_control()->add_child(bulk_dialog);
		}
		bulk_dialog->setup(current_tile_set, get_undo_redo());
		bulk_dialog->popup_centered(Vector2i(520, 460));
	}
	else
	{
		if (!layer_dialog)
		{
			layer_dialog = memnew(LayerCopyDialog);
			ei->get_base_control()->add_child(layer_dialog);
		}
		layer_dialog->setup(current_tile_set, get_undo_redo());
		layer_dialog->popup_centered(Vector2i(420, 260));
	}
}
