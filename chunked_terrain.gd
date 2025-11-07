extends Node3D
class_name DynamicTerrainLoader2

@export_category("Player Tracking")
@export var target_node: Node3D
@export var update_interval: float = 1.0

@export_category("World Settings")
@export var start_latitude: float = -15.708  # Brasília coordinates
@export var start_longitude: float = -48.560
@export var world_scale: float = 1.0  # 1 meter per world unit for true 1:1 scale
@export var max_view_distance: float = 2000.0  # Meters

@export_category("LOD Settings")
@export var min_zoom: int = 15  # Highest detail (ground level)
@export var max_zoom: int = 10  # Lowest detail (high altitude)
@export var lod_max_height: float = 8000.0  # Everest! Height where we switch to lowest LOD
@export var lod_min_height: float = 50.0 # 50 m
# Add this constant for Earth measurements
const EARTH_CIRCUMFERENCE: float = 40075000.0  # Earth circumference in meters

@export_category("Performance")
@export var max_concurrent_downloads: int = 2
@export var cache_size: int = 25


@export_category("Collision Settings")
@export var enable_collision: bool = true
@export var collision_resolution: int = 256  # Match the texture resolution
@export var collision_lod_threshold: float = 500.0  # Only generate collision when below this altitude@export_category("Collision Settings")

@export_category("Advanced Collision Settings")
@export var max_concurrent_collision_generations: int = 1
@export var collision_generation_timeout: float = 0.5  # Seconds to wait before generating collision
@export var use_collision_threading: bool = false

@export_category("Texture Types")
@export var download_heightmaps: bool = true
@export var download_normal_maps: bool = true
@export var use_normal_maps: bool = true

# Texture type constants
enum TEXTURE_TYPE { TERRARIUM, NORMAL }
const TEXTURE_TYPE_PATHS = {
    TEXTURE_TYPE.TERRARIUM: "terrarium",
    TEXTURE_TYPE.NORMAL: "normal"
}
const TEXTURE_TYPE_URLS = {
    TEXTURE_TYPE.TERRARIUM: "https://elevation-tiles-prod.s3.amazonaws.com/terrarium/{z}/{x}/{y}.png",
    TEXTURE_TYPE.NORMAL: "https://elevation-tiles-prod.s3.amazonaws.com/normal/{z}/{x}/{y}.png"
}

# Track loaded textures for each tile
var loaded_textures: Dictionary = {}

var collision_generation_queue: Array = []
var active_collision_generations: int = 0
var collision_mutex: Mutex = Mutex.new()
var collision_thread: Thread

# Collision tracking
var current_collision_body: StaticBody3D = null
var collision_shapes: Dictionary = {}
var last_collision_update: int = 0

# Internal state
var current_tile_coords: Vector2i
var current_zoom: int = min_zoom
var download_queue: Array = []
var active_downloads: int = 0
var tile_cache: Array = []

# Threading
var download_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var should_exit: bool = false

# HTTP requests (must be created on main thread)
var http_requests: Array = []

# Mesh
var terrain_mesh_instance: MeshInstance3D
var shader_material: ShaderMaterial

var last_zoom_change_time: float = 0.0
var zoom_change_cooldown: float = 2.0  # Minimum seconds between zoom changes
var collision_ready: bool = false
var waiting_for_collision: bool = false

func update_shader_with_tile(tile_coords: Vector2i, zoom: int):
    var tile_key = get_tile_key(tile_coords, zoom)
    print("Updating shader with tile: ", tile_coords, " zoom: ", zoom)

    if loaded_textures.has(tile_key):
        var tile_data = loaded_textures[tile_key]

        # Set heightmap texture
        if tile_data.has("terrarium"):
            var height_texture = tile_data["terrarium"]
            shader_material.set_shader_parameter("heightmap_texture", height_texture)

            # Update mesh with height data for debugging
            update_mesh_for_zoom(zoom, height_texture)

        # Update mesh for current zoom
        update_mesh_for_zoom(zoom)

        # Generate collision if enabled and we're below threshold
        if enable_collision and target_node and target_node.global_position.y < collision_lod_threshold:
            if tile_data.has("terrarium"):
                # Queue collision generation
                queue_collision_generation(tile_coords, zoom, tile_data["terrarium"])
                print("Queued collision generation for tile: ", tile_coords)

        print("Updated terrain to tile: ", tile_coords, " at zoom ", zoom)

        # Debug the current state
        call_deferred("debug_terrain_elevation")
    else:
        print("No textures loaded for tile key: ", tile_key)

func load_tile_and_neighbors(center_tile: Vector2i):
    # Calculate how many neighbors to load based on view distance and zoom
    var num_neighbors = calculate_neighbor_count()

    for x in range(-num_neighbors, num_neighbors + 1):
        for y in range(-num_neighbors, num_neighbors + 1):
            var tile_coords = Vector2i(center_tile.x + x, center_tile.y + y)
            queue_tile_downloads(tile_coords)

