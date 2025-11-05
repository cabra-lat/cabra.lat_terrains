@tool
class_name ChunkedTerrain
extends Node3D

@export_category("Terrain Settings")
@export var tiles_number: Vector2i = Vector2i(8,8)
@export var tile_size_km: Vector2 = Vector2(439.296, 439.296)
@export var chunks_per_tile: Vector2i = Vector2i(8, 8)
@export var subdivisions_per_chunk: int = 64
@export var max_height_meters: float = 2995.0
@onready var material: ShaderMaterial = ShaderMaterial.new()

# HEIGHTMAP CONFIGURATION
@export_category("Heightmap Configuration")
## Use [color=#ff0000]{0}[/color] for i [color=#ff0000](row)[/color]
## and [color=#00ff00]{1}[/color] for j ([color=#00ff00](column)[/color] [br]
## Examples: [br]
## - [color=#ffff00]res://heightmaps/tile_[color=#ff0000]{0}[/color]x[color=#00ff00]{1}[/color].png [/color][br]
## - [color=#ffff00]res://maps/region_[color=#ff0000]{0}[/color]_[color=#00ff00]{1}[/color].jpg[/color]
@export var heightmap_path_pattern: String = "res://assets/heightmaps/brazil_relief_tile_i{0}_j{1}.png":
    set(value):
        heightmap_path_pattern = value
        if Engine.is_editor_hint():
            # Re-preload textures when pattern changes
            call_deferred("preload_tile_textures")
            if enable_editor_preview:
                call_deferred("_update_editor_preview")

# SPAWN POINT CONFIGURATION
@export_category("Spawn Point Settings")
@export var spawn_tile_index: Vector2i = Vector2i(2, 2):
    set(value):
        spawn_tile_index = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")
@export var spawn_chunk_index: Vector2i = Vector2i(-1, -1):  # -1 means center of tile
    set(value):
        spawn_chunk_index = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")
@export var show_spawn_marker: bool = true:
    set(value):
        show_spawn_marker = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")

@export_category("Performance Settings")
@export var render_distance: float = 2000.0
@export var collision_distance: float = 1000.0
@export var update_interval: float = 0.1

@export_category("Player References")
@export var player_node_path: NodePath
@export var camera_node_path: NodePath

# EDITOR PREVIEW SETTINGS
@export_category("Editor Preview")
@export var enable_editor_preview: bool = false:
    set(value):
        enable_editor_preview = value
        if Engine.is_editor_hint():
            call_deferred("_update_editor_preview")
@export var preview_radius_chunks: int = 2:
    set(value):
        preview_radius_chunks = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")
@export var preview_show_collision: bool = false:
    set(value):
        preview_show_collision = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")
@export var preview_show_wireframe: bool = true:
    set(value):
        preview_show_wireframe = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")

# Editor preview state
var editor_preview_initialized: bool = false
var pending_preview_update: bool = false

# OPTIONAL: Auto-update preview based on editor camera position
var last_editor_camera_position: Vector3 = Vector3.ZERO
@export var preview_auto_follow_camera: bool = false:
    set(value):
        preview_auto_follow_camera = value
        if Engine.is_editor_hint() and enable_editor_preview:
            call_deferred("_update_editor_preview")

func _process(delta):
    if Engine.is_editor_hint() and enable_editor_preview and preview_auto_follow_camera:
        var editor_camera = _get_editor_camera()
        if editor_camera:
            var cam_pos = editor_camera.global_position
            # Only update if camera moved significantly
            if cam_pos.distance_to(last_editor_camera_position) > 100.0:
                last_editor_camera_position = cam_pos
                # Convert camera position to tile/chunk coordinates
                var tile_chunk_pos = _world_to_tile_chunk(cam_pos)
                call_deferred("_load_preview_chunks_around", tile_chunk_pos[0], tile_chunk_pos[1])

func _get_editor_camera() -> Camera3D:
    # Try to get the editor camera
    var viewport = get_viewport()
    if viewport:
        return viewport.get_camera_3d()
    return null

func _world_to_tile_chunk(world_pos: Vector3) -> Array:
    var local_pos = to_local(world_pos)
    var tile_size_m = tile_size_km * 1000.0

    var tile_i = int(local_pos.z / tile_size_m.y)
    var tile_j = int(local_pos.x / tile_size_m.x)

    var chunk_i = int((local_pos.z - tile_i * tile_size_m.y) / chunk_size_m.y)
    var chunk_j = int((local_pos.x - tile_j * tile_size_m.x) / chunk_size_m.x)

    return [Vector2i(tile_i, tile_j), Vector2i(chunk_j, chunk_i)]

