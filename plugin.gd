# terrain_manager_plugin.gd
@tool
extends EditorPlugin
#
#var terrain_manager: Node
#var menu_button: MenuButton
#var popup: PopupMenu
#
#func _enter_tree():
    ## Create toolbar UI
    #create_toolbar_ui()
#
    ## Connect to scene changed signal
    #scene_changed.connect(_on_scene_changed)
#
    ## Initial scan
    #call_deferred("scan_for_terrain_manager")
#
#func _exit_tree():
    #if menu_button:
        #remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, menu_button)
        #menu_button.queue_free()
#
#func create_toolbar_ui():
    ## Create menu button instead of regular button
    #menu_button = MenuButton.new()
    #menu_button.text = "Terrain"
    #menu_button.tooltip_text = "Terrain Manager Tools"
#
    ## Create and set up the popup menu
    #popup = menu_button.get_popup()
    #popup.add_item("Refresh Terrain", 0)
    #popup.add_item("Reload Textures", 1)
    #popup.add_item("Toggle Debug View", 2)
    #popup.add_separator()
    #popup.add_item("Rescan for TerrainManager", 3)
#
    #popup.connect("id_pressed", _on_menu_item_selected)
#
    #add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, menu_button)
#
#func _on_menu_item_selected(id: int):
    #match id:
        #0: # Refresh Terrain
            #_on_refresh_pressed()
        #1: # Reload Textures
            #_on_reload_textures_pressed()
        #2: # Toggle Debug
            #_on_debug_pressed()
        #3: # Rescan
            #_on_rescan_pressed()
#
#func _on_scene_changed():
    #scan_for_terrain_manager()
#
#func _on_rescan_pressed():
    #print("Manual rescan triggered...")
    #scan_for_terrain_manager()
#
#func scan_for_terrain_manager():
    #var current_scene = get_editor_interface().get_edited_scene_root()
    #if current_scene:
        #terrain_manager = find_terrain_manager(current_scene)
#
        #if terrain_manager:
            #print("✓ Found TerrainManager: ", terrain_manager.name)
            #print("  Path: ", terrain_manager.get_path())
        #else:
            #print("✗ No TerrainManager found in scene")
#
        ## Update menu button state
        #update_menu_button_state()
    #else:
        #terrain_manager = null
        #update_menu_button_state()
        #print("No active scene to scan")
#
#func find_terrain_manager(node: Node) -> Node:
    ## Check if current node is a TerrainManager
    #if _is_terrain_manager(node):
        #return node
#
    ## Recursively check all children
    #for child in node.get_children():
        #var result = find_terrain_manager(child)
        #if result:
            #return result
#
    #return null
#
#func _is_terrain_manager(node: Node) -> bool:
    #if not node:
        #return false
#
    ## Method 1: Check for specific methods
    #if node.has_method("refresh_editor_preview") and node.has_method("preload_tile_textures"):
        #return true
#
    ## Method 2: Check script name
    #var script = node.get_script()
    #if script:
        #var script_path = script.resource_path
        #if script_path and ("terrain_manager" in script_path.to_lower()):
            #return true
#
    ## Method 3: Check class name (if registered)
    #if node.get_class() == "TerrainManager":
        #return true
#
    ## Method 4: Check node name as fallback
    #if "terrain" in node.name.to_lower() and "manager" in node.name.to_lower():
        #return true
#
    #return false
#
#func update_menu_button_state():
    #if terrain_manager and is_instance_valid(terrain_manager):
        #menu_button.text = "Terrain ✓"
        #menu_button.tooltip_text = "Terrain Manager: Active"
    #else:
        #menu_button.text = "Terrain ✗"
        #menu_button.tooltip_text = "No TerrainManager found"
#
#func _on_refresh_pressed():
    #if terrain_manager and is_instance_valid(terrain_manager) and terrain_manager.has_method("refresh_editor_preview"):
        #terrain_manager.refresh_editor_preview()
        #print("Terrain Manager Plugin: Refreshed terrain preview")
#
#func _on_reload_textures_pressed():
    #if terrain_manager and is_instance_valid(terrain_manager) and terrain_manager.has_method("force_reload_textures"):
        #terrain_manager.force_reload_textures()
        #print("Terrain Manager Plugin: Reloaded textures")
#
#func _on_debug_pressed():
    #if terrain_manager and is_instance_valid(terrain_manager) and terrain_manager.has_method("toggle_debug"):
        #terrain_manager.toggle_debug()
        #print("Terrain Manager Plugin: Toggled debug mode")