func queue_tile_downloads(tile_coords: Vector2i):
    # Queue both heightmap and normal map downloads if needed
    if download_heightmaps:
        queue_tile_download(tile_coords, TEXTURE_TYPE.TERRARIUM)

    if download_normal_maps:
        queue_tile_download(tile_coords, TEXTURE_TYPE.NORMAL)

func queue_tile_download(tile_coords: Vector2i, texture_type: int):
    mutex.lock()

    var tile_key = get_tile_key(tile_coords, current_zoom)
    var texture_type_str = TEXTURE_TYPE_PATHS[texture_type]

    # FIXED: Check if already loaded using the correct structure
    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has(texture_type_str):
        mutex.unlock()
        return

    # Check if already in queue
    if is_tile_in_queue(tile_coords, current_zoom, texture_type):
        mutex.unlock()
        return

    # FIXED: Also check disk cache before queuing download
    var cached_texture = load_tile_from_cache(tile_coords, current_zoom, texture_type)
    if cached_texture:
        print("Cache HIT for ", texture_type_str, " tile: ", tile_coords, " at zoom ", current_zoom)
        # Initialize tile entry if needed
        if not loaded_textures.has(tile_key):
            loaded_textures[tile_key] = {}

        # Store the texture
        loaded_textures[tile_key][texture_type_str] = cached_texture
        update_tile_cache(tile_key, loaded_textures[tile_key])

        # If this is the current tile, update shader
        if tile_coords == current_tile_coords and current_zoom == current_zoom:
            call_deferred("update_shader_with_tile", tile_coords, current_zoom)

        mutex.unlock()
        return

    print("Cache MISS for ", texture_type_str, " tile: ", tile_coords, " - queuing download")
    download_queue.append({
        "coords": tile_coords,
        "zoom": current_zoom,
        "type": texture_type
    })
    mutex.unlock()
    semaphore.post()  # Wake up download thread

func is_tile_in_queue(coords: Vector2i, zoom: int, texture_type: int) -> bool:
    for tile in download_queue:
        if tile["coords"] == coords and tile["zoom"] == zoom and tile["type"] == texture_type:
            return true
    return false

func _download_worker():
    while not should_exit:
        semaphore.wait()  # Wait for work

        if should_exit:
            break

        mutex.lock()
        if download_queue.size() == 0:
            mutex.unlock()
            continue

        var tile_data = download_queue.pop_front()
        var tile_coords = tile_data["coords"]
        var zoom = tile_data["zoom"]
        var texture_type = tile_data["type"]
        mutex.unlock()

        # FIXED: Check cache first
        var tile_key = get_tile_key(tile_coords, zoom)
        var texture_type_str = TEXTURE_TYPE_PATHS[texture_type]

        # Skip if already loaded (might have been loaded by another thread)
        mutex.lock()
        var already_loaded = loaded_textures.has(tile_key) and loaded_textures[tile_key].has(texture_type_str)
        mutex.unlock()

        if already_loaded:
            print("Tile already loaded, skipping: ", tile_coords, " type: ", texture_type_str)
            continue

        # Download the tile
        var image_texture = download_tile_texture(tile_coords, zoom, texture_type)

        if image_texture:
            mutex.lock()
            # Initialize tile entry if needed
            if not loaded_textures.has(tile_key):
                loaded_textures[tile_key] = {}

            # Store the texture
            loaded_textures[tile_key][texture_type_str] = image_texture

            # Update cache (LRU)
            update_tile_cache(tile_key, loaded_textures[tile_key])

            # If this is the current tile at current zoom, update the shader
            if tile_coords == current_tile_coords and zoom == current_zoom:
                call_deferred("update_shader_with_tile", tile_coords, zoom)

            mutex.unlock()

func download_tile_texture(tile_coords: Vector2i, zoom: int, texture_type: int) -> Texture2D:
    var url_template = TEXTURE_TYPE_URLS[texture_type]
    var url = url_template.format({
        "z": zoom,
        "x": tile_coords.x,
        "y": tile_coords.y
    })

    var http_request = null
    for request in http_requests:
        if request.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
            http_request = request
            break

    if not http_request:
        return null

    var semaphore = Semaphore.new()
    var result_array = []

    # Connect to the signal in the main thread
    call_deferred("_start_http_request", http_request, url, semaphore, result_array)

    # Wait for the semaphore
    semaphore.wait()

    if result_array[0] != HTTPRequest.RESULT_SUCCESS:
        print("Failed to download ", TEXTURE_TYPE_PATHS[texture_type], " tile: ", tile_coords, " Error: ", result_array[0])
        return null

    var body = result_array[3] as PackedByteArray

    # Save the raw PNG data to cache
    save_tile_to_cache(tile_coords, zoom, texture_type, body)

    var image = Image.new()
    var image_error = image.load_png_from_buffer(body)

    if image_error != OK:
        print("Failed to load PNG for ", TEXTURE_TYPE_PATHS[texture_type], " tile: ", tile_coords)
        return null

    var texture = ImageTexture.create_from_image(image)
    print("Successfully downloaded ", TEXTURE_TYPE_PATHS[texture_type], " tile: ", tile_coords, " at zoom ", zoom)
    return texture

