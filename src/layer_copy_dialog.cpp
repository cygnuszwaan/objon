#include "layer_copy_dialog.h"

#include <godot_cpp/classes/editor_undo_redo_manager.hpp>
#include <godot_cpp/classes/label.hpp>
#include <godot_cpp/classes/navigation_mesh_source_geometry_data2d.hpp>
#include <godot_cpp/classes/navigation_polygon.hpp>
#include <godot_cpp/classes/navigation_server2d.hpp>
#include <godot_cpp/classes/option_button.hpp>
#include <godot_cpp/classes/tile_data.hpp>
#include <godot_cpp/classes/tile_set_atlas_source.hpp>
#include <godot_cpp/classes/tile_set_source.hpp>
#include <godot_cpp/classes/v_box_container.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2i.hpp>

using namespace godot;

// Gather a layer's shapes as a list of point loops. For physics that is the
// collision polygons; for navigation it is the navigation polygon's outlines.
static void collect_layer_polygons(TileData *p_td, int p_type, int p_idx, Vector<PackedVector2Array> &r_out)
{
	r_out.clear();
	if (p_type == 0)
	{
		const int n = p_td->get_collision_polygons_count(p_idx);
		for (int p = 0; p < n; p++)
		{
			r_out.push_back(p_td->get_collision_polygon_points(p_idx, p));
		}
	}
	else
	{
		Ref<NavigationPolygon> np = p_td->get_navigation_polygon(p_idx);
		if (np.is_valid())
		{
			for (int i = 0; i < np->get_outline_count(); i++)
			{
				r_out.push_back(np->get_outline(i));
			}
		}
	}
}

LayerCopyDialog::LayerCopyDialog()
{
	_build_ui();
}

void LayerCopyDialog::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("_on_confirmed"), &LayerCopyDialog::_on_confirmed);
}

void LayerCopyDialog::_build_ui()
{
	set_title("Copy Between Physics/Navigation");
	set_ok_button_text("Copy");
	set_hide_on_ok(false);

	VBoxContainer *vb = memnew(VBoxContainer);
	add_child(vb);

	Label *intro = memnew(Label);
	intro->set_text("Copy shapes from one layer to another, on every tile of every source.");
	vb->add_child(intro);

	Label *from_label = memnew(Label);
	from_label->set_text("From layer:");
	vb->add_child(from_label);
	from_picker = memnew(OptionButton);
	vb->add_child(from_picker);

	Label *to_label = memnew(Label);
	to_label->set_text("To layer:");
	vb->add_child(to_label);
	to_picker = memnew(OptionButton);
	vb->add_child(to_picker);

	status_label = memnew(Label);
	vb->add_child(status_label);

	connect("confirmed", Callable(this, "_on_confirmed"));
}

void LayerCopyDialog::_fill_picker(OptionButton *p_picker)
{
	p_picker->clear();
	if (tile_set.is_null())
	{
		return;
	}
	const int phys = tile_set->get_physics_layers_count();
	const int nav = tile_set->get_navigation_layers_count();
	int id = 0;
	for (int i = 0; i < phys; i++)
	{
		p_picker->add_item("Physics " + itos(i), id++);
		p_picker->set_item_metadata(p_picker->get_item_count() - 1, Vector2i(0, i));
	}
	for (int i = 0; i < nav; i++)
	{
		p_picker->add_item("Navigation " + itos(i), id++);
		p_picker->set_item_metadata(p_picker->get_item_count() - 1, Vector2i(1, i));
	}
}

void LayerCopyDialog::setup(const Ref<TileSet> &p_tile_set, EditorUndoRedoManager *p_undo_redo)
{
	tile_set = p_tile_set;
	undo_redo = p_undo_redo;
	status_label->set_text("");
	_fill_picker(from_picker);
	_fill_picker(to_picker);
}

