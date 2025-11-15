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
@export var min_zoom: int = 10
@export var max_zoom: int = 15
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
@export var shader: Shader = preload("../shaders/terrain_shader.gdshader")
@export var material: ShaderMaterial = preload("../resources/template_material.tres")

var current_tile_coords: Vector2i
var time_since_last_update: float = 0.0

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
    RenderingServer.set_debug_generate_wireframes(true)
    _initialize_managers()
    await get_tree().create_timer(3.0).timeout
    call_deferred("update_terrain")
    call_deferred("_spawn_player_at_terrain_safe")

func _initialize_managers() -> void:
    _collision_manager = CollisionManager.new()
    _collision_manager.setup(self)
    add_child(_collision_manager)

    _lod_manager = LODManager.new()
    _lod_manager.setup(self)
    add_child(_lod_manager)

    _terrain_mesh_manager = TerrainMeshManager.new()
    _terrain_mesh_manager.setup(self)
    add_child(_terrain_mesh_manager)

    _tile_manager = TileManager.new()
    _tile_manager.setup(self)
    _tile_manager.tile_loaded.connect(_terrain_mesh_manager.on_tile_loaded)
    _tile_manager.tile_loaded.connect(_collision_manager.on_tile_loaded)
    add_child(_tile_manager)

func _physics_process(delta: float) -> void:
    time_since_last_update += delta

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
    var origin = CoordinateConverter.lat_lon_to_world(start_latitude, start_longitude, new_zoom)
    var new_tile_coords = CoordinateConverter.world_to_tile(player_pos + origin, new_zoom)

    if new_tile_coords != current_tile_coords or new_zoom != _lod_manager.current_zoom:
        current_tile_coords = new_tile_coords
        _lod_manager.current_zoom = new_zoom

        _load_new_terrain(new_tile_coords, new_zoom)

func _load_new_terrain(tile_coords: Vector2i, zoom: int) -> void:
    _tile_manager.preload_tile(tile_coords, zoom)
    _terrain_mesh_manager.update_for_tile(tile_coords, zoom)
    current_tile_coords = tile_coords  # Add this

func _spawn_player_at_terrain_safe() -> void:
    if not target_node:
        return

    var player_xz = Vector3(target_node.global_position.x, 0, target_node.global_position.z)
    var elevation = _terrain_mesh_manager.get_terrain_elevation_at_position(player_xz)

    if not _is_valid_elevation(elevation):
        var new_position = Vector3(
            target_node.global_position.x,
            elevation + 1.8,  # Eye height
            target_node.global_position.z
        )

        print("Spawning player at terrain elevation: ", elevation, "m")
        target_node.global_position = new_position
        _reset_player_physics()
    else:
        print("Invalid elevation detected: ", elevation)


func _is_valid_elevation(elevation: float) -> bool:
    return elevation > -1000 and elevation < 10000

func _reset_player_physics() -> void:
    if target_node is CharacterBody3D:
        target_node.velocity = Vector3.ZERO
    elif target_node.has_method("set_velocity"):
        target_node.set_velocity(Vector3.ZERO)

func _exit_tree() -> void:
    _tile_manager.cleanup()
    _collision_manager.cleanup()
