#pragma once

#include <godot_cpp/classes/confirmation_dialog.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/tile_set.hpp>

namespace godot
{

class OptionButton;
class ItemList;
class CheckBox;
class Label;
class EditorUndoRedoManager;
class TileData;
class TileSetAtlasSource;

// Dialog launched from the Tile Sources advanced menu. Lets the user pick a
// template atlas source and one or more target sources in the open TileSet, then
// propagates all physics (collision) and/or navigation data from the template
// onto the targets, matching tiles by atlas coordinates. The whole operation is
// a single undoable action.
class BulkCopyDialog : public ConfirmationDialog
{
	GDCLASS(BulkCopyDialog, ConfirmationDialog);

	OptionButton *template_picker = nullptr;
	ItemList *target_list = nullptr;
	CheckBox *physics_check = nullptr;
	CheckBox *nav_check = nullptr;
	Label *status_label = nullptr;

	Ref<TileSet> tile_set;
	EditorUndoRedoManager *undo_redo = nullptr;

	void _build_ui();
	void _populate();
	void _refresh_targets();
	String _source_label(int p_source_id) const;

	// Queues do/undo for copying one source TileData layer set onto a target.
	void _queue_tile_copy(TileData *p_src, TileData *p_dst, int p_physics_layers, int p_nav_layers, bool p_do_physics, bool p_do_nav);

protected:
	static void _bind_methods();

public:
	void setup(const Ref<TileSet> &p_tile_set, EditorUndoRedoManager *p_undo_redo);
	void _on_confirmed();
	void _on_template_changed(int p_index);

	BulkCopyDialog();
};

} // namespace godot
