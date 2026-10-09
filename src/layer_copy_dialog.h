#pragma once

#include <godot_cpp/classes/confirmation_dialog.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/tile_set.hpp>

namespace godot
{

class OptionButton;
class Label;
class EditorUndoRedoManager;
class TileData;

// Dialog launched from the Tile Sources advanced menu. Copies shapes from one
// layer to another - within the same tile, across every tile of every atlas
// source. The "from" and "to" layer can each be any physics or navigation
// layer, so it doubles as a physics<->navigation converter (collision shapes
// are baked into a navigation polygon and vice versa).
class LayerCopyDialog : public ConfirmationDialog
{
	GDCLASS(LayerCopyDialog, ConfirmationDialog);

	OptionButton *from_picker = nullptr;
	OptionButton *to_picker = nullptr;
	Label *status_label = nullptr;

	Ref<TileSet> tile_set;
	EditorUndoRedoManager *undo_redo = nullptr;

	void _build_ui();
	void _fill_picker(OptionButton *p_picker);

	// Layers are encoded as Vector2i(type, index): type 0 = physics, 1 = nav.
	void _queue_layer_copy(TileData *p_td, int p_from_type, int p_from_idx, int p_to_type, int p_to_idx);

protected:
	static void _bind_methods();

public:
	void setup(const Ref<TileSet> &p_tile_set, EditorUndoRedoManager *p_undo_redo);
	void _on_confirmed();

	LayerCopyDialog();
};

} // namespace godot
