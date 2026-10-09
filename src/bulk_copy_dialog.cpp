#include "bulk_copy_dialog.h"

#include <godot_cpp/classes/check_box.hpp>
#include <godot_cpp/classes/editor_undo_redo_manager.hpp>
#include <godot_cpp/classes/h_box_container.hpp>
#include <godot_cpp/classes/item_list.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/navigation_polygon.hpp>
#include <godot_cpp/classes/option_button.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/tile_data.hpp>
#include <godot_cpp/classes/tile_set_atlas_source.hpp>
#include <godot_cpp/classes/tile_set_source.hpp>
#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

using namespace godot;

BulkCopyDialog::BulkCopyDialog()
{
	_build_ui();
}

void BulkCopyDialog::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("_on_confirmed"), &BulkCopyDialog::_on_confirmed);
	ClassDB::bind_method(D_METHOD("_on_template_changed", "index"), &BulkCopyDialog::_on_template_changed);
}

void BulkCopyDialog::_build_ui()
{
	set_title("Copy Physics/Navigation Across Sources");
	set_ok_button_text("Copy");
	// Keep the dialog open if validation fails or so the result summary stays
	// visible; hidden manually on success.
	set_hide_on_ok(false);

	VBoxContainer *vb = memnew(VBoxContainer);
	add_child(vb);

	Label *from_label = memnew(Label);
	from_label->set_text("Template source (copy FROM):");
	vb->add_child(from_label);

	template_picker = memnew(OptionButton);
	template_picker->connect("item_selected", Callable(this, "_on_template_changed"));
	vb->add_child(template_picker);

	Label *to_label = memnew(Label);
	to_label->set_text("Target sources (copy TO):");
	vb->add_child(to_label);

	target_list = memnew(ItemList);
	target_list->set_select_mode(ItemList::SELECT_MULTI);
	target_list->set_custom_minimum_size(Vector2(0, 180));
	vb->add_child(target_list);

	HBoxContainer *toggles = memnew(HBoxContainer);
	physics_check = memnew(CheckBox);
	physics_check->set_text("Physics");
	physics_check->set_pressed(true);
	toggles->add_child(physics_check);

	nav_check = memnew(CheckBox);
	nav_check->set_text("Navigation");
	nav_check->set_pressed(true);
	toggles->add_child(nav_check);
	vb->add_child(toggles);

	status_label = memnew(Label);
	vb->add_child(status_label);

	connect("confirmed", Callable(this, "_on_confirmed"));
}

void BulkCopyDialog::setup(const Ref<TileSet> &p_tile_set, EditorUndoRedoManager *p_undo_redo)
{
	tile_set = p_tile_set;
	undo_redo = p_undo_redo;
	_populate();
}

String BulkCopyDialog::_source_label(int p_source_id) const
{
	String name = "Source " + itos(p_source_id);
	if (tile_set.is_null())
	{
		return name;
	}
	TileSetAtlasSource *atlas = Object::cast_to<TileSetAtlasSource>(tile_set->get_source(p_source_id).ptr());
	if (atlas)
	{
		Ref<Texture2D> tex = atlas->get_texture();
		if (tex.is_valid())
		{
			const String path = tex->get_path();
			if (!path.is_empty())
			{
				name += " (" + path.get_file() + ")";
			}
		}
	}
	return name;
}

void BulkCopyDialog::_populate()
{
	template_picker->clear();
	status_label->set_text("");

	if (tile_set.is_null())
	{
		target_list->clear();
		return;
	}

	for (int i = 0; i < tile_set->get_source_count(); i++)
	{
		const int sid = tile_set->get_source_id(i);
		// Only atlas sources carry per-tile physics/navigation data.
		TileSetAtlasSource *atlas = Object::cast_to<TileSetAtlasSource>(tile_set->get_source(sid).ptr());
		if (!atlas)
		{
			continue;
		}
		template_picker->add_item(_source_label(sid), sid);
	}

	_refresh_targets();
}

void BulkCopyDialog::_refresh_targets()
{
	target_list->clear();
	if (tile_set.is_null())
	{
		return;
	}

	// The source picked as the template is excluded from the target list - you
	// cannot copy a source onto itself.
	const int template_id = template_picker->get_selected_id();
	for (int i = 0; i < tile_set->get_source_count(); i++)
	{
		const int sid = tile_set->get_source_id(i);
		if (sid == template_id)
		{
			continue;
		}
		TileSetAtlasSource *atlas = Object::cast_to<TileSetAtlasSource>(tile_set->get_source(sid).ptr());
		if (!atlas)
		{
			continue;
		}
		const int idx = target_list->add_item(_source_label(sid));
		target_list->set_item_metadata(idx, sid);
	}
}

void BulkCopyDialog::_on_template_changed(int p_index)
{
	_refresh_targets();
}

