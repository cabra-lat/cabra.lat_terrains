@tool
extends MeshInstance3D
class_name TileTerrainTile

# Use integer tile coordinates instead of lat/lon
@export var tile_x: int = 0 : set = _set_tile_x
@export var tile_y: int = 0 : set = _set_tile_y
@export var zoom_level: int = 18 : set = _set_zoom_level
@export var layer_type: String = "googlemt" : set = _set_layer_type
@export var terrain_scale: float = 1000.0 : set = _set_terrain_scale
@export var height_scale: float = 1.0 : set = _set_height_scale
@export var use_precomputed_normals: bool = true : set = _set_use_precomputed_normals

var shader_mat: ShaderMaterial
var tile_coord: Vector2i = Vector2i()
var tile_manager: TileManager
var _tile_loaded_connected: bool = false

# Proper setter functions for tile coordinates
func _set_tile_x(value: int) -> void:
    tile_x = value
    _update_tile_coord()
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _set_tile_y(value: int) -> void:
    tile_y = value
    _update_tile_coord()
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _set_zoom_level(value: int) -> void:
    zoom_level = value
    _update_tile_coord()
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _set_layer_type(value: String) -> void:
    layer_type = value
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _set_terrain_scale(value: float) -> void:
    terrain_scale = value
    _update_material_properties()
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _set_height_scale(value: float) -> void:
    height_scale = value
    _update_material_properties()
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _set_use_precomputed_normals(value: bool) -> void:
    use_precomputed_normals = value
    _update_material_properties()
    if is_inside_tree():
        call_deferred("_refresh_tile")

func _update_tile_coord():
    tile_coord = Vector2i(tile_x, tile_y)

func _setup_collision(tile_size: float, heightmap_texture: Texture2D = null) -> void:
    var parent_col := get_parent() as StaticBody3D
    if not parent_col:
        return

    # Clear existing collision shapes
    for child in parent_col.get_children():
        if child is CollisionShape3D:
            parent_col.remove_child(child)
            child.queue_free()

    if heightmap_texture and heightmap_texture is Texture2D:
        # Create collision shape from heightmap data
        _create_heightmap_collision(parent_col, tile_size, heightmap_texture)

func _create_heightmap_collision(parent_col: StaticBody3D, tile_size: float, heightmap_texture: Texture2D) -> void:
    print("Creating heightmap collision for tile: ", tile_coord)

    # Get height data from texture
    var height_data = HeightSampler.get_height_data(heightmap_texture)
    if height_data.is_empty():
        push_warning("Warning: No height data found for collision, using box collision")
        return

    # Create heightmap shape
    var heightmap_shape = HeightMapShape3D.new()

    # Configure the heightmap shape
    var map_width = 32  # Match our mesh resolution (31 subdivisions = 32 vertices)
    var map_depth = 32

    # Set the map data
    heightmap_shape.map_width = map_width
    heightmap_shape.map_depth = map_depth
    heightmap_shape.map_data = height_data

    print("Heightmap collision data: ", map_width, "x", map_depth, " with ", height_data.size(), " points")

    # Create collision shape
    var collision_shape := CollisionShape3D.new()
    collision_shape.shape = heightmap_shape

    # Scale the collision shape to match the mesh
    # The heightmap shape expects data in local space, so we need to scale it
    var scale_factor = Vector3(
        tile_size / (map_width - 1),  # X scale
        height_scale,                  # Y scale (height)
        tile_size / (map_depth - 1)    # Z scale
    )

    # Apply scaling through transform
    collision_shape.scale = scale_factor
    collision_shape.position = position  # Center the collision
    parent_col.add_child(collision_shape)

    # Set owner for proper scene saving
    if Engine.is_editor_hint() and is_inside_tree() and get_tree().edited_scene_root != null:
        pass #collision_shape.owner = get_tree().edited_scene_root

    print("Heightmap collision created for tile: ", tile_coord)

