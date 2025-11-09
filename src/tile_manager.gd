class_name TileManager
extends Node

signal tile_loaded(tile_coords: Vector2i, zoom: int, layer_data: Dictionary)
signal tile_unloaded(tile_coords: Vector2i, zoom: int, layer_data: Dictionary)
signal tile_load_failed(tile_coords: Vector2i, zoom: int, layer_type: String, error: String)
signal token_refreshed(layer_type: String, success: bool)

# Layer configuration
class TileLayerConfig:
  var layer_type: String
  var url_template: String
  var file_extension: String
  var priority: int
  var enabled: bool
  var token: String
  var token_refresh_url: String
  var token_refresh_interval: float
  var requires_token: bool
  var last_token_refresh: float

  func _init(type: String, url: String, extension: String = "png", prio: int = 0,
        enabled_by_default: bool = true, token: String = "", refresh_url: String = "",
        refresh_interval: float = 3600.0, requires_token: bool = false):
    layer_type = type
    url_template = url
    file_extension = extension
    priority = prio
    enabled = enabled_by_default
    self.token = token
    token_refresh_url = refresh_url
    token_refresh_interval = refresh_interval
    self.requires_token = requires_token
    last_token_refresh = 0.0

# Main configuration
@export var max_concurrent_downloads: int = 2
@export var cache_size: int = 25
@export var download_retry_attempts: int = 3
@export var download_timeout: float = 30.0
@export var token_refresh_check_interval: float = 300.0  # Check tokens every 5 minutes

# Internal state
var download_queue: Array = []
var active_downloads: int = 0
var tile_cache: Array = []
var loaded_tiles: Dictionary = {}
var layer_configs: Dictionary = {}
var download_attempts: Dictionary = {}
var token_refresh_timer: Timer
var pending_token_refreshes: Dictionary = {}  # layer_type -> bool (true if refresh in progress)

# Threading
var download_thread: Thread
var mutex: Mutex
var semaphore: Semaphore
var should_exit: bool = false
var http_requests: Array = []

# References
var terrain_loader: DynamicTerrainLoader

func _ready() -> void:
  if Engine.is_editor_hint():
    return

  mutex = Mutex.new()
  semaphore = Semaphore.new()

  # Setup token refresh timer
  token_refresh_timer = Timer.new()
  token_refresh_timer.wait_time = token_refresh_check_interval
  token_refresh_timer.timeout.connect(_check_token_refresh)
  add_child(token_refresh_timer)
  token_refresh_timer.start()

  # Setup default layers with token support examples
  register_layer(TileLayerConfig.new("heightmap",
    "https://elevation-tiles-prod.s3.amazonaws.com/terrarium/{z}/{x}/{y}.png", "png", 2))
  register_layer(TileLayerConfig.new("normal",
    "https://elevation-tiles-prod.s3.amazonaws.com/normal/{z}/{x}/{y}.png", "png", 1))
  register_layer(TileLayerConfig.new("satellite",
    "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
    "jpg", 0))
  ## Example of a layer that requires token
  #register_layer(TileLayerConfig.new("mapbox_satellite",
    #"https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}.jpg?access_token={token}",
    #"jpg", 0, true, "", "https://api.mapbox.com/tokens/v2?access_token={token}",
    #3600.0, true))

  # Create HTTP requests
  for i in range(max_concurrent_downloads):
    var http_request = HTTPRequest.new()
    http_request.timeout = download_timeout
    if terrain_loader:
      terrain_loader.add_child(http_request)
    else:
      add_child(http_request)
    http_requests.append(http_request)

  # Start download thread
  download_thread = Thread.new()
  download_thread.start(_download_worker)

func setup(loader: DynamicTerrainLoader):
  terrain_loader = loader
  if terrain_loader:
    cache_size = terrain_loader.cache_size
    max_concurrent_downloads = terrain_loader.max_concurrent_downloads

# Public API with token support
func get_tile_data(tile_coords: Vector2i, zoom: int, layer_type: String) -> Resource:
  if layer_configs.has(layer_type) and layer_configs[layer_type].requires_token and not has_valid_token(layer_type):
    return null

  var tile_key = get_tile_key(tile_coords, zoom)
  if loaded_tiles.has(tile_key) and loaded_tiles[tile_key].has(layer_type):
    return loaded_tiles[tile_key][layer_type]
  return null

func get_all_tile_data(tile_coords: Vector2i, zoom: int) -> Dictionary:
  var tile_key = get_tile_key(tile_coords, zoom)
  if loaded_tiles.has(tile_key):
    return loaded_tiles[tile_key].duplicate()
  return {}

