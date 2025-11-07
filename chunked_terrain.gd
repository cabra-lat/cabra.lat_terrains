extends Node3D
class_name DynamicTerrainLoader

@export_category("Player Tracking")
@export var target_node: Node3D
@export var update_interval: float = 1.0

@export_category("World Settings")
@export var start_latitude: float = -15.708  # Brasília coordinates
@export var start_longitude: float = -48.560
@export var world_scale: float = 100.0  # Meters per degree at equator
@export var max_view_distance: float = 2000.0  # Meters

@export_category("LOD Settings")
@export var min_zoom: int = 15  # Highest detail (ground level)
@export var max_zoom: int = 10  # Lowest detail (high altitude)
@export var lod_height_threshold: float = 1000.0  # Height where we switch to lower LOD

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
var loaded_tiles: Dictionary = {}
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

const TILE_BASE_URL = "https://elevation-tiles-prod.s3.amazonaws.com/terrarium/{z}/{x}/{y}.png"

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

func update_shader_with_tile(tile_coords: Vector2i, zoom: int):
    var tile_key = get_tile_key(tile_coords, zoom)

    if loaded_tiles.has(tile_key):
        var tile_data = loaded_tiles[tile_key]
        var texture = tile_data["texture"]

        # Update shader parameters
        shader_material.set_shader_parameter("heightmap_texture", texture)
        shader_material.set_shader_parameter("tile_coords", Vector2(tile_coords))
        shader_material.set_shader_parameter("current_zoom", zoom)
        shader_material.set_shader_parameter("terrain_scale", 100.0)
        shader_material.set_shader_parameter("height_scale", 0.1)

        # Update mesh for current zoom
        update_mesh_for_zoom(zoom)

        # Generate collision if enabled and we're close to the ground
        if enable_collision and target_node and target_node.global_position.y < collision_lod_threshold:
            call_deferred("generate_collision_for_tile", tile_coords, zoom, texture)

        print("Updated terrain to tile: ", tile_coords, " at zoom ", zoom)


func generate_collision_for_tile(tile_coords: Vector2i, zoom: int, texture: Texture2D):
    var tile_key = get_tile_key(tile_coords, zoom)

    # Remove old collision body if it exists
    if current_collision_body:
        current_collision_body.queue_free()
        current_collision_body = null

    # Check if we already have a collision shape for this tile
    if collision_shapes.has(tile_key):
        current_collision_body = create_collision_body_from_shape(collision_shapes[tile_key])
        add_child(current_collision_body)
        print("Reused existing collision for tile: ", tile_coords)
        return

    # Generate new collision shape with full resolution
    var collision_shape = generate_collision_shape(texture)
    if collision_shape:
        # Cache the shape for future use
        collision_shapes[tile_key] = collision_shape
        current_collision_body = create_collision_body_from_shape(collision_shape)
        add_child(current_collision_body)
        print("Generated high-res collision (256x256) for tile: ", tile_coords)


func generate_collision_shape(texture: Texture2D) -> HeightMapShape3D:
    var image = texture.get_image()
    var image_size = image.get_size()

    # Use full texture resolution for collision
    var collision_width = image_size.x  # 256
    var collision_depth = image_size.y  # 256
    var height_data = PackedFloat32Array()
    height_data.resize(collision_width * collision_depth)

    # Sample every pixel of the heightmap
    for z in range(collision_depth):
        for x in range(collision_width):
            var color = image.get_pixel(x, z)
            var height = decode_height_from_color(color) * 0.1  # Match the visual scale

            height_data[z * collision_width + x] = height

    # Create heightmap shape
    var heightmap_shape = HeightMapShape3D.new()
    heightmap_shape.map_width = collision_width
    heightmap_shape.map_depth = collision_depth
    heightmap_shape.map_data = height_data

    return heightmap_shape



