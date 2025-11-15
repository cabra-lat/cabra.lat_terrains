class_name CollisionManager
extends Node

signal collision_ready(tile_coords: Vector2i, zoom: int)
signal collision_generation_failed(tile_coords: Vector2i, zoom: int)

@export_category("Collision Settings")
@export var enable_collision: bool = true
@export var max_concurrent_generations: int = 2
# Always use highest detail for collision
const COLLISION_ZOOM_LEVEL: int = 15
var _generation_queue: Array = []
var _active_generations: int = 0
var _mutex: Mutex
var _worker_threads: Array = []
var _semaphore: Semaphore
var _collision_shapes: Dictionary = {}
var _collision_bodies: Dictionary = {}  # tile_key -> StaticBody3D
var _current_collision_body: StaticBody3D = null
var _terrain_loader: DynamicTerrainLoader
var _max_cache_size: int = 10
var _current_tile_key: String = ""

func setup(loader: DynamicTerrainLoader) -> void:
    _terrain_loader = loader
    _mutex = Mutex.new()
    _semaphore = Semaphore.new()

    # Initialize worker threads
    for i in range(max_concurrent_generations):
        var thread = Thread.new()
        thread.start(_collision_worker_thread.bind(i))
        _worker_threads.append(thread)

func _ready() -> void:
    # Start all worker threads
    for thread in _worker_threads:
        if not thread.is_started():
            thread.start()

func on_tile_loaded(tile_coords: Vector2i, zoom: int, data: Dictionary) -> void:
    # Pass the original zoom for positioning
    queue_collision_generation(tile_coords, data["heightmap"], zoom)

func queue_collision_generation(tile_coords: Vector2i, texture: Texture2D, position_zoom: int) -> void:
    if not enable_collision:
        return

    _mutex.lock()
    var tile_key = TileManager.get_tile_key(tile_coords, position_zoom)  # Use position_zoom for key

    # Check if already in queue
    for job in _generation_queue:
        if job.tile_coords == tile_coords and job.position_zoom == position_zoom:
            _mutex.unlock()
            return

    _generation_queue.append(CollisionJob.new(tile_coords, COLLISION_ZOOM_LEVEL, texture, position_zoom))
    _mutex.unlock()

    _semaphore.post()

func _collision_worker_thread(worker_id: int) -> void:
    while true:
        _semaphore.wait()

        _mutex.lock()
        if _generation_queue.is_empty():
            _mutex.unlock()
            continue

        var job: CollisionJob = _generation_queue.pop_front()
        _active_generations += 1
        _mutex.unlock()

        var collision_shape = _generate_collision_shape(job.texture, job.tile_coords)

        if collision_shape:
            call_deferred("_on_collision_generation_complete", job.tile_coords, job.zoom, collision_shape, job.position_zoom)
        else:
            call_deferred("_on_collision_generation_failed", job.tile_coords, job.zoom)

        _mutex.lock()
        _active_generations -= 1
        _mutex.unlock()

func _generate_collision_shape(texture: Texture2D, tile_coords: Vector2i) -> HeightMapShape3D:
    var image = texture.get_image()
    var size = image.get_size()

    # Downsample if necessary to meet resolution requirements
    if size.x > 256 or size.y > 256:
        var new_image = Image.new()
        var scale = max(size.x / 256.0, size.y / 256.0)
        new_image.create(size.x / scale, size.y / scale, false, Image.FORMAT_RGB8)
        new_image.blit_rect(image, Rect2(0, 0, size.x, size.y), Vector2i.ZERO)
        image = new_image

    var height_data = _sample_height_data(image, size)
    var heightmap_shape = HeightMapShape3D.new()

    heightmap_shape.map_width = size.x
    heightmap_shape.map_depth = size.y
    heightmap_shape.map_data = height_data

    return heightmap_shape

func _sample_height_data(image: Image, size: Vector2i) -> PackedFloat32Array:
    var height_data = PackedFloat32Array()
    height_data.resize(size.x * size.y)

    for z in range(size.y):
        for x in range(size.x):
            var color = image.get_pixel(x, z)
            height_data[z * size.x + x] = HeightSampler.decode_height_from_color(color)

    return height_data