# Update the mesh building function to pass heightmap to collision
func _build_mesh_with_all_data(albedo_data: Resource, heightmap_data: Resource, normalmap_data: Resource) -> void:
    print("Building mesh with all data for tile: ", tile_coord)

    # Get the actual tile size for this zoom level
    var actual_tile_size = CoordinateConverter.get_tile_size_meters(zoom_level)
    print("Tile ", tile_coord, " actual size: ", actual_tile_size, " meters")

    # Create mesh with 31 subdivisions (32x32 vertices) to match the 32x32 heightmap resolution
    var pm := PlaneMesh.new()
    pm.size = Vector2(actual_tile_size, actual_tile_size)
    pm.subdivide_depth = 31
    pm.subdivide_width = 31

    # Ensure we have a shader material
    if not shader_mat:
        _create_shader_material()

    if shader_mat and shader_mat.shader:
        # Set the albedo texture
        if albedo_data is Texture2D:
            shader_mat.set_shader_parameter("albedo_texture", albedo_data)
            print("Albedo texture set for tile: ", tile_coord)
        else:
            print("Warning: albedo_data is not a Texture2D for tile: ", tile_coord)
            _set_error_placeholder()
            return

        shader_mat.set_shader_parameter("terrain_scale", actual_tile_size)
        shader_mat.set_shader_parameter("height_scale", height_scale)
        shader_mat.set_shader_parameter("use_precomputed_normals", use_precomputed_normals)

        # Store heightmap for collision
        var heightmap_for_collision = null

        # Set heightmap if available
        if heightmap_data and heightmap_data is Texture2D:
            shader_mat.set_shader_parameter("heightmap_texture", heightmap_data)
            heightmap_for_collision = heightmap_data
            print("Heightmap set for tile: ", tile_coord)

            # Update AABB with actual height data
            _update_aabb_with_heightmap(heightmap_data, actual_tile_size)
        else:
            # Use conservative AABB if no heightmap
            _update_aabb_conservative(actual_tile_size)
            print("No heightmap available for tile: ", tile_coord)

        # Set normalmap if available
        if normalmap_data and normalmap_data is Texture2D:
            shader_mat.set_shader_parameter("normalmap_texture", normalmap_data)
            print("Normalmap set for tile: ", tile_coord)
        else:
            print("No normalmap available for tile: ", tile_coord)
            shader_mat.set_shader_parameter("use_precomputed_normals", false)

    pm.material = shader_mat
    mesh = pm

    print("Mesh built successfully for tile: ", tile_coord, " with 32x32 vertices")

    # Setup collision with heightmap data
    _setup_collision(actual_tile_size, heightmap_data)

# Also update the AABB functions to be more accurate
func _update_aabb_with_heightmap(heightmap_texture: Texture2D, tile_size: float):
    # Sample the heightmap to get min/max height
    var height_range = HeightSampler.sample_height(heightmap_texture)
    var min_height = height_range.x * height_scale
    var max_height = height_range.y * height_scale

    # Add some margin for safety
    var margin = (max_height - min_height) * 0.1
    min_height -= margin
    max_height += margin

    print("Tile ", tile_coord, " height range: ", height_range.x, " to ", height_range.y, " (scaled: ", min_height, " to ", max_height, ")")

    # Calculate AABB based on actual height data
    var half_size = tile_size * 0.5
    var aabb_height = max_height - min_height

    # Create an AABB that encompasses the entire tile with actual height range
    var aabb = AABB(
        Vector3(-half_size, min_height, -half_size),  # position (min corner)
        Vector3(tile_size, aabb_height, tile_size)    # size
    )

    # Set the custom AABB
    set_custom_aabb(aabb)

    # Set extra cull margin based on actual height range
    extra_cull_margin = max(abs(min_height), abs(max_height)) + tile_size * 0.2

    print("Tile ", tile_coord, " AABB: ", aabb)

func _update_aabb_conservative(tile_size: float):
    # Conservative AABB assuming maximum possible height
    var half_size = tile_size * 0.5
    var max_height = height_scale * 2000.0  # More conservative estimate for collision

    var aabb = AABB(
        Vector3(-half_size, -max_height, -half_size),  # min
        Vector3(tile_size, max_height * 2, tile_size)  # size
    )

    # Set the custom AABB
    set_custom_aabb(aabb)

    # Set extra cull margin
    extra_cull_margin = max_height + tile_size * 0.2


func _ready():
    _update_tile_coord()

    # Create the shader material if it doesn't exist
    if not shader_mat:
        _create_shader_material()

    # Refresh immediately when added to scene
    call_deferred("_refresh_tile")