func has_tile_data(tile_coords: Vector2i, zoom: int, layer_type: String = "") -> bool:
  var tile_key = get_tile_key(tile_coords, zoom)
  if layer_type.is_empty():
    return loaded_tiles.has(tile_key)
  else:
    if layer_configs.has(layer_type) and layer_configs[layer_type].requires_token and not has_valid_token(layer_type):
      return false
    return loaded_tiles.has(tile_key) and loaded_tiles[tile_key].has(layer_type)

func preload_tile(tile_coords: Vector2i, zoom: int, layer_types: Array = []) -> void:
  if layer_types.is_empty():
    layer_types = get_enabled_layers()

  for layer_type in layer_types:
    if layer_configs.has(layer_type) and layer_configs[layer_type].enabled:
      queue_tile_download(tile_coords, zoom, layer_type)

# Utility functions
static func get_tile_key(tile_coords: Vector2i, zoom: int) -> String:
  return "%d_%d_%d" % [tile_coords.x, tile_coords.y, zoom]

static func get_download_key(tile_coords: Vector2i, zoom: int, layer_type: String) -> String:
  return "%d_%d_%d_%s" % [tile_coords.x, tile_coords.y, zoom, layer_type]

# Token management
func set_layer_token(layer_type: String, token: String):
  if layer_configs.has(layer_type):
    layer_configs[layer_type].token = token
    layer_configs[layer_type].last_token_refresh = Time.get_unix_time_from_system()
    print("Token set for layer: ", layer_type)

func get_layer_token(layer_type: String) -> String:
  if layer_configs.has(layer_type):
    return layer_configs[layer_type].token
  return ""

func has_valid_token(layer_type: String) -> bool:
  if not layer_configs.has(layer_type):
    return false

  var config = layer_configs[layer_type]
  if not config.requires_token:
    return true

  if config.token.is_empty():
    return false

  # Check if token needs refresh
  var current_time = Time.get_unix_time_from_system()
  if current_time - config.last_token_refresh > config.token_refresh_interval:
    return false

  return true

func refresh_layer_token(layer_type: String) -> bool:
  if not layer_configs.has(layer_type) or not layer_configs[layer_type].requires_token:
    return true

  if pending_token_refreshes.has(layer_type) and pending_token_refreshes[layer_type]:
    return false  # Refresh already in progress

  var config = layer_configs[layer_type]
  if config.token_refresh_url.is_empty():
    print("No refresh URL configured for layer: ", layer_type)
    return false

  pending_token_refreshes[layer_type] = true

  var url = config.token_refresh_url.replace("{token}", config.token)
  var http_request = HTTPRequest.new()
  add_child(http_request)

  var result = await _perform_token_refresh_request(http_request, url, layer_type)

  http_request.queue_free()
  pending_token_refreshes.erase(layer_type)

  return result

func _perform_token_refresh_request(http_request: HTTPRequest, url: String, layer_type: String) -> bool:
  var semaphore = Semaphore.new()
  var result_array = []

  call_deferred("_start_http_request", http_request, url, semaphore, result_array)
  semaphore.wait()

  if result_array[0] != HTTPRequest.RESULT_SUCCESS:
    print("Token refresh failed for layer ", layer_type, ": HTTP error ", result_array[0])
    token_refreshed.emit(layer_type, false)
    return false

  var response_code = result_array[1]
  var body = result_array[3] as PackedByteArray

  if response_code == 200:
    # Parse token from response (implementation depends on your auth service)
    var new_token = _parse_token_from_response(body, layer_type)
    if not new_token.is_empty():
      set_layer_token(layer_type, new_token)
      print("Token refreshed successfully for layer: ", layer_type)
      token_refreshed.emit(layer_type, true)
      return true
    else:
      print("Failed to parse new token for layer: ", layer_type)
      token_refreshed.emit(layer_type, false)
      return false
  else:
    print("Token refresh failed for layer ", layer_type, ": HTTP ", response_code)
    token_refreshed.emit(layer_type, false)
    return false

func _parse_token_from_response(body: PackedByteArray, layer_type: String) -> String:
  # This needs to be implemented based on your authentication service's response format
  # Example for JSON response: {"access_token": "xyz", "expires_in": 3600}

  var json = JSON.new()
  var error = json.parse(body.get_string_from_utf8())
  if error == OK:
    var data = json.data
    if typeof(data) == TYPE_DICTIONARY:
      # Adjust these keys based on your auth service
      if data.has("access_token"):
        return data["access_token"]
      elif data.has("token"):
        return data["token"]

  # If simple string token
  return body.get_string_from_utf8().strip_edges()