# Tile and chunk management
var tiles = {}
var tile_textures = {}
var camera: Camera3D
var player_node: Node3D
var chunk_load_timer: Timer

# Debug
var debug_label: Label3D

# Editor preview chunks
var editor_preview_chunks = []
var spawn_marker: MeshInstance3D

# World origin management
var world_origin: Vector3 = Vector3.ZERO
var player_last_position: Vector3 = Vector3.ZERO
var origin_update_threshold: float = 500.0

# Spawn point management
var spawn_point_world_position: Vector3 = Vector3.ZERO

# Calculate chunk size in meters
var chunk_size_m: Vector2:
    get:
        return tile_size_km * 1000.0 / Vector2(chunks_per_tile)

# Add to ChunkedTerrain class
var collision_processing_timer: Timer

func _ready():
    if Engine.is_editor_hint():
        # Editor-specific setup
        preload_tile_textures()
        _create_spawn_marker()
        editor_preview_initialized = true

        # Create collision processing timer for editor
        collision_processing_timer = Timer.new()
        collision_processing_timer.wait_time = 0.1
        collision_processing_timer.one_shot = true
        collision_processing_timer.timeout.connect(_process_pending_collisions)
        add_child(collision_processing_timer)

        if enable_editor_preview:
            call_deferred("_update_editor_preview")
    else:
        # Game runtime setup
        preload_tile_textures()
        setup_terrain()
        setup_world_origin()
        setup_spawn_point()
        load_initial_chunks_around_spawn()
        start_chunk_management()
        setup_debug()

# NEW: Process pending collisions after a delay
func _process_pending_collisions():
    if not Engine.is_editor_hint() or not is_inside_tree():
        return

    for chunk in editor_preview_chunks:
        if is_instance_valid(chunk) and chunk.pending_collision:
            chunk._add_collision_internal(chunk.pending_collision_height)

# UPDATED: Update editor preview with collision processing
func _update_editor_preview():
    if not Engine.is_editor_hint():
        return

    if not is_inside_tree():
        pending_preview_update = true
        return

    if not editor_preview_initialized:
        return

    _clear_editor_preview()

    if not enable_editor_preview:
        return

    # Update spawn marker
    call_deferred("_create_spawn_marker")

    # Load preview chunks around spawn point
    call_deferred("_load_preview_chunks_around_spawn")

    # Process collisions after a short delay
    if collision_processing_timer:
        collision_processing_timer.start()

# NEW: Load preview chunks specifically around spawn
func _load_preview_chunks_around_spawn():
    if not Engine.is_editor_hint() or not is_inside_tree():
        return

    var center_tile = spawn_tile_index
    var center_chunk = spawn_chunk_index

    # If spawn chunk is -1 (tile center), use center of tile
    if center_chunk.x == -1 or center_chunk.y == -1:
        center_chunk = Vector2i(chunks_per_tile.x / 2, chunks_per_tile.y / 2)

    print("Loading editor preview around spawn - Tile: ", center_tile, " Chunk: ", center_chunk)

    # Load the center tile first
    var center_tile_texture = tile_textures.get(Vector2(center_tile.x, center_tile.y))
    if center_tile_texture:
        # Load chunks in center tile
        for chunk_i in range(max(0, center_chunk.x - preview_radius_chunks), min(chunks_per_tile.x, center_chunk.x + preview_radius_chunks + 1)):
            for chunk_j in range(max(0, center_chunk.y - preview_radius_chunks), min(chunks_per_tile.y, center_chunk.y + preview_radius_chunks + 1)):
                _create_editor_chunk_safe(center_tile, Vector2(chunk_j, chunk_i), center_tile_texture)

    # Load adjacent tiles if they exist
    for i in range(-1, 2):
        for j in range(-1, 2):
            if i == 0 and j == 0:
                continue  # Skip center tile (already loaded)

            var adj_tile = Vector2i(center_tile.x + i, center_tile.y + j)
            if adj_tile.x >= 0 and adj_tile.x < tiles_number.x and adj_tile.y >= 0 and adj_tile.y < tiles_number.y:
                var adj_texture = tile_textures.get(Vector2(adj_tile.x, adj_tile.y))
                if adj_texture:
                    # For adjacent tiles, load chunks near the edge closest to center
                    var start_i = 0
                    var end_i = chunks_per_tile.x
                    var start_j = 0
                    var end_j = chunks_per_tile.y

                    if i == -1:  # Left tile - load right edge
                        start_i = chunks_per_tile.x - preview_radius_chunks
                    elif i == 1:  # Right tile - load left edge
                        end_i = preview_radius_chunks

                    if j == -1:  # Top tile - load bottom edge
                        start_j = chunks_per_tile.y - preview_radius_chunks
                    elif j == 1:  # Bottom tile - load top edge
                        end_j = preview_radius_chunks

                    for chunk_i in range(start_i, end_i):
                        for chunk_j in range(start_j, end_j):
                            _create_editor_chunk_safe(adj_tile, Vector2(chunk_j, chunk_i), adj_texture)

