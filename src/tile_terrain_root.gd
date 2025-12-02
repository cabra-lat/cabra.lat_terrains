@tool
extends Node3D
class_name TileTerrainRoot

# User-friendly lat/lon inputs
@export var centre_latitude: float = -6.084 : set = _set_centre_latitude
@export var centre_longitude: float = -50.177 : set = _set_centre_longitude
@export var zoom: int = 18 : set = _set_zoom
@export var layer: String = "googlemt"
@export_range(1, 100, 2) var grid_radius: int = 3
@export var add_collision: bool = true
@export var save_in_scene: bool = false: set = _set_save_in_scene

# Update button
@export_tool_button("Update") var update_button: Callable

# Atlas data - shared by all tiles
var albedo_atlas: Texture2D
var heightmap_atlas: Texture2D
var normalmap_atlas: Texture2D
var uv_offsets: Dictionary = {}  # tile_coords -> Vector2 offset in atlas
var uv_scales: Dictionary = {}    # tile_coords -> Vector2 scale in atlas

# Internal
var centre_tile: Vector2i = Vector2i.ZERO
var tile_manager: TileManager
var grid_tiles: Array = []
var tile_instances: Dictionary = {}
var atlas_built: bool = false
var tile_height_ranges: Dictionary = {}  # Store min/max height per tile

func _enter_tree() -> void:
   update_button = Callable(self, "_set_update_button")

# Setters
func _set_save_in_scene(value: float) -> void:
    save_in_scene = value
    if not save_in_scene:
      for c in get_children():
        remove_child(c)

func _set_centre_latitude(value: float) -> void:
    centre_latitude = value
    _update_centre_tile()

func _set_centre_longitude(value: float) -> void:
    centre_longitude = value
    _update_centre_tile()

func _set_zoom(value: int) -> void:
    zoom = value
    _update_centre_tile()

func _set_update_button() -> void:
    atlas_built = false
    call_deferred("_build")

func _update_centre_tile():
    centre_tile = CoordinateConverter.lat_lon_to_tile(centre_latitude, centre_longitude, zoom)
    print("Centre coordinates: lat=", centre_latitude, " lon=", centre_longitude, " -> tile=", centre_tile)
    CoordinateConverter.set_origin_from_tile(centre_tile, zoom)

func _ready() -> void:
    _update_centre_tile()

    if not is_instance_valid(tile_manager):
        tile_manager = TileManager.new()
        tile_manager.max_concurrent_downloads = 2
        add_child(tile_manager)
        tile_manager.name = "TileManager"

    if not tile_manager.tile_loaded.is_connected(_on_tile_loaded):
        tile_manager.tile_loaded.connect(_on_tile_loaded)

func _build() -> void:
    if not is_inside_tree():
        return

    print("Building terrain grid with radius: ", grid_radius)
    print("Centre tile: ", centre_tile, " at zoom: ", zoom)

    # Clear existing tiles
    for child in get_children():
        if child != tile_manager:
            remove_child(child)
            child.queue_free()

    tile_instances.clear()
    tile_height_ranges.clear()

    # Generate tile list
    grid_tiles.clear()
    for dy in range(-grid_radius, grid_radius + 1):
        for dx in range(-grid_radius, grid_radius + 1):
            var tile := centre_tile + Vector2i(dx, dy)
            var max_tile = 1 << zoom
            if tile.x >= 0 and tile.x < max_tile and tile.y >= 0 and tile.y < max_tile:
                grid_tiles.append(tile)

    print("Building for ", grid_tiles.size(), " tiles")

    # Start building atlases
    _build_atlases()