void BulkCopyDialog::_queue_tile_copy(TileData *p_src, TileData *p_dst, int p_physics_layers, int p_nav_layers, bool p_do_physics, bool p_do_nav)
{
	if (p_do_physics)
	{
		for (int layer = 0; layer < p_physics_layers; layer++)
		{
			const int src_count = p_src->get_collision_polygons_count(layer);
			const int dst_old_count = p_dst->get_collision_polygons_count(layer);

			// do: replace target polygons with the template's.
			undo_redo->add_do_method(p_dst, "set_collision_polygons_count", layer, src_count);
			for (int p = 0; p < src_count; p++)
			{
				undo_redo->add_do_method(p_dst, "set_collision_polygon_points", layer, p, p_src->get_collision_polygon_points(layer, p));
				undo_redo->add_do_method(p_dst, "set_collision_polygon_one_way", layer, p, p_src->is_collision_polygon_one_way(layer, p));
				undo_redo->add_do_method(p_dst, "set_collision_polygon_one_way_margin", layer, p, p_src->get_collision_polygon_one_way_margin(layer, p));
			}
			undo_redo->add_do_method(p_dst, "set_constant_linear_velocity", layer, p_src->get_constant_linear_velocity(layer));
			undo_redo->add_do_method(p_dst, "set_constant_angular_velocity", layer, p_src->get_constant_angular_velocity(layer));

			// undo: restore the target's previous polygons (values captured now).
			undo_redo->add_undo_method(p_dst, "set_collision_polygons_count", layer, dst_old_count);
			for (int p = 0; p < dst_old_count; p++)
			{
				undo_redo->add_undo_method(p_dst, "set_collision_polygon_points", layer, p, p_dst->get_collision_polygon_points(layer, p));
				undo_redo->add_undo_method(p_dst, "set_collision_polygon_one_way", layer, p, p_dst->is_collision_polygon_one_way(layer, p));
				undo_redo->add_undo_method(p_dst, "set_collision_polygon_one_way_margin", layer, p, p_dst->get_collision_polygon_one_way_margin(layer, p));
			}
			undo_redo->add_undo_method(p_dst, "set_constant_linear_velocity", layer, p_dst->get_constant_linear_velocity(layer));
			undo_redo->add_undo_method(p_dst, "set_constant_angular_velocity", layer, p_dst->get_constant_angular_velocity(layer));
		}
	}

	if (p_do_nav)
	{
		for (int layer = 0; layer < p_nav_layers; layer++)
		{
			// Duplicate the navigation polygon so source and target do not share
			// the same resource instance.
			Ref<NavigationPolygon> src_nav = p_src->get_navigation_polygon(layer);
			Ref<NavigationPolygon> src_nav_copy;
			if (src_nav.is_valid())
			{
				src_nav_copy = src_nav->duplicate();
			}
			undo_redo->add_do_method(p_dst, "set_navigation_polygon", layer, src_nav_copy);
			undo_redo->add_undo_method(p_dst, "set_navigation_polygon", layer, p_dst->get_navigation_polygon(layer));
		}
	}
}

void BulkCopyDialog::_on_confirmed()
{
	if (tile_set.is_null() || !undo_redo)
	{
		status_label->set_text("No edited TileSet available.");
		return;
	}

	const int template_id = template_picker->get_selected_id();
	if (template_id < 0)
	{
		status_label->set_text("Pick a template source.");
		return;
	}
	TileSetAtlasSource *src = Object::cast_to<TileSetAtlasSource>(tile_set->get_source(template_id).ptr());
	if (!src)
	{
		status_label->set_text("Template is not an atlas source.");
		return;
	}

	const bool do_phys = physics_check->is_pressed();
	const bool do_nav = nav_check->is_pressed();
	if (!do_phys && !do_nav)
	{
		status_label->set_text("Enable Physics and/or Navigation.");
		return;
	}

	const PackedInt32Array selected = target_list->get_selected_items();
	if (selected.is_empty())
	{
		status_label->set_text("Select at least one target source.");
		return;
	}

	const int phys_layers = tile_set->get_physics_layers_count();
	const int nav_layers = tile_set->get_navigation_layers_count();

	undo_redo->create_action("Copy tile physics/navigation across sources");

	int tiles_copied = 0;
	int tiles_skipped = 0;
	int targets_done = 0;
	for (int s = 0; s < selected.size(); s++)
	{
		const int target_id = (int)(int64_t)target_list->get_item_metadata(selected[s]);
		if (target_id == template_id)
		{
			continue;
		}
		TileSetAtlasSource *dst = Object::cast_to<TileSetAtlasSource>(tile_set->get_source(target_id).ptr());
		if (!dst)
		{
			continue;
		}
		targets_done++;

		const int tile_count = src->get_tiles_count();
		for (int i = 0; i < tile_count; i++)
		{
			const Vector2i coords = src->get_tile_id(i);
			if (!dst->has_tile(coords))
			{
				tiles_skipped++;
				continue;
			}
			const int alt_count = src->get_alternative_tiles_count(coords);
			for (int a = 0; a < alt_count; a++)
			{
				const int alt = src->get_alternative_tile_id(coords, a);
				TileData *s_td = src->get_tile_data(coords, alt);
				TileData *d_td = dst->get_tile_data(coords, alt);
				if (!s_td || !d_td)
				{
					continue;
				}
				_queue_tile_copy(s_td, d_td, phys_layers, nav_layers, do_phys, do_nav);
				tiles_copied++;
			}
		}
	}

	undo_redo->commit_action();

	const String summary = "Copied " + itos(tiles_copied) + " tile(s) to " + itos(targets_done) + " source(s); skipped " + itos(tiles_skipped) + " missing in target.";
	status_label->set_text(summary);
	UtilityFunctions::print("[TileSetHelper] ", summary);

	hide();
}