# UPDATED: Safe editor chunk creation
func _create_editor_chunk_safe(tile_pos: Vector2, chunk_pos: Vector2, texture: Texture2D):
    if not Engine.is_editor_hint() or not is_inside_tree():
        return

    var tile_size_m = tile_size_km * 1000.0

    # Calculate LOCAL position for this chunk
    var local_position = Vector3(
        tile_pos.y * tile_size_m.x + chunk_pos.x * chunk_size_m.x,
        0,
        tile_pos.x * tile_size_m.y + chunk_pos.y * chunk_size_m.y
    )

    var chunk = TerrainChunk.new()

    # Use the local setup method
    chunk.setup_tile_local(
        Vector3(chunk_size_m.x, 0, chunk_size_m.y),
        local_position,
        texture,
        material,
        max_height_meters,
        render_distance,
        subdivisions_per_chunk,
        tile_pos,
        chunk_pos,
        Vector2(chunks_per_tile)
    )

    # Apply editor preview settings
    if preview_show_wireframe:
        chunk.set_wireframe_mode(true)

    add_child(chunk)

    # Set owner for proper editing
    if Engine.is_editor_hint() and is_inside_tree():
        var scene_root = get_tree().get_edited_scene_root()
        if scene_root:
            chunk.set_owner(scene_root)

    editor_preview_chunks.append(chunk)

    # Add collision safely - it will handle tree state internally
    if preview_show_collision:
        chunk.add_collision(max_height_meters)

# UPDATED: Clear preview with safety checks
func _clear_editor_preview():
    for chunk in editor_preview_chunks:
        if is_instance_valid(chunk):
            if chunk.is_inside_tree():
                remove_child(chunk)
            chunk.queue_free()
    editor_preview_chunks.clear()

    # Clean up spawn marker if preview is disabled
    if not enable_editor_preview and spawn_marker and is_instance_valid(spawn_marker):
        if spawn_marker.is_inside_tree():
            remove_child(spawn_marker)
        spawn_marker.queue_free()
        spawn_marker = null

# NEW: Handle when node enters tree
func _enter_tree():
    if Engine.is_editor_hint():
        if pending_preview_update:
            call_deferred("_update_editor_preview")
            pending_preview_update = false

func _create_spawn_marker():
    # Remove existing spawn marker safely
    if spawn_marker and is_instance_valid(spawn_marker):
        if spawn_marker.is_inside_tree():
            remove_child(spawn_marker)
        spawn_marker.queue_free()
        spawn_marker = null

    if not show_spawn_marker or not is_inside_tree():
        return

    # Calculate spawn position in LOCAL coordinates
    var spawn_pos_local = calculate_spawn_position_local()
    print("Creating spawn marker at local position: ", spawn_pos_local)

    # Create marker with proper deferred setup
    var marker = MeshInstance3D.new()
    var sphere_mesh = SphereMesh.new()
    sphere_mesh.radius = 10.0
    sphere_mesh.height = 20.0

    var marker_material = StandardMaterial3D.new()
    marker_material.albedo_color = Color(1, 0, 0, 0.8)
    marker_material.emission_enabled = true
    marker_material.emission = Color(1, 0, 0, 0.3)
    sphere_mesh.material = marker_material

    marker.mesh = sphere_mesh
    marker.position = spawn_pos_local + Vector3(0, 15, 0)

    # Add label
    var label = Label3D.new()
    label.text = "Spawn Point\nTile: %d,%d\nChunk: %s" % [
        spawn_tile_index.x, spawn_tile_index.y,
        "%d,%d" % [spawn_chunk_index.x, spawn_chunk_index.y] if spawn_chunk_index.x != -1 else "Tile Center"
    ]
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    label.position = Vector3(0, 25, 0)
    label.modulate = Color(1, 1, 1, 1)
    marker.add_child(label)

    add_child(marker)
    spawn_marker = marker

    # Set owner for editor - only if we have a valid scene root
    if Engine.is_editor_hint() and is_inside_tree():
        var scene_root = get_tree().get_edited_scene_root()
        if scene_root:
            marker.set_owner(scene_root)
            label.set_owner(scene_root)