func _build_atlases() -> void:
    print("Building atlases...")

    # Don't rebuild atlases if they're already built and we have all data
    if atlas_built and _has_all_atlas_data():
        print("Atlases already built, creating meshes...")
        _create_tile_meshes()
        return

    # Build albedo atlas
    var albedo_atlas_data = _build_albedo_atlas()
    if not albedo_atlas_data.texture:
        print("Albedo atlas not ready, downloading tiles...")
        return

    # For zoom 18, build heightmap and normalmap atlases
    if zoom == 18:
        var heightmap_atlas_data = MultiZoomTextureCompositor.build_atlas_for_grid(grid_tiles, zoom, "heightmap", tile_manager)
        var normalmap_atlas_data = MultiZoomTextureCompositor.build_atlas_for_grid(grid_tiles, zoom, "normal", tile_manager)

        if not heightmap_atlas_data.texture or not normalmap_atlas_data.texture:
            print("Heightmap or normalmap atlas not ready, downloading tiles...")
            return

        albedo_atlas = albedo_atlas_data.texture
        heightmap_atlas = heightmap_atlas_data.texture
        normalmap_atlas = normalmap_atlas_data.texture
        uv_offsets = heightmap_atlas_data.offsets
        uv_scales = heightmap_atlas_data.scales

        # Pre-calculate height ranges for all tiles
        _calculate_all_tile_height_ranges()

        atlas_built = true
        print("Atlases built successfully")
        print("Albedo atlas size: ", albedo_atlas.get_size())
        print("Heightmap atlas size: ", heightmap_atlas.get_size())
        print("Normalmap atlas size: ", normalmap_atlas.get_size())

        # Create the tile meshes with atlas textures
        _create_tile_meshes()
    else:
        print("Only zoom 18 is supported for atlas mode")

func _calculate_all_tile_height_ranges():
    tile_height_ranges.clear()
    for coords in grid_tiles:
        var height_range = _get_tile_height_range(coords)
        tile_height_ranges[coords] = height_range
        print("Tile ", coords, " height range: ", height_range.x, " to ", height_range.y)

func _get_tile_height_range(tile_coords: Vector2i) -> Vector2:
    if not heightmap_atlas:
        return Vector2(0.0, 0.0)

    var heightmap_image = heightmap_atlas.get_image()
    if heightmap_image.is_empty():
        return Vector2(0.0, 0.0)

    if not uv_offsets.has(tile_coords) or not uv_scales.has(tile_coords):
        return Vector2(0.0, 0.0)

    # Get tile's region in the atlas
    var uv_offset = uv_offsets[tile_coords]
    var uv_scale = uv_scales[tile_coords]

    var atlas_width = heightmap_image.get_width()
    var atlas_height = heightmap_image.get_height()

    # Calculate pixel coordinates in atlas
    var start_x = int(uv_offset.x * atlas_width)
    var start_y = int(uv_offset.y * atlas_height)
    var region_width = int(uv_scale.x * atlas_width)
    var region_height = int(uv_scale.y * atlas_height)

    # Sample heights to get min/max
    var min_height = INF
    var max_height = -INF

    # Sample at regular intervals (not every pixel for performance)
    var sample_step = max(1, region_width / 32)
    for y in range(start_y, start_y + region_height, sample_step):
        for x in range(start_x, start_x + region_width, sample_step):
            x = clampi(x, 0, atlas_width - 1)
            y = clampi(y, 0, atlas_height - 1)

            var color = heightmap_image.get_pixel(x, y)
            var height = HeightSampler.decode_height_from_color(color)

            min_height = min(min_height, height)
            max_height = max(max_height, height)

    if min_height == INF:
        min_height = 0.0
        max_height = 0.0

    return Vector2(min_height, max_height)

func _has_all_atlas_data() -> bool:
    return albedo_atlas != null and heightmap_atlas != null and normalmap_atlas != null and uv_offsets.size() == grid_tiles.size()

