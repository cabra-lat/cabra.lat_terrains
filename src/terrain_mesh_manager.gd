class_name TerrainMeshManager
extends Node

@export var use_normal_maps: bool = true

var terrain_mesh_instance: MeshInstance3D
var shader_material: ShaderMaterial

var terrain_loader: DynamicTerrainLoader

func setup(loader: DynamicTerrainLoader):
    terrain_loader = loader
    setup_terrain_mesh()

func setup_terrain_mesh():
    terrain_mesh_instance = MeshInstance3D.new()
    terrain_loader.add_child(terrain_mesh_instance)

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(10, 10)
    terrain_mesh_instance.mesh = plane_mesh

    shader_material = ShaderMaterial.new()
    # Make sure this path is correct for your project
    shader_material.shader = preload("../shaders/terrain_shader.gdshader")
    terrain_mesh_instance.material_override = shader_material

func on_tile_loaded(tile_coords: Vector2i, zoom: int, tile_data: Dictionary):
    update_shader_with_tile(tile_coords, zoom, tile_data)

    # Only generate collision for highest LOD tiles
    if zoom == terrain_loader.COLLISION_ZOOM_LEVEL:
        if tile_data.has("terrarium"):
            terrain_loader.collision_manager.queue_collision_generation(
                tile_coords, zoom, tile_data["terrarium"]
            )

func update_shader_with_tile(tile_coords: Vector2i, zoom: int, tile_data: Dictionary):
    if tile_data.has("terrarium"):
        var height_texture = tile_data["terrarium"]
        shader_material.set_shader_parameter("heightmap_texture", height_texture)
        update_mesh_for_zoom(zoom)

    if use_normal_maps and tile_data.has("normal"):
        var normal_texture = tile_data["normal"]
        shader_material.set_shader_parameter("normal_map", normal_texture)

func update_mesh_for_zoom(zoom: int):
    var tile_size_meters = CoordinateConverter.get_tile_size_meters(zoom)

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(tile_size_meters, tile_size_meters)
    plane_mesh.subdivide_depth = 255
    plane_mesh.subdivide_width = 255

    # Center the mesh at (0,0,0) - spans from -size/2 to size/2
    terrain_mesh_instance.mesh = plane_mesh
    terrain_mesh_instance.position = Vector3.ZERO

    shader_material.set_shader_parameter("terrain_scale", tile_size_meters)

    print("Mesh updated for zoom ", zoom, " - Size: ", tile_size_meters, "m, Position: ", terrain_mesh_instance.position)

func update_for_tile(tile_coords: Vector2i, zoom: int):
    # This will be called when the tile changes
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