# NEW: Calculate spawn position in LOCAL coordinates
func calculate_spawn_position_local() -> Vector3:
    var tile_size_m = tile_size_km * 1000.0

    if spawn_chunk_index.x == -1 or spawn_chunk_index.y == -1:
        # Spawn at tile center - LOCAL position
        return Vector3(
            (spawn_tile_index.y + 0.5) * tile_size_m.x,
            0,
            (spawn_tile_index.x + 0.5) * tile_size_m.y
        )
    else:
        # Spawn at specific chunk center - LOCAL position
        return Vector3(
            spawn_tile_index.y * tile_size_m.x + (spawn_chunk_index.x + 0.5) * chunk_size_m.x,
            0,
            spawn_tile_index.x * tile_size_m.y + (spawn_chunk_index.y + 0.5) * chunk_size_m.y
        )

# UPDATED: Calculate world spawn position (for reference)
func calculate_spawn_position() -> Vector3:
    var local_pos = calculate_spawn_position_local()
    return global_position + local_pos

# UPDATED: Setup spawn point system
func setup_spawn_point():
    spawn_point_world_position = calculate_spawn_position()
    print("Spawn point set at world position: ", spawn_point_world_position)
    print("Spawn point local position: ", calculate_spawn_position_local())
    print("Spawn tile: ", spawn_tile_index, " Chunk: ", spawn_chunk_index)

    # Create spawn marker in game mode too
    if not Engine.is_editor_hint() and show_spawn_marker:
        _create_spawn_marker()

# UPDATED: Setup world origin to center on spawn point
func setup_world_origin():
    # Set world origin to spawn point (in world coordinates)
    world_origin = spawn_point_world_position
    print("World origin set to spawn point: ", world_origin)

    if player_node:
        player_last_position = player_node.global_position

func _create_editor_chunk(tile_pos: Vector2, chunk_pos: Vector2, texture: Texture2D):
    if not Engine.is_editor_hint() or not is_inside_tree():
        return

    var tile_size_m = tile_size_km * 1000.0

    # Calculate LOCAL position for this chunk
    var local_position = Vector3(
        tile_pos.y * tile_size_m.x + chunk_pos.x * chunk_size_m.x,
        0,
        tile_pos.x * tile_size_m.y + chunk_pos.y * chunk_size_m.y
    )

    var chunk = TerrainChunk.new()
    chunk.setup_tile(
        Vector3(chunk_size_m.x, 0, chunk_size_m.y),
        local_position,
        texture,
        material,
        max_height_meters,
        render_distance,
        subdivisions_per_chunk,
        tile_pos,
        chunk_pos,
        Vector2(chunks_per_tile)
    )

    # Apply editor preview settings
    if preview_show_wireframe:
        chunk.set_wireframe_mode(true)

    add_child(chunk)

    # Set owner for proper editing
    if Engine.is_editor_hint() and is_inside_tree():
        var scene_root = get_tree().get_edited_scene_root()
        if scene_root:
            chunk.set_owner(scene_root)

    editor_preview_chunks.append(chunk)

    # Add collision after adding to scene
    if preview_show_collision:
        chunk.call_deferred("add_collision", max_height_meters)

# UPDATED: Chunk positioning uses local coordinates
func calculate_chunk_world_position(tile_pos: Vector2, chunk_pos: Vector2) -> Vector3:
    var tile_size_m = tile_size_km * 1000.0
    var local_position = Vector3(
        tile_pos.y * tile_size_m.x + chunk_pos.x * chunk_size_m.x + chunk_size_m.x / 2,
        0,
        tile_pos.x * tile_size_m.y + chunk_pos.y * chunk_size_m.y + chunk_size_m.y / 2
    )
    # Convert local to world position
    return global_position + local_position