# Updated cache functions
func load_tile_from_cache(tile_coords: Vector2i, zoom: int, texture_type: int) -> Texture2D:
    var cache_path = get_tile_cache_path(tile_coords, zoom, texture_type)
    var file = FileAccess.open(cache_path, FileAccess.READ)

    if file:
        var buffer = file.get_buffer(file.get_length())
        file.close()

        var image = Image.new()
        var error = image.load_png_from_buffer(buffer)

        if error == OK:
            var texture = ImageTexture.create_from_image(image)
            print("Loaded ", TEXTURE_TYPE_PATHS[texture_type], " tile from cache: ", tile_coords, " at zoom ", zoom)
            return texture

    return null

func get_tile_cache_path(tile_coords: Vector2i, zoom: int, texture_type: int) -> String:
    var type_path = TEXTURE_TYPE_PATHS[texture_type]
    return "user://tile_cache/%s/zoom_%d/%d/%d.png" % [type_path, zoom, tile_coords.x, tile_coords.y]

func ensure_cache_directory(path: String):
    var dir_path = path.get_base_dir()
    if not DirAccess.dir_exists_absolute(dir_path):
        DirAccess.make_dir_recursive_absolute(dir_path)

func save_tile_to_cache(tile_coords: Vector2i, zoom: int, texture_type: int, image_data: PackedByteArray) -> bool:
    var cache_path = get_tile_cache_path(tile_coords, zoom, texture_type)

    # Ensure directory exists
    ensure_cache_directory(cache_path)

    var file = FileAccess.open(cache_path, FileAccess.WRITE)
    if file:
        file.store_buffer(image_data)
        file.close()
        print("Saved ", TEXTURE_TYPE_PATHS[texture_type], " tile to cache: ", tile_coords, " at zoom ", zoom)
        return true

    print("ERROR: Failed to save ", TEXTURE_TYPE_PATHS[texture_type], " tile to cache: ", tile_coords)
    return false

func update_tile_cache(tile_key: String, tile_data: Dictionary):
    # Remove if already in cache
    for i in range(tile_cache.size()):
        if tile_cache[i].key == tile_key:
            tile_cache.remove_at(i)
            break

    # Add to front
    tile_cache.push_front({"key": tile_key, "data": tile_data})

    # Trim cache if too large
    while tile_cache.size() > cache_size:
        var removed = tile_cache.pop_back()
        loaded_textures.erase(removed.key)

# Updated shader with normal map support
func setup_terrain_mesh():
    terrain_mesh_instance = MeshInstance3D.new()
    add_child(terrain_mesh_instance)

    # Create a simple plane for now - we'll update it based on loaded tiles
    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(10, 10)
    terrain_mesh_instance.mesh = plane_mesh

    # Create shader material
    shader_material = ShaderMaterial.new()
    shader_material.shader = preload("shaders/terrain_shader.gdshader")
    terrain_mesh_instance.material_override = shader_material

func queue_collision_generation(tile_coords: Vector2i, zoom: int, texture: Texture2D):
    collision_mutex.lock()
    collision_generation_queue.append({
        "coords": tile_coords,
        "zoom": zoom,
        "texture": texture
    })
    collision_mutex.unlock()

func generate_collision_threaded(collision_job):
    var tile_coords = collision_job["coords"]
    var zoom = collision_job["zoom"]
    var texture = collision_job["texture"]

    var collision_shape = generate_collision_shape(texture)

    if collision_shape:
        call_deferred("_on_collision_generation_complete", tile_coords, zoom, collision_shape)
    else:
        collision_mutex.lock()
        active_collision_generations -= 1
        collision_mutex.unlock()

func _on_collision_generation_complete(tile_coords: Vector2i, zoom: int, collision_shape: HeightMapShape3D):
    var tile_key = get_tile_key(tile_coords, zoom)

    # Cache the shape
    collision_shapes[tile_key] = collision_shape

    # Set as current collision if this is still the active tile
    if tile_coords == current_tile_coords and zoom == current_zoom:
        if current_collision_body:
            current_collision_body.queue_free()

        current_collision_body = create_collision_body_from_shape(collision_shape)
        add_child(current_collision_body)
        print("High-res collision generated for tile: ", tile_coords)

    collision_mutex.lock()
    active_collision_generations -= 1
    collision_mutex.unlock()

    if collision_thread and collision_thread.is_started():
        collision_thread.wait_to_finish()
        collision_thread = null

func generate_collision_for_tile(tile_coords: Vector2i, zoom: int, texture: Texture2D):
    var tile_key = get_tile_key(tile_coords, zoom)

    # Remove old collision body if it exists
    if current_collision_body:
        current_collision_body.queue_free()
        current_collision_body = null

    # Mark collision as not ready
    collision_ready = false
    waiting_for_collision = true

    # Check if we already have a collision shape for this tile
    if collision_shapes.has(tile_key):
        current_collision_body = create_collision_body_from_shape(collision_shapes[tile_key])
        add_child(current_collision_body)
        collision_ready = true
        waiting_for_collision = false
        print("Reused existing collision for tile: ", tile_coords)
        return

    # Generate new collision shape with full resolution
    var collision_shape = generate_collision_shape(texture)
    if collision_shape:
        # Cache the shape for future use
        collision_shapes[tile_key] = collision_shape
        current_collision_body = create_collision_body_from_shape(collision_shape)
        add_child(current_collision_body)
        collision_ready = true
        waiting_for_collision = false
        print("Generated high-res collision (256x256) for tile: ", tile_coords)
    else:
        waiting_for_collision = false