void LayerCopyDialog::_queue_layer_copy(TileData *p_td, int p_from_type, int p_from_idx, int p_to_type, int p_to_idx)
{
	Vector<PackedVector2Array> src_polys;
	collect_layer_polygons(p_td, p_from_type, p_from_idx, src_polys);

	if (p_to_type == 0)
	{
		// Target is a physics layer: capture the old collision polygons for undo,
		// then replace them with the source shapes.
		const int old_count = p_td->get_collision_polygons_count(p_to_idx);
		undo_redo->add_undo_method(p_td, "set_collision_polygons_count", p_to_idx, old_count);
		for (int p = 0; p < old_count; p++)
		{
			undo_redo->add_undo_method(p_td, "set_collision_polygon_points", p_to_idx, p, p_td->get_collision_polygon_points(p_to_idx, p));
			undo_redo->add_undo_method(p_td, "set_collision_polygon_one_way", p_to_idx, p, p_td->is_collision_polygon_one_way(p_to_idx, p));
			undo_redo->add_undo_method(p_td, "set_collision_polygon_one_way_margin", p_to_idx, p, p_td->get_collision_polygon_one_way_margin(p_to_idx, p));
		}

		undo_redo->add_do_method(p_td, "set_collision_polygons_count", p_to_idx, src_polys.size());
		for (int p = 0; p < src_polys.size(); p++)
		{
			undo_redo->add_do_method(p_td, "set_collision_polygon_points", p_to_idx, p, src_polys[p]);
			// Preserve one-way flags only for physics->physics; cross-type has none.
			if (p_from_type == 0)
			{
				undo_redo->add_do_method(p_td, "set_collision_polygon_one_way", p_to_idx, p, p_td->is_collision_polygon_one_way(p_from_idx, p));
				undo_redo->add_do_method(p_td, "set_collision_polygon_one_way_margin", p_to_idx, p, p_td->get_collision_polygon_one_way_margin(p_from_idx, p));
			}
		}
	}
	else
	{
		// Target is a navigation layer: build the new navigation polygon now, then
		// set it via do/undo.
		Ref<NavigationPolygon> new_np;
		if (p_from_type == 1)
		{
			Ref<NavigationPolygon> src = p_td->get_navigation_polygon(p_from_idx);
			if (src.is_valid())
			{
				new_np = src->duplicate();
			}
		}
		else if (!src_polys.is_empty())
		{
			new_np.instantiate();
			Ref<NavigationMeshSourceGeometryData2D> geometry;
			geometry.instantiate();
			for (int p = 0; p < src_polys.size(); p++)
			{
				new_np->add_outline(src_polys[p]);
				geometry->add_traversable_outline(src_polys[p]);
			}
			new_np->set_agent_radius(0.0);
			NavigationServer2D::get_singleton()->bake_from_source_geometry_data(new_np, geometry);
		}

		undo_redo->add_do_method(p_td, "set_navigation_polygon", p_to_idx, new_np);
		undo_redo->add_undo_method(p_td, "set_navigation_polygon", p_to_idx, p_td->get_navigation_polygon(p_to_idx));
	}
}

void LayerCopyDialog::_on_confirmed()
{
	if (tile_set.is_null() || !undo_redo)
	{
		status_label->set_text("No edited TileSet available.");
		return;
	}
	if (from_picker->get_selected() < 0 || to_picker->get_selected() < 0)
	{
		status_label->set_text("Pick a from-layer and a to-layer.");
		return;
	}

	const Vector2i from = from_picker->get_item_metadata(from_picker->get_selected());
	const Vector2i to = to_picker->get_item_metadata(to_picker->get_selected());
	if (from == to)
	{
		status_label->set_text("Choose two different layers.");
		return;
	}

	undo_redo->create_action("Copy between physics/navigation layers");

	int tiles = 0;
	for (int s = 0; s < tile_set->get_source_count(); s++)
	{
		const int sid = tile_set->get_source_id(s);
		TileSetAtlasSource *atlas = Object::cast_to<TileSetAtlasSource>(tile_set->get_source(sid).ptr());
		if (!atlas)
		{
			continue;
		}
		const int tile_count = atlas->get_tiles_count();
		for (int i = 0; i < tile_count; i++)
		{
			const Vector2i coords = atlas->get_tile_id(i);
			const int alt_count = atlas->get_alternative_tiles_count(coords);
			for (int a = 0; a < alt_count; a++)
			{
				const int alt = atlas->get_alternative_tile_id(coords, a);
				TileData *td = atlas->get_tile_data(coords, alt);
				if (!td)
				{
					continue;
				}
				_queue_layer_copy(td, from.x, from.y, to.x, to.y);
				tiles++;
			}
		}
	}

	undo_redo->commit_action();

	const String summary = "Copied layer across " + itos(tiles) + " tile(s).";
	status_label->set_text(summary);
	UtilityFunctions::print("[TileSetHelper] ", summary);
	hide();
}