# UPDATED: Chunk loading uses local coordinates
func load_chunk(tile_pos: Vector2, chunk_pos: Vector2, with_collision: bool):
    if not tiles.has(tile_pos):
        tiles[tile_pos] = {}

    if tiles[tile_pos].has(chunk_pos):
        var chunk = tiles[tile_pos][chunk_pos]
        if with_collision and chunk.chunk_state != "WITH_COLLISION":
            add_collision_to_chunk(chunk)
        elif not with_collision and chunk.chunk_state == "WITH_COLLISION":
            remove_collision_from_chunk(chunk)
        return

    var tile_texture = tile_textures.get(tile_pos)
    if not tile_texture:
        print("No texture found for tile: ", tile_pos)
        return

    var tile_size_m = tile_size_km * 1000.0
    # Use LOCAL position
    var local_position = Vector3(
        tile_pos.y * tile_size_m.x + chunk_pos.x * chunk_size_m.x,
        0,
        tile_pos.x * tile_size_m.y + chunk_pos.y * chunk_size_m.y
    )

    var chunk = TerrainChunk.new()
    chunk.setup_tile(
        Vector3(chunk_size_m.x, 0, chunk_size_m.y),
        local_position,  # Local position
        tile_texture,
        material,
        max_height_meters,
        render_distance,
        subdivisions_per_chunk,
        tile_pos,
        chunk_pos,
        Vector2(chunks_per_tile)
    )

    add_child(chunk)
    tiles[tile_pos][chunk_pos] = chunk

    if with_collision:
        add_collision_to_chunk(chunk)
    else:
        chunk.set_visual_only()

    print("Loaded chunk %s at local position %s with collision: %s" % [chunk_pos, local_position, with_collision])

# UPDATED: Debug info with better positioning info
func update_debug_info(world_position: Vector3, tile_i: int, tile_j: int):
    if debug_label:
        var visual_count = 0
        var collision_count = 0
        var total_chunks = get_chunk_count()
        var total_tiles = tiles.size()

        for tile in tiles.values():
            for chunk in tile.values():
                if chunk.chunk_state == "WITH_COLLISION":
                    collision_count += 1
                else:
                    visual_count += 1

        var spawn_local = calculate_spawn_position_local()
        debug_label.text = "Tiles: %d, Chunks: %d (V: %d, C: %d)\nWorld Pos: %s\nSpawn Local: %s\nSpawn: Tile %s, Chunk %s\nFPS: %d" % [
            total_tiles, total_chunks, visual_count, collision_count,
            "%.1f, %.1f, %.1f" % [world_position.x, world_position.y, world_position.z],
            "%.1f, %.1f, %.1f" % [spawn_local.x, spawn_local.y, spawn_local.z],
            "%d,%d" % [spawn_tile_index.x, spawn_tile_index.y],
            "%d,%d" % [spawn_chunk_index.x, spawn_chunk_index.y] if spawn_chunk_index.x != -1 else "Center",
            Engine.get_frames_per_second()
        ]

# NEW: Load initial chunks around spawn point
func load_initial_chunks_around_spawn():
    if Engine.is_editor_hint():
        return

    print("Loading initial chunks around spawn point...")

    # Calculate which tiles and chunks should be loaded around spawn
    var tile_size_m = tile_size_km * 1000.0
    var tiles_x = ceil(render_distance / tile_size_m.x) + 1
    var tiles_z = ceil(render_distance / tile_size_m.y) + 1

    for tile_i in range(spawn_tile_index.x - tiles_z, spawn_tile_index.x + tiles_z + 1):
        for tile_j in range(spawn_tile_index.y - tiles_x, spawn_tile_index.y + tiles_x + 1):
            if tile_i >= 0 and tile_i < tiles_number.x and tile_j >= 0 and tile_j < tiles_number.y:
                var tile_pos = Vector2(tile_i, tile_j)

                # Load all chunks in this tile that are within render distance
                for chunk_i in range(0, chunks_per_tile.x):
                    for chunk_j in range(0, chunks_per_tile.y):
                        var chunk_pos = Vector2(chunk_j, chunk_i)
                        var chunk_world_pos = calculate_chunk_world_position(tile_pos, chunk_pos)
                        var distance = spawn_point_world_position.distance_to(chunk_world_pos)

                        if distance <= render_distance:
                            var with_collision = distance <= collision_distance
                            load_chunk(tile_pos, chunk_pos, with_collision)