func _check_token_refresh():
  for layer_type in layer_configs:
    var config = layer_configs[layer_type]
    if config.requires_token and not config.token.is_empty():
      var current_time = Time.get_unix_time_from_system()
      if current_time - config.last_token_refresh > config.token_refresh_interval:
        print("Refreshing token for layer: ", layer_type)
        refresh_layer_token(layer_type)

# Layer management (updated with token checks)
func register_layer(config: TileLayerConfig):
  layer_configs[config.layer_type] = config
  # Set initial token refresh time if token is provided
  if not config.token.is_empty():
    config.last_token_refresh = Time.get_unix_time_from_system()

func unregister_layer(layer_type: String):
  layer_configs.erase(layer_type)

func set_layer_enabled(layer_type: String, enabled: bool):
  if layer_configs.has(layer_type):
    layer_configs[layer_type].enabled = enabled

func get_enabled_layers() -> Array:
  var enabled = []
  for layer_type in layer_configs:
    var config = layer_configs[layer_type]
    if config.enabled:
      # Check if layer requires and has valid token
      if config.requires_token and not has_valid_token(layer_type):
        print("Layer ", layer_type, " requires valid token but none available")
        continue
      enabled.append(layer_type)
  # Sort by priority (higher priority first)
  enabled.sort_custom(_sort_layers_by_priority)
  return enabled

func _sort_layers_by_priority(a: String, b: String) -> bool:
  return layer_configs[a].priority > layer_configs[b].priority

func queue_tile_downloads(tile_coords: Vector2i, zoom: int):
  var enabled_layers = get_enabled_layers()
  for layer_type in enabled_layers:
    queue_tile_download(tile_coords, zoom, layer_type)

func queue_tile_download(tile_coords: Vector2i, zoom: int, layer_type: String):
  if not layer_configs.has(layer_type) or not layer_configs[layer_type].enabled:
    return

  # Add this check for tile download
  if not is_valid_tile(tile_coords, zoom):
      print("Invalid tile coordinates: ", tile_coords, " at zoom: ", zoom)
      return

  # Check token requirement
  var config = layer_configs[layer_type]
  if config.requires_token and not has_valid_token(layer_type):
    print("Cannot queue download for ", layer_type, ": No valid token")
    # Try to refresh token if we have one but it's expired
    if not config.token.is_empty():
      refresh_layer_token(layer_type)
    return

  mutex.lock()

  var tile_key = get_tile_key(tile_coords, zoom)

  # Check if already loaded
  if loaded_tiles.has(tile_key) and loaded_tiles[tile_key].has(layer_type):
    mutex.unlock()
    return

  # Check if already in queue
  if is_tile_in_queue(tile_coords, zoom, layer_type):
    mutex.unlock()
    return

  # Check cache
  var cached_resource = load_tile_from_cache(tile_coords, zoom, layer_type)
  if cached_resource:
    if not loaded_tiles.has(tile_key):
      loaded_tiles[tile_key] = {}
    loaded_tiles[tile_key]["coords"] = tile_coords
    loaded_tiles[tile_key]["zoom"] = zoom
    loaded_tiles[tile_key][layer_type] = cached_resource
    update_tile_cache(tile_key, loaded_tiles[tile_key])
    mutex.unlock()

    # Notify about loaded tile
    call_deferred("_emit_tile_loaded", tile_coords, zoom, loaded_tiles[tile_key])
    return

  # Queue for download
  var queue_item = {
    "coords": tile_coords,
    "zoom": zoom,
    "layer_type": layer_type,
    "priority": layer_configs[layer_type].priority
  }

  # Insert based on priority (higher priority first)
  var insert_index = 0
  for i in range(download_queue.size()):
    if download_queue[i].priority < queue_item.priority:
      break
    insert_index = i + 1

  download_queue.insert(insert_index, queue_item)
  mutex.unlock()
  semaphore.post()

func is_valid_tile(tile_coords: Vector2i, zoom: int) -> bool:
    var tile_size = CoordinateConverter.get_tile_size_meters(zoom)
    # Check if tile is within Earth's boundaries
    if tile_coords.x < 0 or tile_coords.x >= (1 << zoom):
        return false
    if tile_coords.y < 0 or tile_coords.y >= (1 << zoom):
        return false
    return true

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

func is_tile_in_queue(coords: Vector2i, zoom: int, layer_type: String) -> bool:
  for tile in download_queue:
    if tile["coords"] == coords and tile["zoom"] == zoom and tile["layer_type"] == layer_type:
      return true
  return false

