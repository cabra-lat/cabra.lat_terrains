extends Node3D
class_name DynamicTerrainLoader

@export_category("Player Tracking")
@export var target_node: Node3D
@export var update_interval: float = 1.0

@export_category("World Settings")
@export var start_latitude: float = -15.708
@export var start_longitude: float = -48.560
@export var world_scale: float = 1.0
@export var max_view_distance: float = 2000.0

# Managers
var tile_manager: TileManager
var collision_manager: CollisionManager
var lod_manager: LODManager
var terrain_mesh_manager: TerrainMeshManager

var current_tile_coords: Vector2i
var time_since_last_update: float = 0.0
var collision_ready: bool = false
var waiting_for_collision: bool = false

# Always use highest LOD for collision
const COLLISION_ZOOM_LEVEL: int = 15

func _ready():
    initialize_managers()
    call_deferred("update_terrain")

func initialize_managers():
    tile_manager = TileManager.new()
    tile_manager.setup(self)
    add_child(tile_manager)

    collision_manager = CollisionManager.new()
    collision_manager.setup(self)
    add_child(collision_manager)

    lod_manager = LODManager.new()
    lod_manager.setup(self)
    add_child(lod_manager)

    terrain_mesh_manager = TerrainMeshManager.new()
    terrain_mesh_manager.setup(self)
    add_child(terrain_mesh_manager)

func _physics_process(delta):
    time_since_last_update += delta

    collision_manager.process_collision_queue()

    # Auto-position player when collision becomes ready
    if waiting_for_collision and collision_ready:
        waiting_for_collision = false
        call_deferred("spawn_player_at_terrain_safe")

    if time_since_last_update >= update_interval:
        time_since_last_update = 0.0
        update_terrain()

func update_terrain():
    if not target_node:
        return

    var player_pos = target_node.global_position

    # Update LOD for visual mesh
    var new_zoom = lod_manager.calculate_dynamic_zoom(player_pos.y)
    var new_tile_coords = CoordinateConverter.world_to_tile_coords(player_pos, start_latitude, start_longitude, new_zoom)

    if new_tile_coords != current_tile_coords or new_zoom != lod_manager.current_zoom:
        current_tile_coords = new_tile_coords
        lod_manager.current_zoom = new_zoom

        # Load new tiles for visual mesh
        tile_manager.load_tile_and_neighbors(new_tile_coords, new_zoom)

        # Update terrain mesh
        terrain_mesh_manager.update_for_tile(new_tile_coords, new_zoom)

        # ALWAYS load collision at highest LOD, regardless of player altitude
        var collision_tile_coords = CoordinateConverter.world_to_tile_coords(player_pos, start_latitude, start_longitude, COLLISION_ZOOM_LEVEL)
        load_collision_tile(collision_tile_coords)

func load_collision_tile(tile_coords: Vector2i):
    # Load collision tile at highest LOD
    tile_manager.load_tile_and_neighbors(tile_coords, COLLISION_ZOOM_LEVEL)
    waiting_for_collision = true
    collision_ready = false

func _input(event):
    if event is InputEventKey and event.pressed:
        match event.keycode:
            KEY_SPACE:
                debug_terrain_info()
            KEY_P:
                spawn_player_at_terrain_safe()
            KEY_L:
                lod_manager.debug_lod_status(target_node)
            KEY_H:
                debug_height_comparison()  # New debug command

func spawn_player_at_terrain_safe():
    if not target_node:
        return

    # Get the terrain elevation at player's CURRENT XZ position
    var player_xz = Vector3(target_node.global_position.x, 0, target_node.global_position.z)
    var elevation = terrain_mesh_manager.get_terrain_elevation_at_position(player_xz)

    if elevation > -1000 and elevation < 10000:
        var new_position = Vector3(
            target_node.global_position.x,
            elevation + 1.8,  # Eye height
            target_node.global_position.z
        )

        print("Spawning player at: ", new_position, " (elevation: ", elevation, "m)")
        target_node.global_position = new_position

        reset_player_physics()
    else:
        print("Invalid elevation detected: ", elevation)

func reset_player_physics():
    if target_node and target_node is CharacterBody3D:
        target_node.velocity = Vector3.ZERO
    elif target_node and target_node.has_method("set_velocity"):
        target_node.set_velocity(Vector3.ZERO)

func debug_terrain_info():
    print("=== TERRAIN DEBUG INFO ===")
    print("Current tile: ", current_tile_coords, " Zoom: ", lod_manager.current_zoom)
    print("Collision zoom: ", COLLISION_ZOOM_LEVEL)
    print("Player position: ", target_node.global_position)

    var elevation = terrain_mesh_manager.get_terrain_elevation_at_position(target_node.global_position)
    var height_above_terrain = target_node.global_position.y - elevation
    print("Terrain elevation at player: ", elevation, "m")
    print("Player height above terrain: ", height_above_terrain, "m")

    lod_manager.debug_lod_status(target_node)

    print("Collision ready: ", collision_ready)
    print("Waiting for collision: ", waiting_for_collision)

func debug_height_comparison():
    print("=== HEIGHT COMPARISON DEBUG ===")

    var visual_texture = tile_manager.get_texture_for_tile(
        current_tile_coords,
        lod_manager.current_zoom,
        TileTextureType.TERRARIUM
    )

    var collision_texture = tile_manager.get_texture_for_tile(
        CoordinateConverter.world_to_tile_coords(target_node.global_position, start_latitude, start_longitude, COLLISION_ZOOM_LEVEL),
        COLLISION_ZOOM_LEVEL,
        TileTextureType.TERRARIUM
    )

    if visual_texture and collision_texture:
        var player_pos = target_node.global_position
        var visual_elevation = terrain_mesh_manager.get_terrain_elevation_at_position(player_pos)

        # Sample collision height directly
        var collision_elevation = sample_collision_height_at_position(collision_texture, player_pos, COLLISION_ZOOM_LEVEL)

        print("Visual elevation: ", visual_elevation, "m")
        print("Collision elevation: ", collision_elevation, "m")
        print("Height difference: ", visual_elevation - collision_elevation, "m")

func sample_collision_height_at_position(texture: Texture2D, world_pos: Vector3, zoom: int) -> float:
    var image = texture.get_image()
    var tile_size = CoordinateConverter.get_tile_size_meters(zoom)

    # Convert world position to UV coordinates
    var u = (world_pos.x + tile_size / 2) / tile_size
    var v = (world_pos.z + tile_size / 2) / tile_size

    u = clamp(u, 0.0, 1.0)
    v = clamp(v, 0.0, 1.0)

    # Use the same sampling as collision generation
    return collision_manager.sample_height_from_image_direct(image, u, v)

func _exit_tree():
    tile_manager.cleanup()
    collision_manager.cleanup()