# UPDATED: World origin update now considers spawn point as reference
func update_world_origin(new_center: Vector3):
    var shift = new_center - world_origin

    if shift.length() > origin_update_threshold:
        print("Updating world origin. Shift: ", shift)
        print("Old origin: ", world_origin, " New center: ", new_center)

        # Shift all existing chunks
        for tile_pos in tiles:
            for chunk_pos in tiles[tile_pos]:
                var chunk = tiles[tile_pos][chunk_pos]
                chunk.global_position -= shift

        # Update our world origin tracking
        world_origin = new_center

        # Update player's last position
        if player_node:
            player_last_position = player_node.global_position

# UPDATED: Get terrain center now considers spawn point
func get_terrain_center() -> Vector3:
    return spawn_point_world_position

# NEW: Load chunks around a specific point for preview
func _load_preview_chunks_around(center_tile: Vector2i, center_chunk: Vector2i):
    if not Engine.is_editor_hint():
        return

    var tile_texture = tile_textures.get(Vector2(center_tile.x, center_tile.y))
    if not tile_texture:
        push_warning("No texture found for center tile: " + str(center_tile))
        return

    # Preview chunks in the center tile
    for chunk_i in range(max(0, center_chunk.x - preview_radius_chunks), min(chunks_per_tile.x, center_chunk.x + preview_radius_chunks + 1)):
        for chunk_j in range(max(0, center_chunk.y - preview_radius_chunks), min(chunks_per_tile.y, center_chunk.y + preview_radius_chunks + 1)):
            _create_editor_chunk(center_tile, Vector2(chunk_j, chunk_i), tile_texture)

    # Also preview adjacent tiles if near edges
    if center_chunk.x - preview_radius_chunks < 0:
        # Need tiles to the left
        var left_tile = Vector2i(center_tile.x, center_tile.y - 1)
        if left_tile.y >= 0:
            var left_texture = tile_textures.get(Vector2(left_tile.x, left_tile.y))
            if left_texture:
                for chunk_i in range(chunks_per_tile.x - preview_radius_chunks, chunks_per_tile.x):
                    for chunk_j in range(max(0, center_chunk.y - preview_radius_chunks), min(chunks_per_tile.y, center_chunk.y + preview_radius_chunks + 1)):
                        _create_editor_chunk(left_tile, Vector2(chunk_j, chunk_i), left_texture)

    if center_chunk.x + preview_radius_chunks >= chunks_per_tile.x:
        # Need tiles to the right
        var right_tile = Vector2i(center_tile.x, center_tile.y + 1)
        if right_tile.y < tiles_number.y:
            var right_texture = tile_textures.get(Vector2(right_tile.x, right_tile.y))
            if right_texture:
                for chunk_i in range(0, preview_radius_chunks):
                    for chunk_j in range(max(0, center_chunk.y - preview_radius_chunks), min(chunks_per_tile.y, center_chunk.y + preview_radius_chunks + 1)):
                        _create_editor_chunk(right_tile, Vector2(chunk_j, chunk_i), right_texture)

    if center_chunk.y - preview_radius_chunks < 0:
        # Need tiles above
        var top_tile = Vector2i(center_tile.x - 1, center_tile.y)
        if top_tile.x >= 0:
            var top_texture = tile_textures.get(Vector2(top_tile.x, top_tile.y))
            if top_texture:
                for chunk_i in range(max(0, center_chunk.x - preview_radius_chunks), min(chunks_per_tile.x, center_chunk.x + preview_radius_chunks + 1)):
                    for chunk_j in range(chunks_per_tile.y - preview_radius_chunks, chunks_per_tile.y):
                        _create_editor_chunk(top_tile, Vector2(chunk_j, chunk_i), top_texture)

    if center_chunk.y + preview_radius_chunks >= chunks_per_tile.y:
        # Need tiles below
        var bottom_tile = Vector2i(center_tile.x + 1, center_tile.y)
        if bottom_tile.x < tiles_number.x:
            var bottom_texture = tile_textures.get(Vector2(bottom_tile.x, bottom_tile.y))
            if bottom_texture:
                for chunk_i in range(max(0, center_chunk.x - preview_radius_chunks), min(chunks_per_tile.x, center_chunk.x + preview_radius_chunks + 1)):
                    for chunk_j in range(0, preview_radius_chunks):
                        _create_editor_chunk(bottom_tile, Vector2(chunk_j, chunk_i), bottom_texture)