func _add_collision_body(tile_coords: Vector2i, collision_shape: HeightMapShape3D, position_zoom: int) -> void:
    var tile_key = TileManager.get_tile_key(tile_coords, position_zoom)  # Use position_zoom

    if _collision_bodies.has(tile_key):
        print("Collision body already exists, skipping: ", tile_coords)
        return

    var static_body = StaticBody3D.new()
    var collision_shape_node = CollisionShape3D.new()
    collision_shape_node.shape = collision_shape

    # Calculate scale and position using position_zoom
    var tile_size = CoordinateConverter.get_tile_size_meters(position_zoom)
    var scale_x = tile_size / (collision_shape.map_width - 1)
    var scale_z = tile_size / (collision_shape.map_depth - 1)
    collision_shape_node.scale = Vector3(scale_x, 1.0, scale_z)

    # Position using position_zoom
    var world_position = CoordinateConverter.tile_to_world(tile_coords, position_zoom)
    var origin = CoordinateConverter.lat_lon_to_world(
        _terrain_loader.start_latitude,
        _terrain_loader.start_longitude,
        position_zoom
    )

    # Center the tile
    world_position.x -= tile_size / 2.0
    world_position.z -= tile_size / 2.0
    static_body.position = world_position - origin

    static_body.add_child(collision_shape_node)
    _terrain_loader.add_child(static_body)

    _collision_bodies[tile_key] = static_body
    _current_collision_body = static_body
    _current_tile_key = tile_key
    print("Collision body added for tile: ", tile_coords, " at position: ", static_body.position)

func _on_collision_generation_complete(tile_coords: Vector2i, zoom: int, collision_shape: HeightMapShape3D, position_zoom: int) -> void:
    var tile_key = TileManager.get_tile_key(tile_coords, position_zoom)
    _collision_shapes[tile_key] = collision_shape

    if _should_update_current_collision(tile_coords):
        _update_current_collision_body(collision_shape, tile_coords, position_zoom)

    collision_ready.emit(tile_coords, zoom)
    _cleanup_old_collisions()

func _on_collision_generation_failed(tile_coords: Vector2i, zoom: int) -> void:
    collision_generation_failed.emit(tile_coords, zoom)
    _mutex.lock()
    _active_generations -= 1
    _mutex.unlock()

func _update_current_collision_body(collision_shape: HeightMapShape3D, tile_coords: Vector2i, position_zoom: int) -> void:
    if not _should_update_current_collision(tile_coords):
        return

    if _current_collision_body:
        _current_collision_body.queue_free()
        _current_collision_body = null

    _current_collision_body = _create_collision_body(collision_shape, tile_coords, position_zoom)
    _current_collision_body.set_name("CollisionBody_%s_%d" % [tile_coords, position_zoom])
    _terrain_loader.add_child(_current_collision_body)

    _current_tile_key = TileManager.get_tile_key(tile_coords, position_zoom)
    print("Collision body updated for tile: ", tile_coords, " zoom: ", position_zoom)

func _create_collision_body(shape: HeightMapShape3D, tile_coords: Vector2i, position_zoom: int) -> StaticBody3D:
    var static_body = StaticBody3D.new()
    var collision_shape = CollisionShape3D.new()
    collision_shape.shape = shape

    # Use position_zoom for all calculations
    var tile_size = CoordinateConverter.get_tile_size_meters(position_zoom)
    var scale_x = tile_size / (shape.map_width - 1)
    var scale_z = tile_size / (shape.map_depth - 1)
    collision_shape.scale = Vector3(scale_x, 1.0, scale_z)

    static_body.position = CoordinateConverter.get_tile_center_world_pos(
        tile_coords, position_zoom,
        _terrain_loader.start_latitude,
        _terrain_loader.start_longitude
    )

    static_body.add_child(collision_shape)
    return static_body

func _should_update_current_collision(tile_coords: Vector2i) -> bool:
    return tile_coords == _terrain_loader.current_tile_coords

func get_collision_shape(tile_coords: Vector2i) -> HeightMapShape3D:
    var tile_key = TileManager.get_tile_key(tile_coords, COLLISION_ZOOM_LEVEL)
    return _collision_shapes.get(tile_key)

