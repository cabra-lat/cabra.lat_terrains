@tool
extends EditorPlugin

var terrain_control: Control
var terrain_inspector: VBoxContainer

func _enter_tree():
    # Create custom inspector UI
    terrain_control = Control.new()
    terrain_inspector = _create_terrain_inspector()
    terrain_control.add_child(terrain_inspector)
    
    add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, terrain_control)
    terrain_control.hide()

func _exit_tree():
    if terrain_control:
        remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, terrain_control)
        terrain_control.queue_free()

func _create_terrain_inspector() -> VBoxContainer:
    var container = VBoxContainer.new()
    container.name = "TerrainInspector"
    
    # Title
    var title = Label.new()
    title.text = "Terrain Preview"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    container.add_child(title)
    
    # Add various controls for terrain preview...
    
    return container

func edit(object: Object):
    if object is ChunkedTerrain:
        terrain_control.show()
    else:
        terrain_control.hide()

func handles(object: Object) -> bool:
    return object is ChunkedTerrain