# UPDATED: Property handling with tree checks
func _set(property: StringName, value) -> bool:
    if Engine.is_editor_hint():
        if property.begins_with("preview_") or property.begins_with("spawn_") or property == "heightmap_path_pattern":
            if is_inside_tree() and editor_preview_initialized:
                call_deferred("_update_editor_preview")
            else:
                pending_preview_update = true
            return true
    return false

# UPDATED: Exit tree cleanup
func _exit_tree():
    if Engine.is_editor_hint():
        _clear_editor_preview()

func preload_tile_textures():
    print("Preloading tile textures using pattern: ", heightmap_path_pattern)

    tile_textures.clear()

    var loaded_count = 0
    var missing_count = 0
    var failed_count = 0

    for i in range(tiles_number.x):
        for j in range(tiles_number.y):
            var texture_path = heightmap_path_pattern.format([i, j])
            var tile_key = Vector2(i, j)

            if ResourceLoader.exists(texture_path):
                # Method 1: Try loading as texture first
                var resource = ResourceLoader.load(texture_path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE)

                if resource and resource is Texture2D:
                    var texture: Texture2D = resource
                    var image = texture.get_image()

                    if image:
                        # Create a guaranteed-readable texture
                        if image.is_compressed():
                            if image.decompress() != OK:
                                print("Failed to decompress image for tile ", tile_key)
                                failed_count += 1
                                continue

                        # Create new texture from decompressed image
                        var image_texture = ImageTexture.create_from_image(image)
                        if image_texture:
                            tile_textures[tile_key] = image_texture
                            loaded_count += 1
                            print("Loaded tile: i=%d, j=%d -> %s (%dx%d)" % [
                                i, j, texture_path, image.get_width(), image.get_height()
                            ])
                        else:
                            failed_count += 1
                            print("Failed to create ImageTexture for tile ", tile_key)
                    else:
                        # Use original texture if we can't get image data
                        tile_textures[tile_key] = texture
                        loaded_count += 1
                        print("Loaded tile (no image access): i=%d, j=%d -> %s" % [i, j, texture_path])
                else:
                    # Method 2: Try loading as Image directly as fallback
                    var image = Image.new()
                    var error = image.load(texture_path)
                    if error == OK:
                        if image.is_compressed():
                            image.decompress()
                        var image_texture = ImageTexture.create_from_image(image)
                        tile_textures[tile_key] = image_texture
                        loaded_count += 1
                        print("Loaded tile (fallback): i=%d, j=%d -> %s (%dx%d)" % [
                            i, j, texture_path, image.get_width(), image.get_height()
                        ])
                    else:
                        failed_count += 1
                        print("Failed to load texture: ", texture_path, " Error: ", error)
            else:
                missing_count += 1
                print("Missing tile: i=%d, j=%d -> %s" % [i, j, texture_path])

    print("Preloaded %d tiles, %d missing, %d failed" % [loaded_count, missing_count, failed_count])

    if Engine.is_editor_hint() and enable_editor_preview:
        call_deferred("_update_editor_preview")

func setup_terrain():
    if player_node_path:
        player_node = get_node(player_node_path)
    else:
        player_node = get_tree().get_first_node_in_group("player")

    if camera_node_path:
        camera = get_node(camera_node_path)
    else:
        camera = get_viewport().get_camera_3d()

    chunk_load_timer = Timer.new()
    chunk_load_timer.wait_time = update_interval
    chunk_load_timer.timeout.connect(update_chunks)
    add_child(chunk_load_timer)

func start_chunk_management():
    update_chunks()
    chunk_load_timer.start()
    print("Chunk management started")
    print("Spawn point: Tile ", spawn_tile_index, " Chunk ", spawn_chunk_index)
    print("Total tiles available: ", tiles_number.x * tiles_number.y)
    print("Chunks per tile: ", chunks_per_tile)
    print("Render distance: ", render_distance, " meters")

func debug_chunk_states():
    print("=== CHUNK STATES ===")
    print("Total tiles loaded: ", tiles.size())
    for tile_pos in tiles:
        print("Tile ", tile_pos, " has ", tiles[tile_pos].size(), " chunks")
        for chunk_pos in tiles[tile_pos]:
            var chunk = tiles[tile_pos][chunk_pos]
            print("  Chunk ", chunk_pos, " - State: ", chunk.chunk_state)
    print("===================")