func create_collision_body_from_shape(shape: HeightMapShape3D) -> StaticBody3D:
    var static_body = StaticBody3D.new()
    var collision_shape = CollisionShape3D.new()
    collision_shape.shape = shape

    # SCALE THE COLLISION SHAPE TO MATCH THE VISUAL MESH
    # Our visual mesh is 100m x 100m, but the heightmap shape defaults to 1 unit per vertex
    # We need to scale it to match our 100m x 100m visual size
    var mesh_size = 100.0  # Match the visual mesh size
    var scale_x = mesh_size / (shape.map_width - 1)
    var scale_z = mesh_size / (shape.map_depth - 1)
    collision_shape.scale = Vector3(scale_x, 1.0, scale_z)

    static_body.add_child(collision_shape)

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
        if key != current_tile_key and not loaded_tiles.has(key):
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

func _exit_tree():
    should_exit = true
    semaphore.post()  # Wake up thread so it can exit
    if download_thread and download_thread.is_started():
        download_thread.wait_to_finish()

    for http_request in http_requests:
        http_request.queue_free()

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

func _physics_process(delta):
    time_since_last_update += delta
    if time_since_last_update >= update_interval:
        time_since_last_update = 0.0
        update_terrain()
    # Process collision generation queue
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

var time_since_last_update: float = 0.0

func update_terrain():
    if not target_node:
        return

    var player_pos = target_node.global_position

    # Calculate dynamic zoom based on altitude
    var new_zoom = calculate_dynamic_zoom(player_pos.y)
    if new_zoom != current_zoom:
        current_zoom = new_zoom
        print("Zoom level changed to: ", current_zoom)

    # Convert player position to tile coordinates
    var new_tile_coords = world_to_tile_coords(player_pos)

    if new_tile_coords != current_tile_coords or new_zoom != current_zoom:
        current_tile_coords = new_tile_coords
        load_tile_and_neighbors(new_tile_coords)

func calculate_dynamic_zoom(altitude: float) -> int:
    # Higher altitude = lower zoom (less detail)
    var t = clamp(altitude / lod_height_threshold, 0.0, 1.0)
    return int(lerp(float(min_zoom), float(max_zoom), t))

func world_to_tile_coords(world_position: Vector3) -> Vector2i:
    # Convert world position to geographic coordinates
    var lat_lon = world_to_lat_lon(world_position)
    return lat_lon_to_tile(lat_lon.x, lat_lon.y, current_zoom)

func world_to_lat_lon(world_pos: Vector3) -> Vector2:
    # Convert world coordinates (meters) to lat/lon
    # Use a simpler approach - treat the world as a local area around start position
    var meters_per_degree = 111000.0  # Approximate meters per degree

    var lat = start_latitude - (world_pos.z / meters_per_degree)
    var lon = start_longitude + (world_pos.x / meters_per_degree)

    return Vector2(lat, lon)

func lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Vector2i:
    var n = pow(2.0, zoom)
    var x_tile = int((lon + 180.0) / 360.0 * n)
    var lat_rad = deg_to_rad(lat)
    var y_tile = int((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n)
    return Vector2i(x_tile, y_tile)

func deg_to_rad(deg: float) -> float:
    return deg * PI / 180.0

func load_tile_and_neighbors(center_tile: Vector2i):
    # Calculate how many neighbors to load based on view distance and zoom
    var num_neighbors = calculate_neighbor_count()

    for x in range(-num_neighbors, num_neighbors + 1):
        for y in range(-num_neighbors, num_neighbors + 1):
            var tile_coords = Vector2i(center_tile.x + x, center_tile.y + y)
            queue_tile_download(tile_coords)

func calculate_neighbor_count() -> int:
    # Calculate how many neighboring tiles to load based on view distance
    # Higher zoom = smaller tiles = more neighbors needed
    var base_tile_size_meters = 40000000.0 / pow(2.0, current_zoom)  # Approximate tile size in meters
    var tiles_needed = int(ceil(max_view_distance / base_tile_size_meters))
    return clamp(tiles_needed, 1, 3)  # Limit to reasonable number

func queue_tile_download(tile_coords: Vector2i):
    mutex.lock()

    var tile_key = get_tile_key(tile_coords, current_zoom)

    if loaded_tiles.has(tile_key) or is_tile_in_queue(tile_coords, current_zoom):
        mutex.unlock()
        return

    download_queue.append({"coords": tile_coords, "zoom": current_zoom})
    mutex.unlock()
    semaphore.post()  # Wake up download thread

func is_tile_in_queue(coords: Vector2i, zoom: int) -> bool:
    for tile in download_queue:
        if tile["coords"] == coords and tile["zoom"] == zoom:
            return true
    return false

func get_tile_key(coords: Vector2i, zoom: int) -> String:
    return "%d_%d_%d" % [coords.x, coords.y, zoom]

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
        mutex.unlock()

        # First try to load from disk cache
        var image_texture = load_tile_from_cache(tile_coords, zoom)

        # If not in cache, download it
        if not image_texture:
            image_texture = download_tile_texture(tile_coords, zoom)

        if image_texture:
            mutex.lock()
            var tile_key = get_tile_key(tile_coords, zoom)
            loaded_tiles[tile_key] = {
                "texture": image_texture,
                "coords": tile_coords,
                "zoom": zoom
            }

            # Update cache (LRU)
            update_tile_cache(tile_key, loaded_tiles[tile_key])

            # If this is the current tile at current zoom, update the shader
            if tile_coords == current_tile_coords and zoom == current_zoom:
                call_deferred("update_shader_with_tile", tile_coords, zoom)

            mutex.unlock()

# New function to load tile from disk cache
func load_tile_from_cache(tile_coords: Vector2i, zoom: int) -> Texture2D:
    var cache_path = get_tile_cache_path(tile_coords, zoom)
    var file = FileAccess.open(cache_path, FileAccess.READ)

    if file:
        var buffer = file.get_buffer(file.get_length())
        file.close()

        var image = Image.new()
        var error = image.load_png_from_buffer(buffer)

        if error == OK:
            var texture = ImageTexture.create_from_image(image)
            print("Loaded tile from cache: ", tile_coords, " at zoom ", zoom)
            return texture

    return null

# New function to save tile to disk cache
func save_tile_to_cache(tile_coords: Vector2i, zoom: int, image_data: PackedByteArray) -> bool:
    var cache_path = get_tile_cache_path(tile_coords, zoom)
    var dir_path = cache_path.get_base_dir()

    # Ensure directory exists
    DirAccess.make_dir_recursive_absolute(dir_path)

    var file = FileAccess.open(cache_path, FileAccess.WRITE)
    if file:
        file.store_buffer(image_data)
        file.close()
        print("Saved tile to cache: ", tile_coords, " at zoom ", zoom)
        return true

    return false

# Get the file path for a cached tile
func get_tile_cache_path(tile_coords: Vector2i, zoom: int) -> String:
    return "user://tile_cache/zoom_%d/%d/%d.png" % [zoom, tile_coords.x, tile_coords.y]

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
        loaded_tiles.erase(removed.key)

func download_tile_texture(tile_coords: Vector2i, zoom: int) -> Texture2D:
    var url = TILE_BASE_URL.format({
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
        print("Failed to download tile: ", tile_coords, " Error: ", result_array[0])
        return null

    var body = result_array[3] as PackedByteArray

    # Save the raw PNG data to cache
    save_tile_to_cache(tile_coords, zoom, body)

    var image = Image.new()
    var image_error = image.load_png_from_buffer(body)

    if image_error != OK:
        print("Failed to load PNG for tile: ", tile_coords)
        return null

    var texture = ImageTexture.create_from_image(image)
    print("Successfully downloaded tile: ", tile_coords, " at zoom ", zoom)
    return texture

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

func update_mesh_for_zoom(zoom: int):
    # Use a fixed mesh size that's reasonable for viewing
    var mesh_size = 100.0  # 100m x 100m area

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(mesh_size, mesh_size)
    plane_mesh.subdivide_depth = 255
    plane_mesh.subdivide_width = 255

    terrain_mesh_instance.mesh = plane_mesh

func set_player_on_ground():
    if not target_node:
        return

    # Use raycast to position player on terrain if collision is available
    if current_collision_body:
        var space_state = get_world_3d().direct_space_state
        var query = PhysicsRayQueryParameters3D.create(
            target_node.global_position + Vector3(0, 1000, 0),  # Start high above
            target_node.global_position + Vector3(0, -1000, 0)   # End far below
        )
        query.collision_mask = 1  # Make sure we only hit terrain

        var result = space_state.intersect_ray(query)
        if result:
            target_node.global_position = result.position + Vector3(0, 1.8, 0)  # 1.8m above ground (eye height)
            print("Positioned player on high-res terrain collision: ", result.position)
        else:
            # Fallback to heightmap sampling
            position_player_using_heightmap()
    else:
        # Fallback to heightmap sampling
        position_player_using_heightmap()

func position_player_using_heightmap():
    var player_pos = target_node.global_position
    var lat_lon = world_to_lat_lon(player_pos)
    var tile_coords = lat_lon_to_tile(lat_lon.x, lat_lon.y, current_zoom)
    var tile_key = get_tile_key(tile_coords, current_zoom)

    if loaded_tiles.has(tile_key):
        var tile_data = loaded_tiles[tile_key]
        var texture = tile_data["texture"]
        var image = texture.get_image()

        # Convert player position to UV coordinates within the tile
        var tile_bounds = get_tile_bounds(tile_coords, current_zoom)
        var u = (lat_lon.y - tile_bounds[0]) / (tile_bounds[2] - tile_bounds[0])
        var v = 1.0 - (lat_lon.x - tile_bounds[1]) / (tile_bounds[3] - tile_bounds[1])

        # Use bilinear interpolation for smoother height sampling
        var height = sample_height_bilinear(image, u, v) * 0.1

        target_node.global_position.y = height + 1.8  # 1.8m above ground (eye height)
        print("Positioned player using high-res heightmap: ", height, " meters")

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
    var info = "Loaded tiles: " + str(loaded_tiles.size()) + "\n"
    info += "Queue: " + str(download_queue.size()) + "\n"
    info += "Current zoom: " + str(current_zoom) + "\n"
    info += "Current tile: " + str(current_tile_coords) + "\n"
    mutex.unlock()
    return info

func _input(event):
    if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
        print("=== TERRAIN DEBUG INFO ===")
        print("Current tile: ", current_tile_coords, " Zoom: ", current_zoom)
        print("Player position: ", target_node.global_position)
        print("Loaded tiles: ", loaded_tiles.size())
        print("Mesh size: ", terrain_mesh_instance.mesh.size)

        var tile_key = get_tile_key(current_tile_coords, current_zoom)
        if loaded_tiles.has(tile_key):
            var texture = loaded_tiles[tile_key]["texture"]
            var image = texture.get_image()
            print("Texture size: ", image.get_size())

            # CORRECTED decoding for debug
            var center_color = image.get_pixel(128, 128)
            var r = center_color.r * 255.0
            var g = center_color.g * 255.0
            var b = center_color.b * 255.0
            var decoded_height = (r * 256.0 + g + b / 256.0) - 32768.0
            print("Center pixel color (0-255): ", Vector3(r, g, b))
            print("Decoded height at center: ", decoded_height, " meters")


# Updated timing using Time singleton
func _process(delta):
    # Clean up old collision shapes every 10 seconds
    var current_time = Time.get_ticks_msec()
    if current_time - last_collision_update > 10000:  # 10 seconds
        cleanup_old_collision_shapes()
        last_collision_update = current_time
