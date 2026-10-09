#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/editor_plugin_registration.hpp>

#include "tileset_helper_plugin.h"
#include "bulk_copy_dialog.h"
#include "layer_copy_dialog.h"

using namespace godot;

void initialize_tileset_helper_module(ModuleInitializationLevel p_level)
{
	// Editor-only tool. Everything is registered at the editor init level, which
	// is only reached when running inside the Godot editor (never in an exported
	// game), so the plugin is a no-op at runtime. The editor here loads the
	// template_debug build, and EditorPlugins::add_by_type works regardless of
	// the build target (it just calls the editor_add_plugin interface).
	if (p_level != MODULE_INITIALIZATION_LEVEL_EDITOR)
	{
		return;
	}

	GDREGISTER_INTERNAL_CLASS(BulkCopyDialog);
	GDREGISTER_INTERNAL_CLASS(LayerCopyDialog);
	GDREGISTER_INTERNAL_CLASS(TileSetHelperPlugin);

	EditorPlugins::add_by_type<TileSetHelperPlugin>();
}

void uninitialize_tileset_helper_module(ModuleInitializationLevel p_level)
{
	// godot-cpp removes registered editor plugins automatically on EDITOR
	// deinitialization (see GDExtensionBinding::deinitialize_level), so there is
	// nothing to tear down here.
	if (p_level != MODULE_INITIALIZATION_LEVEL_EDITOR)
	{
		return;
	}
}

extern "C"
{
	GDExtensionBool GDE_EXPORT tileset_helper_library_init(
			GDExtensionInterfaceGetProcAddress p_get_proc_address,
			GDExtensionClassLibraryPtr p_library,
			GDExtensionInitialization *r_initialization)
	{
		godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

		init_obj.register_initializer(initialize_tileset_helper_module);
		init_obj.register_terminator(uninitialize_tileset_helper_module);
		init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);

		return init_obj.init();
	}
}
