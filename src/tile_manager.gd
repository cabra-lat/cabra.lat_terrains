class_name TileManager
extends Node

# Configuration
var max_concurrent_downloads: int = 2
var cache_size: int = 25
var download_heightmaps: bool = true
var download_normal_maps: bool = true

# Internal state
var download_queue: Array = []
var active_downloads: int = 0
var tile_cache: Array = []
var loaded_textures: Dictionary = {}

# Threading
var download_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var should_exit: bool = false
var http_requests: Array = []

# References
var terrain_loader: DynamicTerrainLoader

func setup(loader: DynamicTerrainLoader):
    terrain_loader = loader
    # Read settings from main node
    max_concurrent_downloads = terrain_loader.max_concurrent_downloads
    cache_size = terrain_loader.cache_size
    download_heightmaps = terrain_loader.download_heightmaps
    download_normal_maps = terrain_loader.download_normal_maps
    mutex = Mutex.new()
    semaphore = Semaphore.new()

    # Create HTTP requests
    for i in range(max_concurrent_downloads):
        var http_request = HTTPRequest.new()
        terrain_loader.add_child(http_request)
        http_requests.append(http_request)

    # Start download thread
    download_thread = Thread.new()
    download_thread.start(_download_worker)

func load_tile_and_neighbors(center_tile: Vector2i, zoom: int):
    var num_neighbors = calculate_neighbor_count(zoom)

    for x in range(-num_neighbors, num_neighbors + 1):
        for y in range(-num_neighbors, num_neighbors + 1):
            var tile_coords = Vector2i(center_tile.x + x, center_tile.y + y)
            queue_tile_downloads(tile_coords, zoom)

func queue_tile_downloads(tile_coords: Vector2i, zoom: int):
    if download_heightmaps:
        queue_tile_download(tile_coords, zoom, TileTextureType.TERRARIUM)

    if download_normal_maps:
        queue_tile_download(tile_coords, zoom, TileTextureType.NORMAL)

func queue_tile_download(tile_coords: Vector2i, zoom: int, texture_type: int):
    mutex.lock()

    var tile_key = CoordinateConverter.get_tile_key(tile_coords, zoom)
    var texture_type_str = TileTextureType.get_type_path(texture_type)

    # Check if already loaded
    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has(texture_type_str):
        mutex.unlock()
        return

    # Check if already in queue
    if is_tile_in_queue(tile_coords, zoom, texture_type):
        mutex.unlock()
        return

    # Check cache
    var cached_texture = load_tile_from_cache(tile_coords, zoom, texture_type)
    if cached_texture:
        if not loaded_textures.has(tile_key):
            loaded_textures[tile_key] = {}

        loaded_textures[tile_key][texture_type_str] = cached_texture
        update_tile_cache(tile_key, loaded_textures[tile_key])
        mutex.unlock()

        # Notify terrain loader about new tile
        if tile_coords == terrain_loader.current_tile_coords and zoom == terrain_loader.lod_manager.current_zoom:
            terrain_loader.terrain_mesh_manager.on_tile_loaded(tile_coords, zoom, loaded_textures[tile_key])
        return

    # Queue for download
    download_queue.append({
        "coords": tile_coords,
        "zoom": zoom,
        "type": texture_type
    })
    mutex.unlock()
    semaphore.post()

func _download_worker():
    while not should_exit:
        semaphore.wait()
        if should_exit:
            break

        mutex.lock()
        if download_queue.size() == 0:
            mutex.unlock()
            continue

        var tile_data = download_queue.pop_front()
        mutex.unlock()

        process_tile_download(tile_data)

func is_tile_in_queue(coords: Vector2i, zoom: int, texture_type: int) -> bool:
    for tile in download_queue:
        if tile["coords"] == coords and tile["zoom"] == zoom and tile["type"] == texture_type:
            return true
    return false