func unload_collision(tile_coords: Vector2i, zoom: int) -> void:
    var tile_key = TileManager.get_tile_key(tile_coords, zoom)
    _remove_collision_body(tile_coords, zoom)

func _remove_collision_body(tile_coords: Vector2i, zoom: int) -> void:
    var tile_key = TileManager.get_tile_key(tile_coords, zoom)
    if _collision_bodies.has(tile_key):
        var body = _collision_bodies[tile_key]
        if is_instance_valid(body):
            body.queue_free()
        _collision_bodies.erase(tile_key)
        if _current_tile_key == tile_key:
            _current_tile_key = ""
        print("Collision body removed for tile: ", tile_coords)

func unload_all_except(keep_tiles: Array) -> void:
    var tiles_to_remove = []
    for tile_key in _collision_bodies:
        var should_keep = false
        for keep_tile in keep_tiles:
            var keep_key = TileManager.get_tile_key(keep_tile.coords, keep_tile.zoom)
            if tile_key == keep_key:
                should_keep = true
                break
        if not should_keep:
            tiles_to_remove.append(tile_key)

    for tile_key in tiles_to_remove:
        var parts = tile_key.split("_")
        if parts.size() == 3:
            var coords = Vector2i(int(parts[0]), int(parts[1]))
            var zoom = int(parts[2])
            unload_collision(coords, zoom)

func _cleanup_old_collisions() -> void:
    # Keep only the current tile and adjacent tiles (3x3 grid)
    var tiles_to_keep = []
    var current_tile = _terrain_loader.current_tile_coords

    for dx in range(-1, 2):
        for dy in range(-1, 2):
            var neighbor = Vector2i(current_tile.x + dx, current_tile.y + dy)
            tiles_to_keep.append({"coords": neighbor, "zoom": COLLISION_ZOOM_LEVEL})

    # Remove old collision shapes
    var tiles_to_remove = []
    for tile_key in _collision_shapes:
        var should_keep = false
        for keep_tile in tiles_to_keep:
            var keep_key = TileManager.get_tile_key(keep_tile.coords, keep_tile.zoom)
            if tile_key == keep_key:
                should_keep = true
                break
        if not should_keep:
            tiles_to_remove.append(tile_key)

    # Remove collision shapes
    for tile_key in tiles_to_remove:
        _collision_shapes.erase(tile_key)
        if _collision_bodies.has(tile_key):
            var body = _collision_bodies[tile_key]
            if is_instance_valid(body):
                body.queue_free()
            _collision_bodies.erase(tile_key)
            print("Removed collision for tile: ", tile_key)

    # Limit cache size
    if _collision_shapes.size() > _max_cache_size:
        # Remove oldest items
        var keys = _collision_shapes.keys()
        for i in range(_collision_shapes.size() - _max_cache_size):
            var key = keys[i]
            _collision_shapes.erase(key)
            if _collision_bodies.has(key):
                var body = _collision_bodies[key]
                if is_instance_valid(body):
                    body.queue_free()
                _collision_bodies.erase(key)
                print("Removed old collision: ", key)

func debug_status() -> void:
    print("=== COLLISION MANAGER ===")
    print("Shapes cached: ", _collision_shapes.size())
    print("Bodies active: ", _collision_bodies.size())
    print("Queue: ", _generation_queue.size())
    print("Active generations: ", _active_generations)
    print("Current tile key: ", _current_tile_key)
    for tile_key in _collision_bodies:
        var body = _collision_bodies[tile_key]
        if is_instance_valid(body):
            print("  - ", tile_key, ": ", body.position)

class CollisionJob:
    var tile_coords: Vector2i
    var zoom: int              # Heightmap zoom (COLLISION_ZOOM_LEVEL)
    var texture: Texture2D
    var position_zoom: int     # Positioning zoom (from LOD)

    func _init(coords: Vector2i, zoom_level: int, tex: Texture2D, pos_zoom: int) -> void:
        tile_coords = coords
        zoom = zoom_level
        texture = tex
        position_zoom = pos_zoom