func generate_collision_shape(texture: Texture2D) -> HeightMapShape3D:
    var image = texture.get_image()
    var image_size = image.get_size()

    var collision_width = image_size.x  # 256
    var collision_depth = image_size.y  # 256
    var height_data = PackedFloat32Array()
    height_data.resize(collision_width * collision_depth)

    # Get the current tile size for proper scaling
    var tile_size_meters = get_tile_size_meters(current_zoom)

    # Sample every pixel with absolute elevation values
    for z in range(collision_depth):
        for x in range(collision_width):
            var color = image.get_pixel(x, z)
            var absolute_elevation = decode_height_from_color(color)

            height_data[z * collision_width + x] = absolute_elevation

    var heightmap_shape = HeightMapShape3D.new()
    heightmap_shape.map_width = collision_width
    heightmap_shape.map_depth = collision_depth
    heightmap_shape.map_data = height_data

    return heightmap_shape

func get_tile_size_meters(zoom: int) -> float:
    return EARTH_CIRCUMFERENCE / pow(2.0, zoom)

func create_collision_body_from_shape(shape: HeightMapShape3D) -> StaticBody3D:
    var static_body = StaticBody3D.new()
    var collision_shape = CollisionShape3D.new()
    collision_shape.shape = shape

    # Get the current tile size
    var tile_size_meters = get_tile_size_meters(current_zoom)

    # Scale the collision shape to match the visual mesh exactly
    var scale_x = tile_size_meters / (shape.map_width - 1)
    var scale_z = tile_size_meters / (shape.map_depth - 1)

    collision_shape.scale = Vector3(scale_x, 1.0, scale_z)

    # Position the collision body to match the visual mesh
    #static_body.position = Vector3(-tile_size_meters / 2, 0, -tile_size_meters / 2)

    static_body.add_child(collision_shape)

    print("Collision body created - Position: ", static_body.position, " Scale: (", scale_x, ", 1.0, ", scale_z, ")")
    return static_body

func decode_height_from_color(color: Color) -> float:
    var r = color.r * 255.0
    var g = color.g * 255.0
    var b = color.b * 255.0
    return (r * 256.0 + g + b / 256.0) - 32768.0

# Add this to clean up collision shapes when they're no longer needed
func cleanup_old_collision_shapes():
    var current_tile_key = get_tile_key(current_tile_coords, current_zoom)
    var keys_to_remove = []

    for key in collision_shapes:
        if key != current_tile_key and not loaded_textures.has(key):
            keys_to_remove.append(key)

    for key in keys_to_remove:
        collision_shapes.erase(key)

    if keys_to_remove.size() > 0:
        print("Cleaned up ", keys_to_remove.size(), " old collision shapes")

func _ready():
    mutex = Mutex.new()
    semaphore = Semaphore.new()

    # Create HTTP requests on main thread
    for i in range(max_concurrent_downloads):
        var http_request = HTTPRequest.new()
        add_child(http_request)
        http_requests.append(http_request)

    setup_terrain_mesh()

    # Start download thread
    download_thread = Thread.new()
    download_thread.start(_download_worker)

    # Initial load
    call_deferred("update_terrain")

    # Initialize collision state
    collision_ready = false
    waiting_for_collision = false

func _exit_tree():
    should_exit = true
    semaphore.post()  # Wake up thread so it can exit
    if download_thread and download_thread.is_started():
        download_thread.wait_to_finish()

    for http_request in http_requests:
        http_request.queue_free()

func _physics_process(delta):
    time_since_last_update += delta

    # Handle collision generation queue
    collision_mutex.lock()
    if collision_generation_queue.size() > 0 and active_collision_generations < max_concurrent_collision_generations:
        var collision_job = collision_generation_queue.pop_front()
        active_collision_generations += 1
        collision_mutex.unlock()

        # Generate collision in a thread if enabled, otherwise on main thread
        if use_collision_threading and collision_thread == null:
            collision_thread = Thread.new()
            collision_thread.start(generate_collision_threaded.bind(collision_job))
        else:
            call_deferred("generate_collision_for_tile", collision_job["coords"], collision_job["zoom"], collision_job["texture"])
            active_collision_generations -= 1
    else:
        collision_mutex.unlock()

    # Update terrain at regular intervals
    if time_since_last_update >= update_interval:
        time_since_last_update = 0.0
        update_terrain()

        # If we're waiting for collision and it's now ready, reposition player
        if waiting_for_collision and collision_ready:
            waiting_for_collision = false
            call_deferred("spawn_player_at_terrain")