func _build_albedo_atlas() -> Dictionary:
    var atlas_data = {
        "texture": null,
        "offsets": {},
        "scales": {},
        "size": Vector2.ZERO
    }

    # Get grid bounds
    var min_x = INF
    var max_x = -INF
    var min_y = INF
    var max_y = -INF

    for coords in grid_tiles:
        if coords is Vector2i:
            min_x = min(min_x, coords.x)
            max_x = max(max_x, coords.x)
            min_y = min(min_y, coords.y)
            max_y = max(max_y, coords.y)

    var grid_width = int(max_x - min_x + 1)
    var grid_height = int(max_y - min_y + 1)

    # Create atlas image
    var tile_size = 256
    var atlas_width = grid_width * tile_size
    var atlas_height = grid_height * tile_size

    print("Creating albedo atlas: ", atlas_width, "x", atlas_height, ", grid: ", grid_width, "x", grid_height)

    var atlas_image = Image.create(atlas_width, atlas_height, false, Image.FORMAT_RGBA8)
    atlas_image.fill(Color(0, 0, 0, 0))  # Fill with transparent

    var all_tiles_ready = true

    for coords in grid_tiles:
        if not (coords is Vector2i):
            continue

        var texture = tile_manager.get_tile_data(coords, zoom, layer)
        if not texture:
            tile_manager.queue_tile_download(coords, zoom, layer)
            all_tiles_ready = false
            continue

        var tile_image = texture.get_image()
        if tile_image.is_empty():
            print("Warning: Empty image for tile ", coords)
            continue

        # Ensure image is in RGBA8 format
        if tile_image.get_format() != Image.FORMAT_RGBA8:
            tile_image.convert(Image.FORMAT_RGBA8)

        var atlas_x = int((coords.x - min_x) * tile_size)
        var atlas_y = int((coords.y - min_y) * tile_size)

        # Blit tile to atlas
        atlas_image.blit_rect(tile_image, Rect2i(0, 0, tile_size, tile_size), Vector2i(atlas_x, atlas_y))

        # Store UV data
        var atlas_size = Vector2(atlas_image.get_size())
        atlas_data.offsets[coords] = Vector2(atlas_x, atlas_y) / atlas_size
        atlas_data.scales[coords] = Vector2(tile_size, tile_size) / atlas_size

    if all_tiles_ready:
        atlas_data.texture = ImageTexture.create_from_image(atlas_image)
        atlas_data.size = atlas_image.get_size()
        print("Albedo atlas created: ", atlas_image.get_size())

    return atlas_data

func _create_tile_meshes() -> void:
    var actual_tile_size = CoordinateConverter.get_tile_size_meters(zoom)

    for dy in range(-grid_radius, grid_radius + 1):
        for dx in range(-grid_radius, grid_radius + 1):
            var tile := centre_tile + Vector2i(dx, dy)

            if not tile in grid_tiles:
                continue

            print("Creating mesh for tile: ", tile)

            # Create tile container
            var tile_root = StaticBody3D.new() if add_collision else Node3D.new()
            tile_root.name = "tile_%d_%d" % [tile.x, tile.y]

            # Create mesh instance
            var mesh_inst = MeshInstance3D.new()
            mesh_inst.name = "mesh"

            # Get height range for this tile
            var height_range = tile_height_ranges.get(tile, Vector2(0.0, 0.0))
            var min_height = height_range.x
            var max_height = height_range.y

            # Create mesh using atlas textures - shift by min_height
            var mesh = _create_tile_mesh_with_atlas(tile, actual_tile_size, min_height)
            mesh_inst.mesh = mesh

            # Set proper AABB for occlusion culling
            _set_tile_aabb(mesh_inst, actual_tile_size, min_height, max_height)

            # Set position
            var world_pos = CoordinateConverter.tile_to_world(tile, zoom)

            # Add collision if enabled
            var collisor = null
            if add_collision:
                collisor = _add_collision_to_tile(tile, actual_tile_size, min_height)
                if collisor:
                    collisor.position.y = min_height
                    tile_root.add_child(collisor)

            tile_root.position = world_pos
            mesh_inst.position = Vector3.ZERO

            tile_root.add_child(mesh_inst)
            add_child(tile_root)

            tile_instances[tile] = tile_root

            # Set owner for editor
            if save_in_scene and Engine.is_editor_hint() and get_tree().edited_scene_root:
                tile_root.owner = get_tree().edited_scene_root
                mesh_inst.owner = get_tree().edited_scene_root
                if collisor: collisor.owner = get_tree().edited_scene_root