func add_collision_to_chunk(chunk: TerrainChunk):
    if chunk.has_collision:
        return

    chunk.add_collision(max_height_meters)

func remove_collision_from_chunk(chunk: TerrainChunk):
    if not chunk.has_collision:
        return

    chunk.remove_collision()

func remove_chunk(tile_pos: Vector2, chunk_pos: Vector2):
    if tiles.has(tile_pos) and tiles[tile_pos].has(chunk_pos):
        var chunk = tiles[tile_pos][chunk_pos]
        remove_child(chunk)
        chunk.queue_free()
        tiles[tile_pos].erase(chunk_pos)
        print("Removed chunk: ", chunk_pos, " from tile: ", tile_pos)

func get_chunk_count() -> int:
    var count = 0
    for tile in tiles.values():
        count += tile.size()
    return count

func setup_debug():
    debug_label = Label3D.new()
    debug_label.text = "Terrain System Ready"
    debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
    debug_label.position = Vector3(0, 50, 0)
    add_child(debug_label)

func update_chunks():
    if Engine.is_editor_hint():
        return

    debug_chunk_states()

    var current_camera = get_viewport().get_camera_3d()
    var reference_position

    if current_camera:
        reference_position = current_camera.global_position
    elif player_node:
        reference_position = player_node.global_position
    else:
        reference_position = Vector3.ZERO

    update_world_origin(reference_position)

    var tile_size_m = tile_size_km * 1000.0
    var local_position = reference_position - world_origin

    var current_tile_i = int(local_position.z / tile_size_m.y)
    var current_tile_j = int(local_position.x / tile_size_m.x)

    var tiles_x = ceil(render_distance / tile_size_m.x) + 2
    var tiles_z = ceil(render_distance / tile_size_m.y) + 2

    var chunks_to_keep = {}
    var collision_chunks_to_keep = {}

    for tile_i in range(current_tile_i - tiles_z, current_tile_i + tiles_z + 1):
        for tile_j in range(current_tile_j - tiles_x, current_tile_j + tiles_x + 1):
            if tile_i >= 0 and tile_i < tiles_number.x and tile_j >= 0 and tile_j < tiles_number.y:
                var tile_pos = Vector2(tile_i, tile_j)

                for chunk_i in range(0, chunks_per_tile.x):
                    for chunk_j in range(0, chunks_per_tile.y):
                        var chunk_key = Vector2(chunk_j, chunk_i)
                        var chunk_world_pos = calculate_chunk_world_position(tile_pos, chunk_key)

                        var distance = reference_position.distance_to(chunk_world_pos)

                        if distance <= render_distance:
                            var unique_key = str(tile_pos) + "_" + str(chunk_key)
                            chunks_to_keep[unique_key] = {"tile_pos": tile_pos, "chunk_pos": chunk_key}

                            if distance <= collision_distance:
                                collision_chunks_to_keep[unique_key] = true
                                load_chunk(tile_pos, chunk_key, true)
                            else:
                                load_chunk(tile_pos, chunk_key, false)

    var chunks_to_remove = []
    for tile_pos in tiles.keys():
        for chunk_pos in tiles[tile_pos].keys():
            var unique_key = str(tile_pos) + "_" + str(chunk_pos)
            if not chunks_to_keep.has(unique_key):
                chunks_to_remove.append({"tile_pos": tile_pos, "chunk_pos": chunk_pos})

    for chunk_info in chunks_to_remove:
        remove_chunk(chunk_info.tile_pos, chunk_info.chunk_pos)

    for unique_key in chunks_to_keep:
        var chunk_info = chunks_to_keep[unique_key]
        var tile_pos = chunk_info.tile_pos
        var chunk_pos = chunk_info.chunk_pos

        if tiles.has(tile_pos) and tiles[tile_pos].has(chunk_pos):
            var chunk = tiles[tile_pos][chunk_pos]
            if collision_chunks_to_keep.has(unique_key):
                if chunk.chunk_state != "WITH_COLLISION":
                    add_collision_to_chunk(chunk)
            else:
                if chunk.chunk_state == "WITH_COLLISION":
                    remove_collision_from_chunk(chunk)

    var tiles_to_remove = []
    for tile_pos in tiles.keys():
        if tiles[tile_pos].is_empty():
            tiles_to_remove.append(tile_pos)

    for tile_pos in tiles_to_remove:
        tiles.erase(tile_pos)

    update_debug_info(reference_position, current_tile_i, current_tile_j)
