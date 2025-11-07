class_name DynamicTerrainLoader
extends Node3D

@export_category("Player Tracking")
@export var target_node: Node3D
@export var update_interval: float = 1.0

@export_category("World Settings")
@export var start_latitude: float = -15.708
@export var start_longitude: float = -48.560
@export var world_scale: float = 1.0
@export var max_view_distance: float = 2000.0

@export_category("Collision Settings")
@export var enable_collision: bool = true
@export var collision_resolution: int = 256
@export var max_concurrent_generations: int = 1
@export var use_threading: bool = false

@export_category("LOD Settings")
@export var min_zoom: int = 15
@export var max_zoom: int = 10
@export var lod_max_height: float = 8000.0
@export var lod_min_height: float = 50.0

@export_category("Tile Management Settings")
@export var max_concurrent_downloads: int = 2
@export var cache_size: int = 25
@export var download_heightmaps: bool = true
@export var download_normal_maps: bool = true

@export_category("Terrain Mesh Settings")
@export var use_normal_maps: bool = true
@export var use_precomputed_normals: bool = true

var current_tile_coords: Vector2i
var time_since_last_update: float = 0.0
var collision_ready: bool = false
var waiting_for_collision: bool = false

var _tile_manager: TileManager
var _collision_manager: CollisionManager
var _lod_manager: LODManager
var _terrain_mesh_manager: TerrainMeshManager

# Public getters
var lod_manager: LODManager:
    get: return _lod_manager

var collision_manager: CollisionManager:
    get: return _collision_manager

var terrain_mesh_manager: TerrainMeshManager:
    get: return _terrain_mesh_manager

var tile_manager: TileManager:
    get: return _tile_manager


func _ready() -> void:
    _initialize_managers()
    await get_tree().create_timer(3.0).timeout
    call_deferred("update_terrain")
    call_deferred("_spawn_player_at_terrain_safe")


func _initialize_managers() -> void:
    _tile_manager = TileManager.new()
    _tile_manager.setup(self)
    add_child(_tile_manager)

    _collision_manager = CollisionManager.new()
    _collision_manager.setup(self)
    _collision_manager.collision_ready.connect(_on_collision_ready)
    add_child(_collision_manager)

    _lod_manager = LODManager.new()
    _lod_manager.setup(self)
    add_child(_lod_manager)

    _terrain_mesh_manager = TerrainMeshManager.new()
    _terrain_mesh_manager.setup(self)
    add_child(_terrain_mesh_manager)


func _on_collision_ready(tile_coords: Vector2i, zoom: int) -> void:
    collision_ready = true
    print("High-res collision ready for tile: ", tile_coords)

    if waiting_for_collision:
        waiting_for_collision = false
        call_deferred("_spawn_player_at_terrain_safe")


func _physics_process(delta: float) -> void:
    time_since_last_update += delta
    _collision_manager.process_queue()

    if time_since_last_update >= update_interval:
        time_since_last_update = 0.0
        update_terrain()


func update_terrain() -> void:
    if not target_node:
        return

    var player_pos = target_node.global_position

    # Calculate height above terrain for LOD
    var terrain_height = _terrain_mesh_manager.get_terrain_elevation_at_position(player_pos)
    var height_above_terrain = max(0.0, player_pos.y - terrain_height)

    var new_zoom = _lod_manager.calculate_dynamic_zoom(height_above_terrain)
    var new_tile_coords = CoordinateConverter.world_to_tile_coords(player_pos, start_latitude, start_longitude, new_zoom)

    if new_tile_coords != current_tile_coords or new_zoom != _lod_manager.current_zoom:
        current_tile_coords = new_tile_coords
        _lod_manager.current_zoom = new_zoom

        _load_new_terrain(new_tile_coords, new_zoom)


func _load_new_terrain(tile_coords: Vector2i, zoom: int) -> void:
    _tile_manager.load_tile_and_neighbors(tile_coords, zoom)
    _terrain_mesh_manager.update_for_tile(tile_coords, zoom)
    _load_collision_tile(tile_coords)


func _load_collision_tile(tile_coords: Vector2i) -> void:
    # Always use highest detail for collision (zoom 15)
    var collision_texture = _tile_manager.get_texture_for_tile(tile_coords, _collision_manager.COLLISION_ZOOM_LEVEL, TileTextureType.TERRARIUM)

    if collision_texture:
        print("Loading high-res collision for tile: ", tile_coords)
        _collision_manager.queue_collision_generation(tile_coords, collision_texture)
        waiting_for_collision = true
        collision_ready = false
    else:
        print("No high-res texture available for collision at tile: ", tile_coords)


func _spawn_player_at_terrain_safe() -> void:
    if not target_node:
        return

    var player_xz = Vector3(target_node.global_position.x, 0, target_node.global_position.z)
    var elevation = _terrain_mesh_manager.get_terrain_elevation_at_position(player_xz)

    if _is_valid_elevation(elevation):
        var new_position = Vector3(
            target_node.global_position.x,
            elevation + 1.8,  # Eye height
            target_node.global_position.z
        )

        print("Spawning player at terrain elevation: ", elevation, "m")
        target_node.global_position = new_position
        _reset_player_physics()
        waiting_for_collision = false
    else:
        print("Invalid elevation detected: ", elevation)


func _is_valid_elevation(elevation: float) -> bool:
    return elevation > -1000 and elevation < 10000


func _reset_player_physics() -> void:
    if target_node is CharacterBody3D:
        target_node.velocity = Vector3.ZERO
    elif target_node.has_method("set_velocity"):
        target_node.set_velocity(Vector3.ZERO)


func _input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed:
        return

    match event.keycode:
        KEY_SPACE:
            _debug_terrain_info()
        KEY_P:
            _spawn_player_at_terrain_safe()
        KEY_L:
            _lod_manager.debug_lod_status(target_node)
        KEY_C:
            _collision_manager.debug_status()
        KEY_T:
            _debug_terrain_collision_status()


func _debug_terrain_info() -> void:
    print("=== TERRAIN DEBUG INFO ===")
    print("Current tile: ", current_tile_coords, " Zoom: ", _lod_manager.current_zoom)
    print("Collision zoom: ", _collision_manager.COLLISION_ZOOM_LEVEL)
    print("Player position: ", target_node.global_position)

    var elevation = _terrain_mesh_manager.get_terrain_elevation_at_position(target_node.global_position)
    var height_above_terrain = target_node.global_position.y - elevation
    print("Terrain elevation at player: ", elevation, "m")
    print("Player height above terrain: ", height_above_terrain, "m")
    print("LOD using height above terrain: ", height_above_terrain, "m")

    print("Collision ready: ", collision_ready)
    print("Waiting for collision: ", waiting_for_collision)


func _debug_terrain_collision_status() -> void:
    print("=== TERRAIN/COLLISION STATUS ===")
    print("Current visual tile: ", current_tile_coords, " Zoom: ", _lod_manager.current_zoom)
    print("Collision zoom level: ", _collision_manager.COLLISION_ZOOM_LEVEL)

    if _collision_manager._current_collision_body:
        var collision_shape_node = _collision_manager._current_collision_body.get_child(0) as CollisionShape3D
        if collision_shape_node:
            print("Collision Body Scale: ", collision_shape_node.scale)

    if target_node:
        var player_pos = target_node.global_position
        var visual_elevation = _terrain_mesh_manager.get_terrain_elevation_at_position(player_pos)
        print("Player elevation - Visual: ", visual_elevation, "m, Actual: ", player_pos.y, "m")


func _exit_tree() -> void:
    _tile_manager.cleanup()
    _collision_manager.cleanup()