var time_since_last_update: float = 0.0

func update_terrain():
    if not target_node:
        return

    var player_pos = target_node.global_position

    # Use absolute altitude for LOD, not height above terrain
    var new_zoom = calculate_dynamic_zoom(player_pos.y)
    if new_zoom != current_zoom:
        current_zoom = new_zoom
        print("Zoom level changed to: ", current_zoom, " (absolute altitude: ", player_pos.y, "m)")

    # Convert player position to tile coordinates
    var new_tile_coords = world_to_tile_coords(player_pos)

    if new_tile_coords != current_tile_coords or new_zoom != current_zoom:
        current_tile_coords = new_tile_coords
        load_tile_and_neighbors(new_tile_coords)

        # If player is below collision threshold, mark that we need collision
        if enable_collision and player_pos.y < collision_lod_threshold:
            waiting_for_collision = true
    auto_position_player_on_collision()

func calculate_height_above_terrain(world_pos: Vector3) -> float:
    # First, try to use the current tile
    var tile_key = get_tile_key(current_tile_coords, current_zoom)

    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has("terrarium"):
        var texture = loaded_textures[tile_key]["terrarium"]
        var image = texture.get_image()

        # Convert world position to UV coordinates
        var tile_size = get_tile_size_meters(current_zoom)

        var u = (world_pos.x + tile_size / 2) / tile_size
        var v = (world_pos.z + tile_size / 2) / tile_size

        # If we're outside the current tile, try to find the right tile
        if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
            # We're outside the current tile, estimate height
            return estimate_height_above_terrain(world_pos)

        # Clamp UV coordinates
        u = clamp(u, 0.0, 1.0)
        v = clamp(v, 0.0, 1.0)

        var terrain_elevation = sample_height_bilinear(image, u, v)
        return max(0.0, world_pos.y - terrain_elevation)
    else:
        # Fallback: use absolute height if we don't have terrain data
        return world_pos.y

func estimate_height_above_terrain(world_pos: Vector3) -> float:
    # Simple estimation: use the average elevation of the current tile
    var tile_key = get_tile_key(current_tile_coords, current_zoom)

    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has("terrarium"):
        var texture = loaded_textures[tile_key]["terrarium"]
        var image = texture.get_image()

        # Sample the center of the tile as an estimate
        var center_elevation = sample_height_bilinear(image, 0.5, 0.5)
        return max(0.0, world_pos.y - center_elevation)
    else:
        return world_pos.y


func calculate_dynamic_zoom(player_altitude: float) -> int:
    # Use absolute altitude for LOD
    # Higher altitude = lower zoom (less detail)
    # Add a small buffer to ensure ground level uses min_zoom
    var effective_altitude = max(0.0, player_altitude - lod_min_height)  # 50m buffer
    var t = clamp(effective_altitude / lod_max_height, 0.0, 1.0)
    return int(lerp(float(min_zoom), float(max_zoom), t))

func world_to_tile_coords(world_position: Vector3) -> Vector2i:
    # Convert world position to geographic coordinates
    var lat_lon = world_to_lat_lon(world_position)
    return lat_lon_to_tile(lat_lon.x, lat_lon.y, current_zoom)

func world_to_lat_lon(world_pos: Vector3) -> Vector2:
    # Convert world coordinates (meters) to lat/lon with proper scale
    var meters_per_degree_lat = 111000.0  # Approximately 111km per degree latitude
    var meters_per_degree_lon = 111000.0 * cos(deg_to_rad(start_latitude))  # Adjust for latitude

    # Since the tile is centered at (0,0,0), we need to adjust the conversion
    var lat = start_latitude - (world_pos.z / meters_per_degree_lat)
    var lon = start_longitude + (world_pos.x / meters_per_degree_lon)

    return Vector2(lat, lon)

func lat_lon_to_world(lat: float, lon: float) -> Vector3:
    # Convert lat/lon to world coordinates with proper scale
    var meters_per_degree_lat = 111000.0
    var meters_per_degree_lon = 111000.0 * cos(deg_to_rad(start_latitude))

    var world_x = (lon - start_longitude) * meters_per_degree_lon
    var world_z = (start_latitude - lat) * meters_per_degree_lat

    return Vector3(world_x, 0, world_z)

func lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Vector2i:
    var n = pow(2.0, zoom)
    var x_tile = int((lon + 180.0) / 360.0 * n)
    var lat_rad = deg_to_rad(lat)
    var y_tile = int((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n)
    return Vector2i(x_tile, y_tile)

func deg_to_rad(deg: float) -> float:
    return deg * PI / 180.0

func calculate_neighbor_count() -> int:
    # Calculate how many neighboring tiles to load based on view distance
    # Higher zoom = smaller tiles = more neighbors needed
    var base_tile_size_meters = 40000000.0 / pow(2.0, current_zoom)  # Approximate tile size in meters
    var tiles_needed = int(ceil(max_view_distance / base_tile_size_meters))
    return clamp(tiles_needed, 1, 3)  # Limit to reasonable number

func get_tile_key(coords: Vector2i, zoom: int) -> String:
    return "%d_%d_%d" % [coords.x, coords.y, zoom]

func _start_http_request(http_request: HTTPRequest, url: String, semaphore: Semaphore, result_array: Array):
    # Disconnect if already connected to avoid multiple connections
    if http_request.is_connected("request_completed", _on_http_request_completed):
        http_request.request_completed.disconnect(_on_http_request_completed)
    http_request.request_completed.connect(_on_http_request_completed.bind(semaphore, result_array))
    var error = http_request.request(url)
    if error != OK:
        # If request fails immediately, we still need to post the semaphore
        result_array.append_array([error, 0, [], []])
        semaphore.post()

func _on_http_request_completed(result_code: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, semaphore: Semaphore, result_array: Array):
    result_array.append_array([result_code, response_code, headers, body])
    semaphore.post()

func update_mesh_for_zoom(zoom: int, height_texture: Texture2D = null):
    # Calculate proper tile size in meters
    var tile_size_meters = get_tile_size_meters(zoom)

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(tile_size_meters, tile_size_meters)
    plane_mesh.subdivide_depth = 255
    plane_mesh.subdivide_width = 255

    terrain_mesh_instance.mesh = plane_mesh

    # Position the mesh so it's centered at (0,0,0) in XZ, but at proper elevation in Y
    # We'll handle Y positioning separately based on the actual terrain height
    #terrain_mesh_instance.position = Vector3(-tile_size_meters / 2, 0, -tile_size_meters / 2)

    # Update shader with correct scale
    shader_material.set_shader_parameter("terrain_scale", tile_size_meters)

    # If we have height data, debug the elevation range
    if height_texture:
        var height_range = debug_height_range(height_texture, current_tile_coords)
        print("Mesh updated - Size: ", tile_size_meters, "m, Height range: ", height_range.min, "m to ", height_range.max, "m")
    else:
        print("Mesh updated - Size: ", tile_size_meters, "m")

func set_player_on_ground():
    if not target_node:
        return

    var player_pos = target_node.global_position
    var elevation = get_terrain_elevation_at_position(player_pos)

    if elevation > 0:
        # Position player at terrain elevation + eye height
        target_node.global_position.y = elevation + 1.8
        print("Positioned player on terrain: ", elevation, "m + 1.8m eye height")
    else:
        print("Could not position player - no elevation data")

func get_terrain_elevation_at_position(world_pos: Vector3) -> float:
    var tile_key = get_tile_key(current_tile_coords, current_zoom)

    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has("terrarium"):
        var texture = loaded_textures[tile_key]["terrarium"]
        var image = texture.get_image()

        # Convert world position to UV coordinates
        var tile_size = get_tile_size_meters(current_zoom)

        var u = (world_pos.x + tile_size / 2) / tile_size
        var v = (world_pos.z + tile_size / 2) / tile_size

        # Clamp UV coordinates
        u = clamp(u, 0.0, 1.0)
        v = clamp(v, 0.0, 1.0)

        return sample_height_bilinear(image, u, v)
    return 0.0

func position_player_using_heightmap():
    if not target_node:
        return

    var player_pos = target_node.global_position
    var tile_key = get_tile_key(current_tile_coords, current_zoom)

    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has("terrarium"):
        var tile_data = loaded_textures[tile_key]
        var texture = tile_data["terrarium"]
        var image = texture.get_image()

        # Convert player position to UV coordinates, accounting for mesh offset
        var tile_size = get_tile_size_meters(current_zoom)
        var mesh_offset = Vector2.ZERO #(tile_size / 2, tile_size / 2)  # Mesh is centered

        var local_x = player_pos.x + mesh_offset.x
        var local_z = player_pos.z + mesh_offset.y

        var u = local_x / tile_size
        var v = local_z / tile_size

        # Use bilinear interpolation for smoother height sampling
        var absolute_elevation = sample_height_bilinear(image, u, v)

        # Set player at absolute elevation + eye height
        target_node.global_position.y = absolute_elevation + 1.8
        print("Positioned player at absolute elevation: ", absolute_elevation, " meters + 1.8m eye height")
    else:
        print("No heightmap data available for player positioning")

func sample_height_bilinear(image: Image, u: float, v: float) -> float:
    var width = image.get_width()
    var height = image.get_height()

    var x = u * (width - 1)
    var y = v * (height - 1)

    var x1 = floor(x)
    var x2 = min(x1 + 1, width - 1)
    var y1 = floor(y)
    var y2 = min(y1 + 1, height - 1)

    var q11 = decode_height_from_color(image.get_pixel(x1, y1))
    var q21 = decode_height_from_color(image.get_pixel(x2, y1))
    var q12 = decode_height_from_color(image.get_pixel(x1, y2))
    var q22 = decode_height_from_color(image.get_pixel(x2, y2))

    # Bilinear interpolation
    var x_factor = x - x1
    var y_factor = y - y1

    var top = lerp(q11, q21, x_factor)
    var bottom = lerp(q12, q22, x_factor)

    return lerp(top, bottom, y_factor)

func get_tile_bounds(tile_coords: Vector2i, zoom: int) -> Array:
    var n = pow(2.0, zoom)
    var min_lon = (tile_coords.x / n) * 360.0 - 180.0
    var max_lon = ((tile_coords.x + 1) / n) * 360.0 - 180.0

    var min_lat = rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * (tile_coords.y + 1) / n))))
    var max_lat = rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * tile_coords.y / n))))

    return [min_lon, min_lat, max_lon, max_lat]

