# CollisionManager.gd
class_name CollisionManager
extends Node

signal collision_ready(tile_coords, zoom)

@export_category("Collision Settings")
@export var enable_collision: bool = true
@export var collision_resolution: int = 256
@export var max_concurrent_generations: int = 1
@export var use_threading: bool = false

# Always use highest detail for collision
const COLLISION_ZOOM_LEVEL: int = 15

var _generation_queue: Array = []
var _active_generations: int = 0
var _mutex: Mutex
var _thread: Thread
var _collision_shapes: Dictionary = {}
var _current_collision_body: StaticBody3D = null

var _terrain_loader: DynamicTerrainLoader


func setup(loader: DynamicTerrainLoader) -> void:
    _terrain_loader = loader
    _mutex = Mutex.new()


func queue_collision_generation(tile_coords: Vector2i, texture: Texture2D) -> void:
    if not enable_collision:
        return

    _mutex.lock()
    _generation_queue.append(CollisionJob.new(tile_coords, COLLISION_ZOOM_LEVEL, texture))
    _mutex.unlock()


func process_queue() -> void:
    _mutex.lock()

    if _generation_queue.is_empty() or _active_generations >= max_concurrent_generations:
        _mutex.unlock()
        return

    var job: CollisionJob = _generation_queue.pop_front()
    _active_generations += 1
    _mutex.unlock()

    _start_collision_generation(job)


func _start_collision_generation(job: CollisionJob) -> void:
    if use_threading and _thread == null:
        _thread = Thread.new()
        _thread.start(_generate_collision_threaded.bind(job))
    else:
        _generate_collision_for_tile(job)
        _active_generations -= 1


func _generate_collision_threaded(job: CollisionJob) -> void:
    var collision_shape = _generate_collision_shape(job.texture)

    if collision_shape:
        call_deferred("_on_collision_generation_complete", job.tile_coords, COLLISION_ZOOM_LEVEL, collision_shape)
    else:
        _mutex.lock()
        _active_generations -= 1
        _mutex.unlock()


func _on_collision_generation_complete(tile_coords: Vector2i, zoom: int, collision_shape: HeightMapShape3D) -> void:
    var tile_key = CoordinateConverter.get_tile_key(tile_coords, zoom)
    _collision_shapes[tile_key] = collision_shape

    if _should_update_current_collision(tile_coords):
        _update_current_collision_body(collision_shape, tile_coords)
        _terrain_loader.collision_ready = true

    _mutex.lock()
    _active_generations -= 1
    _mutex.unlock()

    if _thread and _thread.is_started():
        _thread.wait_to_finish()
        _thread = null


func _generate_collision_for_tile(job: CollisionJob) -> void:
    var tile_key = CoordinateConverter.get_tile_key(job.tile_coords, COLLISION_ZOOM_LEVEL)

    if _collision_shapes.has(tile_key):
        _update_current_collision_body(_collision_shapes[tile_key], job.tile_coords)
        _terrain_loader.collision_ready = true
        collision_ready.emit(job.tile_coords, COLLISION_ZOOM_LEVEL)
        return

    var collision_shape = _generate_collision_shape(job.texture)
    if collision_shape:
        _collision_shapes[tile_key] = collision_shape
        _update_current_collision_body(collision_shape, job.tile_coords)
        _terrain_loader.collision_ready = true
        collision_ready.emit(job.tile_coords, COLLISION_ZOOM_LEVEL)


func _generate_collision_shape(texture: Texture2D) -> HeightMapShape3D:
    var image = texture.get_image()
    var size = image.get_size()

    print("Generating collision at zoom ", COLLISION_ZOOM_LEVEL, " - Image size: ", size)

    var height_data = _sample_height_data(image, size)
    var heightmap_shape = HeightMapShape3D.new()

    heightmap_shape.map_width = size.x
    heightmap_shape.map_depth = size.y
    heightmap_shape.map_data = height_data

    print("High-res collision shape generated: ", size.x, "x", size.y)
    return heightmap_shape