func process_tile_download(tile_data: Dictionary):
  var tile_coords = tile_data["coords"]
  var zoom = tile_data["zoom"]
  var layer_type = tile_data["layer_type"]
  var tile_key = get_tile_key(tile_coords, zoom)

  # Skip if already loaded
  mutex.lock()
  var already_loaded = loaded_tiles.has(tile_key) and loaded_tiles[tile_key].has(layer_type)
  mutex.unlock()

  if already_loaded:
    call_deferred("_emit_tile_loaded", tile_coords, zoom, loaded_tiles[tile_key])
    return

  # Check token again before downloading
  var config = layer_configs[layer_type]
  if config.requires_token and not has_valid_token(layer_type):
    print("Skipping download for ", layer_type, ": No valid token available")
    call_deferred("_emit_tile_load_failed", tile_coords, zoom, layer_type, "No valid token")
    return

  # Download the tile
  var resource = await download_tile_resource(tile_coords, zoom, layer_type)

  if resource:
    mutex.lock()
    if not loaded_tiles.has(tile_key):
      loaded_tiles[tile_key] = {}
    loaded_tiles[tile_key]["coords"] = tile_coords
    loaded_tiles[tile_key]["zoom"] = zoom
    loaded_tiles[tile_key][layer_type] = resource
    update_tile_cache(tile_key, loaded_tiles[tile_key])

    # Clear download attempts on success
    var download_key = get_download_key(tile_coords, zoom, layer_type)
    download_attempts.erase(download_key)
    mutex.unlock()

    # Notify about new tile
    call_deferred("_emit_tile_loaded", tile_coords, zoom, loaded_tiles[tile_key])
  else:
    # Handle download failure
    var download_key = get_download_key(tile_coords, zoom, layer_type)
    mutex.lock()
    if not download_attempts.has(download_key):
      download_attempts[download_key] = 0

    download_attempts[download_key] += 1
    var attempts = download_attempts[download_key]
    mutex.unlock()

    if attempts < download_retry_attempts:
      # Requeue with lower priority
      print("Retrying download (attempt %d/%d) for %s tile: %s" % [attempts, download_retry_attempts, layer_type, tile_coords])
      tile_data.priority = -1  # Low priority for retries
      mutex.lock()
      download_queue.append(tile_data)
      mutex.unlock()
      semaphore.post()
    else:
      print("Failed to download %s tile after %d attempts: %s" % [layer_type, attempts, tile_coords])
      call_deferred("_emit_tile_load_failed", tile_coords, zoom, layer_type, "Download failed after %d attempts" % attempts)