func rad_to_deg(rad: float) -> float:
    return rad * 180.0 / PI

# Debug function to see loaded tiles
func get_loaded_tiles_info() -> String:
    mutex.lock()
    var info = "Loaded tiles: " + str(loaded_textures.size()) + "\n"
    info += "Queue: " + str(download_queue.size()) + "\n"
    info += "Current zoom: " + str(current_zoom) + "\n"
    info += "Current tile: " + str(current_tile_coords) + "\n"
    mutex.unlock()
    return info

# Updated timing using Time singleton
func _process(delta):
    # Clean up old collision shapes every 10 seconds
    var current_time = Time.get_ticks_msec()
    if current_time - last_collision_update > 10000:  # 10 seconds
        cleanup_old_collision_shapes()
        last_collision_update = current_time

#func _input(event):
    #if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
        #print("=== TERRAIN DEBUG INFO ===")
        #print("Current tile: ", current_tile_coords, " Zoom: ", current_zoom)
#
        #var tile_size = get_tile_size_meters(current_zoom)
        #print("Tile size: ", tile_size, " meters")
        #print("Mesh size: ", terrain_mesh_instance.mesh.size if terrain_mesh_instance.mesh else "No mesh")
        #print("Mesh position: ", terrain_mesh_instance.position)
#
        #var player_pos = target_node.global_position
        #print("Player world position: ", player_pos)
#
        #var lat_lon = world_to_lat_lon(player_pos)
        #print("Player geographic: lat=", lat_lon.x, " lon=", lat_lon.y)
#
        #if terrain_mesh_instance.mesh is PlaneMesh:
            #var plane_mesh = terrain_mesh_instance.mesh as PlaneMesh
            #print("Mesh subdivisions: ", plane_mesh.subdivide_width, "x", plane_mesh.subdivide_depth)
#
        #debug_lod_status()
        ## Debug collision scaling
        #debug_collision_scaling()
#
        ## Debug cache status
        #debug_cache_status()
#
        #debug_terrain_elevation()

func _input(event):
    if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
        print("=== TERRAIN DEBUG INFO ===")
        print("Current tile: ", current_tile_coords, " Zoom: ", current_zoom)

        var tile_size = get_tile_size_meters(current_zoom)
        print("Tile size: ", tile_size, " meters")
        print("Player position: ", target_node.global_position)

        # Debug LOD status
        debug_lod_status()

        # Test terrain height at player position
        var elevation = get_terrain_elevation_at_position(target_node.global_position)
        print("Terrain elevation at player: ", elevation, "m")

    if event is InputEventKey and event.pressed and event.keycode == KEY_P:
        # Spawn player at proper terrain elevation
        spawn_player_at_terrain()

    if event is InputEventKey and event.pressed and event.keycode == KEY_L:
        # Debug LOD specifically
        debug_lod_status()

func debug_collision_scaling():
    print("=== COLLISION SCALING DEBUG ===")
    print("Collision ready: ", collision_ready)
    print("Waiting for collision: ", waiting_for_collision)

    if current_collision_body:
        var collision_shape_node = current_collision_body.get_child(0) as CollisionShape3D
        if collision_shape_node:
            var shape = collision_shape_node.shape as HeightMapShape3D
            if shape:
                print("Collision Shape:")
                print("  Map width: ", shape.map_width)
                print("  Map depth: ", shape.map_depth)
                print("  Data points: ", shape.map_data.size())

            print("Collision Node:")
            print("  Global position: ", current_collision_body.global_position)
            print("  Scale: ", collision_shape_node.scale)

    print("Mesh Instance:")
    print("  Global position: ", terrain_mesh_instance.global_position)
    print("  Mesh size: ", terrain_mesh_instance.mesh.size if terrain_mesh_instance.mesh else "No mesh")

func debug_cache_status():
    print("=== CACHE DEBUG ===")
    print("Loaded textures count: ", loaded_textures.size())
    print("Tile cache count: ", tile_cache.size())

    # Check current tile
    var current_key = get_tile_key(current_tile_coords, current_zoom)
    print("Current tile key: ", current_key)

    if loaded_textures.has(current_key):
        print("Current tile in memory: ", loaded_textures[current_key].keys())
    else:
        print("Current tile NOT in memory")

    # Check disk cache for current tile
    var terrarium_path = get_tile_cache_path(current_tile_coords, current_zoom, TEXTURE_TYPE.TERRARIUM)
    var normal_path = get_tile_cache_path(current_tile_coords, current_zoom, TEXTURE_TYPE.NORMAL)

    print("Terrarium cache path: ", terrarium_path)
    print("Terrarium file exists: ", FileAccess.file_exists(terrarium_path))
    print("Normal cache path: ", normal_path)
    print("Normal file exists: ", FileAccess.file_exists(normal_path))

    # List all cached files for current zoom
    var cache_dir = "user://tile_cache/terrarium/zoom_%d/" % current_zoom
    if DirAccess.dir_exists_absolute(cache_dir):
        var dir = DirAccess.open(cache_dir)
        if dir:
            dir.list_dir_begin()
            var file = dir.get_next()
            var file_count = 0
            while file != "":
                if file.ends_with(".png"):
                    file_count += 1
                file = dir.get_next()
            print("Cached terrarium tiles at zoom %d: %d" % [current_zoom, file_count])