func _sample_height_data(image: Image, size: Vector2i) -> PackedFloat32Array:
    var height_data = PackedFloat32Array()
    height_data.resize(size.x * size.y)

    for z in range(size.y):
        for x in range(size.x):
            var u = float(x) / (size.x - 1)
            var v = float(z) / (size.y - 1)
            var elevation = HeightSampler.sample_height_bilinear(image, u, v)
            height_data[z * size.x + x] = elevation

    return height_data


func _update_current_collision_body(collision_shape: HeightMapShape3D, tile_coords: Vector2i) -> void:
    if _current_collision_body:
        _current_collision_body.queue_free()

    _current_collision_body = _create_collision_body(collision_shape)
    _terrain_loader.add_child(_current_collision_body)
    print("High-res collision body updated for tile: ", tile_coords)
    collision_ready.emit(tile_coords, COLLISION_ZOOM_LEVEL)


func _create_collision_body(shape: HeightMapShape3D) -> StaticBody3D:
    var static_body = StaticBody3D.new()
    var collision_shape = CollisionShape3D.new()
    collision_shape.shape = shape

    var tile_size = CoordinateConverter.get_tile_size_meters(COLLISION_ZOOM_LEVEL)

    # Proper scale calculation for HeightMapShape3D
    var scale_x = tile_size / (shape.map_width - 1)
    var scale_z = tile_size / (shape.map_depth - 1)

    collision_shape.scale = Vector3(scale_x, 1.0, scale_z)
    # No position offset needed - planes are centralized by default

    static_body.add_child(collision_shape)

    print("High-res collision body - Scale: (", scale_x, ", 1.0, ", scale_z, ")")
    print("Tile size: ", tile_size, "m")
    return static_body


func _should_update_current_collision(tile_coords: Vector2i) -> bool:
    return tile_coords == _terrain_loader.current_tile_coords


func get_collision_shape(tile_coords: Vector2i) -> HeightMapShape3D:
    var tile_key = CoordinateConverter.get_tile_key(tile_coords, COLLISION_ZOOM_LEVEL)
    return _collision_shapes.get(tile_key)


func cleanup_old_collisions(current_tile_coords: Vector2i, max_keep: int = 3) -> void:
    var tiles_to_remove = []

    for tile_key in _collision_shapes:
        var parts = tile_key.split("_")
        if parts.size() == 3:
            var coords = Vector2i(int(parts[0]), int(parts[1]))
            var distance = abs(coords.x - current_tile_coords.x) + abs(coords.y - current_tile_coords.y)
            if distance > max_keep:
                tiles_to_remove.append(tile_key)

    for tile_key in tiles_to_remove:
        _collision_shapes.erase(tile_key)
        print("Removed old collision: ", tile_key)


func cleanup() -> void:
    if _thread and _thread.is_started():
        _thread.wait_to_finish()


func debug_status() -> void:
    print("=== COLLISION MANAGER DEBUG ===")
    print("Collision shapes cached: ", _collision_shapes.size())
    print("Current collision body: ", _current_collision_body != null)
    print("Generation queue: ", _generation_queue.size())
    print("Active generations: ", _active_generations)
    print("Always using zoom level: ", COLLISION_ZOOM_LEVEL, " for collision")

    if _current_collision_body:
        var collision_shape = _current_collision_body.get_child(0) as CollisionShape3D
        if collision_shape and collision_shape.shape is HeightMapShape3D:
            var shape = collision_shape.shape as HeightMapShape3D
            print("Current collision shape: ", shape.map_width, "x", shape.map_depth)
            print("Collision shape scale: ", collision_shape.scale)


class CollisionJob:
    var tile_coords: Vector2i
    var zoom: int
    var texture: Texture2D

    func _init(coords: Vector2i, zoom_level: int, tex: Texture2D) -> void:
        tile_coords = coords
        zoom = zoom_level
        texture = tex