func download_tile_resource(tile_coords: Vector2i, zoom: int, layer_type: String) -> Resource:
  var config = layer_configs[layer_type]

  # Build URL with token if required
  var url = config.url_template
  if config.requires_token and not config.token.is_empty():
    url = url.replace("{token}", config.token)

  url = url.format({
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

  var result = result_array[0]
  var response_code = result_array[1]
  var body = result_array[3] as PackedByteArray

  # Handle token expiration
  if response_code == 401 and config.requires_token:
    print("Token expired for layer ", layer_type, ", attempting refresh...")
    if await refresh_layer_token(layer_type):
      # Token refreshed, retry the download
      return await download_tile_resource(tile_coords, zoom, layer_type)
    else:
      print("Failed to refresh token for layer ", layer_type)
      return null

  if result != HTTPRequest.RESULT_SUCCESS:
    print("Failed to download %s tile: %s Error: %d, HTTP: %d" % [layer_type, tile_coords, result, response_code])
    return null

  # Save the raw data to cache
  save_tile_to_cache(tile_coords, zoom, layer_type, body)

  # Load appropriate resource type based on file extension
  var resource = null
  match config.file_extension.to_lower():
    "png", "jpg", "jpeg", "webp":
      resource = _load_image_texture(body, config.file_extension)
    "bin", "raw":
      resource = _load_binary_data(body)
    _:
      resource = _load_image_texture(body, config.file_extension)  # Default to image

  if resource:
    print("Successfully downloaded %s tile: %s at zoom %d" % [layer_type, tile_coords, zoom])
  else:
    print("Failed to process downloaded data for %s tile: %s" % [layer_type, tile_coords])

  return resource

# Rest of the methods remain largely the same, but with token-aware enhancements...
func _load_image_texture(image_data: PackedByteArray, file_extension: String) -> Texture2D:
  var image = Image.new()
  var error = OK

  match file_extension.to_lower():
    "png":
      error = image.load_png_from_buffer(image_data)
    "jpg", "jpeg":
      error = image.load_jpg_from_buffer(image_data)
    "webp":
      error = image.load_webp_from_buffer(image_data)
    _:
      # Try PNG as default
      error = image.load_png_from_buffer(image_data)

  if error == OK:
    return ImageTexture.create_from_image(image)
  return null

func _load_binary_data(data: PackedByteArray) -> Resource:
  # Create a simple resource to hold binary data
  var binary_resource = Resource.new()
  binary_resource.set_meta("data", data)
  return binary_resource

# Cache management (unchanged but included for completeness)
func load_tile_from_cache(tile_coords: Vector2i, zoom: int, layer_type: String) -> Resource:
  if not layer_configs.has(layer_type):
    return null

  var cache_path = get_tile_cache_path(tile_coords, zoom, layer_type)
  var file = FileAccess.open(cache_path, FileAccess.READ)

  if file:
    var buffer = file.get_buffer(file.get_length())
    file.close()

    var config = layer_configs[layer_type]
    var resource = null

    match config.file_extension.to_lower():
      "png", "jpg", "jpeg", "webp":
        resource = _load_image_texture(buffer, config.file_extension)
      "bin", "raw":
        resource = _load_binary_data(buffer)
      _:
        resource = _load_image_texture(buffer, config.file_extension)

    if resource:
      print("Loaded %s tile from cache: %s at zoom %d" % [layer_type, tile_coords, zoom])
      return resource

  return null

func get_tile_cache_path(tile_coords: Vector2i, zoom: int, layer_type: String) -> String:
  var config = layer_configs[layer_type]
  return "user://tile_cache/%s/zoom_%d/%d/%d.%s" % [config.layer_type, zoom, tile_coords.x, tile_coords.y, config.file_extension]

func ensure_cache_directory(path: String):
  var dir_path = path.get_base_dir()
  if not DirAccess.dir_exists_absolute(dir_path):
    var error = DirAccess.make_dir_recursive_absolute(dir_path)
    if error != OK:
      print("Failed to create cache directory: ", dir_path, " Error: ", error)

func save_tile_to_cache(tile_coords: Vector2i, zoom: int, layer_type: String, data: PackedByteArray) -> bool:
  var cache_path = get_tile_cache_path(tile_coords, zoom, layer_type)

  # Ensure directory exists
  ensure_cache_directory(cache_path)

  var file = FileAccess.open(cache_path, FileAccess.WRITE)
  if file:
    file.store_buffer(data)
    file.close()
    print("Saved %s tile to cache: %s at zoom %d" % [layer_type, tile_coords, zoom])
    return true

  print("ERROR: Failed to save %s tile to cache: %s" % [layer_type, tile_coords])
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
    loaded_tiles.erase(removed.key)
    call_deferred("_emit_tile_unloaded", removed.data.coords, removed.data.zoom, removed.data)

func _emit_tile_unloaded(tile_coords: Vector2i, zoom: int, layer_data: Dictionary):
  tile_unloaded.emit(tile_coords, zoom, layer_data)

func _emit_tile_loaded(tile_coords: Vector2i, zoom: int, layer_data: Dictionary):
  tile_loaded.emit(tile_coords, zoom, layer_data)

func _emit_tile_load_failed(tile_coords: Vector2i, zoom: int, layer_type: String, error: String):
  tile_load_failed.emit(tile_coords, zoom, layer_type, error)

func _start_http_request(http_request: HTTPRequest, url: String, sem: Semaphore, result_array: Array):
  # Disconnect any existing connections to avoid duplicates
  if http_request.request_completed.is_connected(_on_http_request_completed):
    http_request.request_completed.disconnect(_on_http_request_completed)

  http_request.request_completed.connect(_on_http_request_completed.bind(sem, result_array))
  var error = http_request.request(url)
  if error != OK:
    result_array.append(error)
    result_array.append(0)  # response_code
    result_array.append([]) # headers
    result_array.append(PackedByteArray()) # body
    sem.post()

func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, sem: Semaphore, result_array: Array):
  result_array.append(result)
  result_array.append(response_code)
  result_array.append(headers)
  result_array.append(body)
  sem.post()

func cleanup():
  should_exit = true
  semaphore.post()

  if token_refresh_timer:
    token_refresh_timer.stop()

  if download_thread and download_thread.is_started():
    download_thread.wait_to_finish()

  for http_request in http_requests:
    if is_instance_valid(http_request):
      http_request.queue_free()