func debug_height_range(texture: Texture2D, tile_coords: Vector2i):
    var image = texture.get_image()
    var min_height = INF
    var max_height = -INF

    for x in range(image.get_width()):
        for y in range(image.get_height()):
            var color = image.get_pixel(x, y)
            var height = decode_height_from_color(color)
            min_height = min(min_height, height)
            max_height = max(max_height, height)

    print("Tile ", tile_coords, " height range: ", min_height, "m to ", max_height, "m")
    return {"min": min_height, "max": max_height}

func debug_terrain_elevation():
    print("=== TERRAIN ELEVATION DEBUG ===")

    var tile_key = get_tile_key(current_tile_coords, current_zoom)
    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has("terrarium"):
        var texture = loaded_textures[tile_key]["terrarium"]
        var image = texture.get_image()

        # Sample multiple points to understand the elevation
        var sample_points = [
            Vector2i(0, 0),      # Bottom-left
            Vector2i(128, 128),  # Center
            Vector2i(255, 255)   # Top-right
        ]

        for point in sample_points:
            var color = image.get_pixel(point.x, point.y)
            var elevation = decode_height_from_color(color)
            print("  Point ", point, " - Absolute elevation: ", elevation, "m")

    print("Mesh position: ", terrain_mesh_instance.global_position)
    print("Mesh AABB: ", terrain_mesh_instance.get_aabb())

    if current_collision_body:
        print("Collision position: ", current_collision_body.global_position)

func debug_lod_status():
    print("=== LOD DEBUG ===")
    var player_pos = target_node.global_position
    var calculated_zoom = calculate_dynamic_zoom(player_pos.y)

    print("Player position: ", player_pos)
    print("Absolute altitude: ", player_pos.y, "m")
    print("Current zoom: ", current_zoom)
    print("Calculated zoom: ", calculated_zoom)
    print("LOD max height: ", lod_max_height, "m")
    print("LOD min height: ", lod_min_height, "m")
    print("Min zoom: ", min_zoom, " (highest detail)")
    print("Max zoom: ", max_zoom, " (lowest detail)")

    # Check terrain elevation at player position
    var terrain_elevation = get_terrain_elevation_at_position(player_pos)
    print("Terrain elevation at player: ", terrain_elevation, "m")
    print("Height above terrain: ", max(0.0, player_pos.y - terrain_elevation), "m")

    # Check if we're using the right LOD
    if current_zoom != calculated_zoom:
        print("LOD MISMATCH: Should be at zoom ", calculated_zoom)
    else:
        print("LOD is correct")

func spawn_player_at_terrain():
    if not target_node:
        return

    # Get elevation at world origin (center of current tile)
    var elevation = get_terrain_elevation_at_position(Vector3.ZERO)

    if elevation > 0:
        target_node.global_position = Vector3(0, elevation + 1.8, 0)
        print("Spawned player at terrain elevation: ", elevation, "m")

        # Reset player velocity to prevent falling
        reset_player_velocity()
    else:
        # Fallback: use average elevation from height range
        var tile_key = get_tile_key(current_tile_coords, current_zoom)
        if loaded_textures.has(tile_key) and loaded_textures[tile_key].has("terrarium"):
            var texture = loaded_textures[tile_key]["terrarium"]
            var height_range = debug_height_range(texture, current_tile_coords)
            var avg_elevation = (height_range["min"] + height_range["max"]) / 2.0
            target_node.global_position = Vector3(0, avg_elevation + 1.8, 0)
            print("Spawned player at average elevation: ", avg_elevation, "m")
            reset_player_velocity()

func reset_player_velocity():
    if target_node and target_node.has_method("set_velocity"):
        target_node.set_velocity(Vector3.ZERO)
    elif target_node and target_node.has_method("reset_velocity"):
        target_node.reset_velocity()

func auto_position_player_on_collision():
    if not target_node or not collision_ready:
        return

    var player_pos = target_node.global_position
    var terrain_elevation = get_terrain_elevation_at_position(player_pos)
    var height_above_terrain = player_pos.y - terrain_elevation

    # If player is significantly above or below terrain, reposition them
    if height_above_terrain > 100.0 or height_above_terrain < -10.0:
        print("Auto-positioning player on collision: too far from terrain (", height_above_terrain, "m)")
        spawn_player_at_terrain()