func _set_tile_aabb(mesh_inst: MeshInstance3D, tile_size: float, min_height: float, max_height: float):
    # Calculate AABB that encompasses the entire terrain tile
    var half_size = tile_size * 0.5
    var height_range = max_height - min_height

    # Center the AABB vertically around the average height
    var center_height = (min_height + max_height) * 0.5

    # Create AABB that covers the entire tile including height displacement
    var aabb = AABB(
        Vector3(-half_size, min_height, -half_size),  # min corner
        Vector3(tile_size, height_range, tile_size)    # size
    )

    mesh_inst.set_custom_aabb(aabb)
    mesh_inst.extra_cull_margin = height_range * 0.5 + tile_size * 0.1

    print("Set AABB for tile: min=", min_height, " max=", max_height, " center=", center_height)

func _add_collision_to_tile(tile_coords: Vector2i, tile_size: float, min_height: float) -> CollisionShape3D:
    # Create heightmap collision shape with scaled height data for uniform scaling
    var heightmap_shape = _create_heightmap_collision_shape(tile_coords, tile_size, min_height)
    var collision_shape = CollisionShape3D.new()

    if heightmap_shape:
        collision_shape.shape = heightmap_shape

        # Calculate uniform scale factor
        var mesh_vertices_per_side = 32  # 31 subdivisions = 32 vertices
        var horizontal_scale_factor = tile_size / (mesh_vertices_per_side - 1)

        # We want uniform scaling, so we need to scale the height data in the shape
        # to match the horizontal scale. HeightMapShape3D assumes 1 unit per grid cell.
        # We'll scale everything uniformly by horizontal_scale_factor.
        collision_shape.scale = Vector3(horizontal_scale_factor, horizontal_scale_factor, horizontal_scale_factor)

        # Position the collision shape to center it
        collision_shape.position = Vector3.ZERO

        print("Added uniformly scaled heightmap collision to tile: ", tile_coords,
              " with scale: ", collision_shape.scale)
    else:
        # Fallback to box collision
        var box_shape = BoxShape3D.new()
        var height_range = tile_height_ranges.get(tile_coords, Vector2(0.0, 1000.0))
        box_shape.size = Vector3(tile_size, height_range.y - height_range.x, tile_size)
        collision_shape.shape = box_shape
        collision_shape.position = Vector3(0, (height_range.x + height_range.y) * 0.5, 0)

        print("Added box collision to tile: ", tile_coords)

    return collision_shape

func _create_heightmap_collision_shape(tile_coords: Vector2i, tile_size: float, min_height: float) -> HeightMapShape3D:
    if not heightmap_atlas:
        return null

    var heightmap_image = heightmap_atlas.get_image()
    if heightmap_image.is_empty():
        return null

    if not uv_offsets.has(tile_coords) or not uv_scales.has(tile_coords):
        return null

    # Get tile's region in the atlas
    var uv_offset = uv_offsets[tile_coords]
    var uv_scale = uv_scales[tile_coords]

    var atlas_width = heightmap_image.get_width()
    var atlas_height = heightmap_image.get_height()

    # Calculate pixel coordinates in atlas
    var start_x = int(uv_offset.x * atlas_width)
    var start_y = int(uv_offset.y * atlas_height)
    var region_width = int(uv_scale.x * atlas_width)
    var region_height = int(uv_scale.y * atlas_height)

    # Use the same resolution as our mesh (32x32 vertices = 31 subdivisions + 1)
    var collision_resolution = 32
    var height_data = PackedFloat32Array()
    height_data.resize(collision_resolution * collision_resolution)

    # Calculate sampling step
    var step_x = float(region_width - 1) / (collision_resolution - 1)
    var step_y = float(region_height - 1) / (collision_resolution - 1)

    # For uniform scaling, we need to adjust the height values
    # so that when scaled uniformly, they match the actual terrain height
    var horizontal_scale_factor = tile_size / (collision_resolution - 1)

    # Sample heights from atlas
    for z in range(collision_resolution):
        for x in range(collision_resolution):
            var sample_x = start_x + int(x * step_x)
            var sample_y = start_y + int(z * step_y)

            # Clamp to image bounds
            sample_x = clampi(sample_x, 0, atlas_width - 1)
            sample_y = clampi(sample_y, 0, atlas_height - 1)

            var color = heightmap_image.get_pixel(sample_x, sample_y)
            var raw_height = HeightSampler.decode_height_from_color(color)

            # Adjust height for uniform scaling:
            # When we scale uniformly by horizontal_scale_factor,
            # the height needs to be scaled by the same factor.
            # So we divide by horizontal_scale_factor to compensate.
            var adjusted_height = (raw_height - min_height) / horizontal_scale_factor

            height_data[z * collision_resolution + x] = adjusted_height

    # Create heightmap shape
    var heightmap_shape = HeightMapShape3D.new()
    heightmap_shape.map_width = collision_resolution
    heightmap_shape.map_depth = collision_resolution
    heightmap_shape.map_data = height_data

    print("Created heightmap shape for tile ", tile_coords,
          " with uniform scaling adjustment")

    return heightmap_shape

