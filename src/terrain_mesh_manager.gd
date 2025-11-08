class_name TerrainMeshManager
extends Node

var use_normal_maps: bool
var use_precomputed_normals: bool

var terrain_mesh_instance: MeshInstance3D
var shader_material: ShaderMaterial

var terrain_loader: DynamicTerrainLoader

func setup(loader: DynamicTerrainLoader):
    terrain_loader = loader
    use_normal_maps = terrain_loader.use_normal_maps
    use_precomputed_normals = terrain_loader.use_precomputed_normals
    setup_terrain_mesh()

func setup_terrain_mesh():
    terrain_mesh_instance = MeshInstance3D.new()
    terrain_loader.add_child(terrain_mesh_instance)

    shader_material = terrain_loader.material

    # Set the precomputed normals parameter
    shader_material.set_shader_parameter("use_precomputed_normals", use_precomputed_normals)

    terrain_mesh_instance.material_override = shader_material

func on_tile_loaded(tile_coords: Vector2i, zoom: int, tile_data: Dictionary):
    update_shader_with_tile(tile_coords, zoom, tile_data)

func update_shader_with_tile(tile_coords: Vector2i, zoom: int, tile_data: Dictionary):
    if tile_data.has("terrarium"):
        var height_texture = tile_data["terrarium"]
        shader_material.set_shader_parameter("heightmap_texture", height_texture)

        var tile_size_meters = CoordinateConverter.get_tile_size_meters(zoom)
        _update_terrain_aabb(tile_size_meters, height_texture)  # Pass height texture for accurate AABB

    if use_normal_maps and tile_data.has("normal"):
        var normal_texture = tile_data["normal"]
        shader_material.set_shader_parameter("normal_map", normal_texture)
        if use_precomputed_normals:
            shader_material.set_shader_parameter("use_precomputed_normals", true)

func update_mesh_for_zoom(zoom: int):
    var tile_size_meters = CoordinateConverter.get_tile_size_meters(zoom)

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(tile_size_meters, tile_size_meters)
    plane_mesh.subdivide_depth = 255
    plane_mesh.subdivide_width = 255

    terrain_mesh_instance.mesh = plane_mesh
    terrain_mesh_instance.position = Vector3.ZERO

    # Calculate and set a proper AABB for the terrain
    # This gives Godot accurate bounds for culling calculations
    _update_terrain_aabb(tile_size_meters)

    shader_material.set_shader_parameter("terrain_scale", tile_size_meters)

    print("Mesh updated for zoom ", zoom, " - Size: ", tile_size_meters, "m")

func _update_terrain_aabb(tile_size_meters: float, height_texture: Texture2D = null):
    if not is_instance_valid(terrain_mesh_instance.mesh): return

    var min_height = -1000.0  # Default minimum
    var max_height = 10000.0  # Default maximum

    # If we have the height texture, sample it to get actual min/max heights
    if height_texture:
        var image = height_texture.get_image()
        var size = image.get_size()
        min_height = INF
        max_height = -INF

        # Sample multiple points to estimate min/max height
        for z in range(0, size.y, max(1, size.y / 10)):  # Sample 10 points in each dimension
            for x in range(0, size.x, max(1, size.x / 10)):
                var u = float(x) / (size.x - 1)
                var v = float(z) / (size.y - 1)
                var height = HeightSampler.sample_height_bilinear(image, u, v)
                min_height = min(min_height, height)
                max_height = max(max_height, height)

        # Add some padding to the height range
        min_height -= 100.0
        max_height += 100.0

    # Calculate half dimensions
    var half_width = tile_size_meters / 2.0
    var half_height = (max_height - min_height) / 2.0
    var half_depth = tile_size_meters / 2.0

    # Center point (mesh is at y=0, so center AABB at middle of height range)
    var center = Vector3(0, (min_height + max_height) / 2.0, 0)

    # Size of AABB
    var size = Vector3(tile_size_meters, max_height - min_height, tile_size_meters)

    # Create AABB
    var aabb = AABB(center - size/2, size)

    # Apply the custom AABB to the mesh
    terrain_mesh_instance.mesh.custom_aabb = aabb

    print("Terrain AABB set - Min: ", min_height, " Max: ", max_height, " Center: ", center, " Size: ", size)

func update_for_tile(tile_coords: Vector2i, zoom: int):
    update_mesh_for_zoom(zoom)

func get_terrain_elevation_at_position(world_pos: Vector3) -> float:
    var tile_data = terrain_loader.tile_manager.get_texture_for_tile(
        terrain_loader.current_tile_coords,
        terrain_loader.lod_manager.current_zoom,
        TileTextureType.TERRARIUM
    )

    if tile_data:
        return HeightSampler.sample_height_at_position(
            tile_data, world_pos, terrain_loader.lod_manager.current_zoom
        )
    return 0.0