func _create_shader_material():
    shader_mat = ShaderMaterial.new()
    var shader = preload("../shaders/terrain_shader.gdshader")
    if shader:
        shader_mat.shader = shader
        print("Shader loaded successfully from ../shaders/terrain_shader.gdshader")
    else:
        print("ERROR: Shader not found at ../shaders/terrain_shader.gdshader")
        # Fallback shader
        var fallback_shader = Shader.new()
        fallback_shader.code = """
            shader_type spatial;
            void fragment() {
                ALBEDO = vec3(0.8, 0.2, 0.2);
            }
        """
        shader_mat.shader = fallback_shader

func _update_material_properties():
    if shader_mat and shader_mat.shader:
        shader_mat.set_shader_parameter("terrain_scale", terrain_scale)
        shader_mat.set_shader_parameter("height_scale", height_scale)
        shader_mat.set_shader_parameter("use_precomputed_normals", use_precomputed_normals)

func _refresh_tile() -> void:
    if not is_inside_tree():
        return

    print("Tile refresh: tile=", tile_coord, " at zoom=", zoom_level)

    # Find TileManager if not set
    if not is_instance_valid(tile_manager):
        tile_manager = get_tree().root.find_child("TileManager", true, false)
        if not is_instance_valid(tile_manager):
            print("ERROR: TileManager not found for tile ", tile_coord)
            _set_error_placeholder()
            return

    # Connect to tile_loaded signal
    if not _tile_loaded_connected:
        if tile_manager.tile_loaded.is_connected(_on_tile_loaded):
            tile_manager.tile_loaded.disconnect(_on_tile_loaded)
        tile_manager.tile_loaded.connect(_on_tile_loaded)
        _tile_loaded_connected = true

    # Get albedo at current zoom level
    var albedo_data = tile_manager.get_tile_data(tile_coord, zoom_level, layer_type)
    if not albedo_data:
        print("No albedo data found, queueing download for: ", tile_coord)
        tile_manager.queue_tile_download(tile_coord, zoom_level, layer_type)
        _set_downloading_placeholder()
        return

    # Get heightmap and normalmap at zoom 15 (if we're at zoom 18)
    var heightmap_data = null
    var normalmap_data = null

    if zoom_level == 18:
        heightmap_data = MultiZoomTextureCompositor.get_heightmap_for_tile(tile_coord, tile_manager)
        normalmap_data = MultiZoomTextureCompositor.get_normalmap_for_tile(tile_coord, tile_manager)

    # Build mesh with all available data
    _build_mesh_with_all_data(albedo_data, heightmap_data, normalmap_data)

func _set_downloading_placeholder():
    var pm := PlaneMesh.new()
    pm.size = Vector2(terrain_scale, terrain_scale)
    var mat := StandardMaterial3D.new()
    if Engine.is_editor_hint():
        mat.albedo_color = Color(0.2, 0.2, 0.8, 0.3)  # Blue for downloading in editor
    else:
        mat.albedo_color = Color(1, 0, 1, 0.5)  # Magenta for runtime
    pm.material = mat
    mesh = pm

func _set_error_placeholder():
    var pm := PlaneMesh.new()
    pm.size = Vector2(terrain_scale, terrain_scale)
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(1, 0, 0, 0.5)  # Red for errors
    pm.material = mat
    mesh = pm

func _on_tile_loaded(coords: Vector2i, z: int, layer_data: Dictionary):
    print("Tile loaded signal received for ", coords, " at zoom ", z)

    # Check if this is our albedo tile at current zoom level
    if coords == tile_coord and z == zoom_level:
        print("This is our albedo tile! Rebuilding mesh...")
        call_deferred("_refresh_tile")

    # Check if this is a zoom 15 tile that we need for heightmap or normalmap
    if zoom_level == 18:
        var zoom15_tile = MultiZoomTextureCompositor._get_zoom15_tile_coords(tile_coord)
        if coords == zoom15_tile and z == 15:
            print("This is a zoom 15 tile we need! Rebuilding mesh...")
            call_deferred("_refresh_tile")

func _exit_tree():
    if _tile_loaded_connected and is_instance_valid(tile_manager):
        if tile_manager.tile_loaded.is_connected(_on_tile_loaded):
            tile_manager.tile_loaded.disconnect(_on_tile_loaded)
        _tile_loaded_connected = false
