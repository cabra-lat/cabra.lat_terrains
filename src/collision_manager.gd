class_name CollisionManager
extends Node

@export var enable_collision: bool = true
@export var collision_resolution: int = 256
@export var collision_lod_threshold: float = 500.0
@export var max_concurrent_collision_generations: int = 1
@export var use_collision_threading: bool = false

var collision_generation_queue: Array = []
var active_collision_generations: int = 0
var collision_mutex: Mutex
var collision_thread: Thread
var collision_shapes: Dictionary = {}
var current_collision_body: StaticBody3D = null

var terrain_loader: DynamicTerrainLoader

func setup(loader: DynamicTerrainLoader):
    terrain_loader = loader
    collision_mutex = Mutex.new()

func queue_collision_generation(tile_coords: Vector2i, zoom: int, texture: Texture2D):
    if not enable_collision:
        return

    collision_mutex.lock()
    collision_generation_queue.append({
        "coords": tile_coords,
        "zoom": zoom,
        "texture": texture
    })
    collision_mutex.unlock()

func process_collision_queue():
    collision_mutex.lock()
    if collision_generation_queue.size() > 0 and active_collision_generations < max_concurrent_collision_generations:
        var collision_job = collision_generation_queue.pop_front()
        active_collision_generations += 1
        collision_mutex.unlock()

        if use_collision_threading and collision_thread == null:
            collision_thread = Thread.new()
            collision_thread.start(generate_collision_threaded.bind(collision_job))
        else:
            generate_collision_for_tile(collision_job["coords"], collision_job["zoom"], collision_job["texture"])
            active_collision_generations -= 1
    else:
        collision_mutex.unlock()

func generate_collision_threaded(collision_job):
    var tile_coords = collision_job["coords"]
    var zoom = collision_job["zoom"]
    var texture = collision_job["texture"]

    var collision_shape = generate_collision_shape_corrected(texture, zoom)

    if collision_shape:
        call_deferred("_on_collision_generation_complete", tile_coords, zoom, collision_shape)
    else:
        collision_mutex.lock()
        active_collision_generations -= 1
        collision_mutex.unlock()

func _on_collision_generation_complete(tile_coords: Vector2i, zoom: int, collision_shape: HeightMapShape3D):
    var tile_key = CoordinateConverter.get_tile_key(tile_coords, zoom)
    collision_shapes[tile_key] = collision_shape

    if tile_coords == terrain_loader.current_tile_coords and zoom == terrain_loader.lod_manager.current_zoom:
        update_current_collision_body(collision_shape, tile_coords, zoom)
        # Notify terrain loader that collision is ready
        terrain_loader.collision_ready = true

    collision_mutex.lock()
    active_collision_generations -= 1
    collision_mutex.unlock()

    if collision_thread and collision_thread.is_started():
        collision_thread.wait_to_finish()
        collision_thread = null

func generate_collision_for_tile(tile_coords: Vector2i, zoom: int, texture: Texture2D):
    var tile_key = CoordinateConverter.get_tile_key(tile_coords, zoom)

    if collision_shapes.has(tile_key):
        update_current_collision_body(collision_shapes[tile_key], tile_coords, zoom)
        terrain_loader.collision_ready = true
        return

    var collision_shape = generate_collision_shape_corrected(texture, zoom)
    if collision_shape:
        collision_shapes[tile_key] = collision_shape
        update_current_collision_body(collision_shape, tile_coords, zoom)
        terrain_loader.collision_ready = true

func update_current_collision_body(collision_shape: HeightMapShape3D, tile_coords: Vector2i, zoom: int):
    if current_collision_body:
        current_collision_body.queue_free()

    current_collision_body = create_collision_body_from_shape(collision_shape, zoom)
    terrain_loader.add_child(current_collision_body)
    print("Collision body updated for tile: ", tile_coords)

func generate_collision_shape_corrected(texture: Texture2D, current_zoom: int) -> HeightMapShape3D:
    var image = texture.get_image()
    var image_size = image.get_size()

    var collision_width = image_size.x
    var collision_depth = image_size.y
    var height_data = PackedFloat32Array()
    height_data.resize(collision_width * collision_depth)

    print("Generating CORRECTED collision shape - Image size: ", image_size, " Data size: ", height_data.size())

    # FIXED: Use the correct orientation for Godot's HeightMapShape3D
    # HeightMapShape3D expects data in row-major order: [z * width + x]
    # But we need to account for coordinate system differences

    for z in range(collision_depth):
        for x in range(collision_width):
            # Use the same UV coordinates as the visual mesh
            var u = float(x) / (collision_width - 1)
            var v = float(z) / (collision_depth - 1)
            var absolute_elevation = HeightSampler.sample_height_at_uv(image, u, v)

            # Store in row-major order: [z * width + x]
            height_data[z * collision_width + x] = absolute_elevation

    var heightmap_shape = HeightMapShape3D.new()
    heightmap_shape.map_width = collision_width
    heightmap_shape.map_depth = collision_depth
    heightmap_shape.map_data = height_data

    # Debug the collision data
    debug_collision_data(height_data, collision_width, collision_depth)

    return heightmap_shape

func debug_collision_data(height_data: PackedFloat32Array, width: int, depth: int):
    print("=== COLLISION DATA DEBUG ===")
    print("Data array size: ", height_data.size())
    print("Width: ", width, " Depth: ", depth)

    # Check corners
    var corners = [
        {"name": "Bottom-Left", "index": 0},
        {"name": "Bottom-Right", "index": width - 1},
        {"name": "Top-Left", "index": (depth - 1) * width},
        {"name": "Top-Right", "index": (depth - 1) * width + (width - 1)}
    ]

    for corner in corners:
        print("  ", corner.name, " [", corner.index, "]: ", height_data[corner.index], "m")

func create_collision_body_from_shape(shape: HeightMapShape3D, current_zoom: int) -> StaticBody3D:
    var static_body = StaticBody3D.new()
    var collision_shape = CollisionShape3D.new()
    collision_shape.shape = shape

    # Get the current tile size
    var tile_size_meters = CoordinateConverter.get_tile_size_meters(current_zoom)

    # FIXED: Proper scaling - the collision shape spans the entire tile
    # HeightMapShape3D covers from (0,0) to (width-1, depth-1) in local space
    # We need to scale it to match our tile size
    var scale_x = tile_size_meters / (shape.map_width - 1)
    var scale_z = tile_size_meters / (shape.map_depth - 1)

    collision_shape.scale = Vector3(scale_x, 1.0, scale_z)
    collision_shape.rotation = Vector3(0.0, PI/2, 0.0)
    # FIXED: Position the collision shape to center it at (0,0,0)
    # The HeightMapShape3D starts at (0,0) so we need to offset it
    var offset_x = -tile_size_meters / 2.0
    var offset_z = -tile_size_meters / 2.0
    collision_shape.position = Vector3(offset_x, 0, offset_z)

    static_body.add_child(collision_shape)

    print("Collision body created:")
    print("  Scale: (", scale_x, ", 1.0, ", scale_z, ")")
    print("  CollisionShape Position: ", collision_shape.position)
    print("  Tile size: ", tile_size_meters, "m")
    return static_body

func cleanup():
    if collision_thread and collision_thread.is_started():
        collision_thread.wait_to_finish()