func process_tile_download(tile_data: Dictionary):
    var tile_coords = tile_data["coords"]
    var zoom = tile_data["zoom"]
    var texture_type = tile_data["type"]
    var tile_key = CoordinateConverter.get_tile_key(tile_coords, zoom)
    var texture_type_str = TileTextureType.get_type_path(texture_type)

    # Skip if already loaded
    mutex.lock()
    var already_loaded = loaded_textures.has(tile_key) and loaded_textures[tile_key].has(texture_type_str)
    mutex.unlock()

    if already_loaded:
        return

    # Download the tile
    var image_texture = download_tile_texture(tile_coords, zoom, texture_type)

    if image_texture:
        mutex.lock()
        if not loaded_textures.has(tile_key):
            loaded_textures[tile_key] = {}

        loaded_textures[tile_key][texture_type_str] = image_texture
        update_tile_cache(tile_key, loaded_textures[tile_key])
        mutex.unlock()

        # Notify about new tile
        if tile_coords == terrain_loader.current_tile_coords and zoom == terrain_loader.lod_manager.current_zoom:
            terrain_loader.terrain_mesh_manager.on_tile_loaded(tile_coords, zoom, loaded_textures[tile_key])


func download_tile_texture(tile_coords: Vector2i, zoom: int, texture_type: int) -> Texture2D:
    var url_template = TileTextureType.get_type_url(texture_type)
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
        print("Failed to download ", TileTextureType.get_type_path(texture_type), " tile: ", tile_coords, " Error: ", result_array[0])
        return null

    var body = result_array[3] as PackedByteArray

    # Save the raw PNG data to cache
    save_tile_to_cache(tile_coords, zoom, texture_type, body)

    var image = Image.new()
    var image_error = image.load_png_from_buffer(body)

    if image_error != OK:
        print("Failed to load PNG for ", TileTextureType.get_type_path(texture_type), " tile: ", tile_coords)
        return null

    var texture = ImageTexture.create_from_image(image)
    print("Successfully downloaded ", TileTextureType.get_type_path(texture_type), " tile: ", tile_coords, " at zoom ", zoom)
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
            print("Loaded ", TileTextureType.get_type_path(texture_type), " tile from cache: ", tile_coords, " at zoom ", zoom)
            return texture

    return null

func get_tile_cache_path(tile_coords: Vector2i, zoom: int, texture_type: int) -> String:
    var type_path = TileTextureType.get_type_path(texture_type)
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
        print("Saved ", TileTextureType.get_type_path(texture_type), " tile to cache: ", tile_coords, " at zoom ", zoom)
        return true

    print("ERROR: Failed to save ", TileTextureType.get_type_path(texture_type), " tile to cache: ", tile_coords)
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

func get_texture_for_tile(tile_coords: Vector2i, zoom: int, texture_type: int) -> Texture2D:
    var tile_key = CoordinateConverter.get_tile_key(tile_coords, zoom)
    var texture_type_str = TileTextureType.get_type_path(texture_type)

    if loaded_textures.has(tile_key) and loaded_textures[tile_key].has(texture_type_str):
        return loaded_textures[tile_key][texture_type_str]
    return null

func cleanup():
    should_exit = true
    semaphore.post()
    if download_thread and download_thread.is_started():
        download_thread.wait_to_finish()

    for http_request in http_requests:
        http_request.queue_free()

func debug_cache_status(current_tile_coords: Vector2i):
    print("=== CACHE DEBUG ===")
    print("Loaded textures: ", loaded_textures.size())
    print("Download queue: ", download_queue.size())

    var current_key = CoordinateConverter.get_tile_key(current_tile_coords, terrain_loader.lod_manager.current_zoom)
    print("Current tile in memory: ", loaded_textures.has(current_key))

func calculate_neighbor_count(current_zoom: int) -> int:
    # Calculate how many neighboring tiles to load based on view distance
    # Higher zoom = smaller tiles = more neighbors needed
    var base_tile_size_meters = 40000000.0 / pow(2.0, current_zoom)  # Approximate tile size in meters
    var tiles_needed = int(ceil(terrain_loader.max_view_distance / base_tile_size_meters))
    return clamp(tiles_needed, 1, 3)  # Limit to reasonable number