func _create_tile_mesh_with_atlas(tile_coords: Vector2i, tile_size: float, min_height: float) -> Mesh:
    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(tile_size, tile_size)
    plane_mesh.subdivide_depth = 31
    plane_mesh.subdivide_width = 31

    # Create shader material with atlas support
    var shader_mat = ShaderMaterial.new()
    shader_mat.shader = preload("../shaders/terrain_shader.gdshader")

    # Set atlas textures
    if albedo_atlas:
        shader_mat.set_shader_parameter("albedo_atlas", albedo_atlas)

    if heightmap_atlas:
        shader_mat.set_shader_parameter("heightmap_atlas", heightmap_atlas)

    if normalmap_atlas:
        shader_mat.set_shader_parameter("normalmap_atlas", normalmap_atlas)
        shader_mat.set_shader_parameter("use_precomputed_normals", true)
    else:
        shader_mat.set_shader_parameter("use_precomputed_normals", false)

    # Set UV offset and scale for this specific tile
    if uv_offsets.has(tile_coords) and uv_scales.has(tile_coords):
        shader_mat.set_shader_parameter("uv_offset", uv_offsets[tile_coords])
        shader_mat.set_shader_parameter("uv_scale", uv_scales[tile_coords])
    else:
        print("Warning: No UV data for tile ", tile_coords)
        shader_mat.set_shader_parameter("uv_offset", Vector2.ZERO)
        shader_mat.set_shader_parameter("uv_scale", Vector2.ONE)

    # Pass min_height to shader to shift the terrain upward
    shader_mat.set_shader_parameter("min_height", min_height)
    shader_mat.set_shader_parameter("terrain_scale", tile_size)
    shader_mat.set_shader_parameter("height_scale", 1.0)

    plane_mesh.material = shader_mat

    return plane_mesh

func _on_tile_loaded(coords: Vector2i, z: int, layer_data: Dictionary):
    # Check if this affects any of our tiles
    var should_rebuild = false

    if z == zoom and coords in grid_tiles and layer == "googlemt":
        should_rebuild = true
        atlas_built = false
    elif z == 15:
        # Check if this zoom15 tile is needed for any of our zoom18 tiles
        for tile in grid_tiles:
            if zoom == 18 and _get_zoom15_tile_coords(tile) == coords:
                should_rebuild = true
                atlas_built = false
                break

    if should_rebuild:
        print("Tile loaded that affects our grid, rebuilding...")
        call_deferred("_build")

func _get_zoom15_tile_coords(zoom18_tile: Vector2i) -> Vector2i:
    return Vector2i(zoom18_tile.x >> 3, zoom18_tile.y >> 3)
