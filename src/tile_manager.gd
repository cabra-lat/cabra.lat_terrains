# tile_manager.gd
@tool
class_name TileManager
extends Node

signal tile_loaded(tile_coords: Vector2i, zoom: int, layer_data: Dictionary)
signal tile_load_failed(tile_coords: Vector2i, zoom: int, layer_type: String, error: String)

# Layer configuration
class TileLayerConfig:
  var layer_type: String
  var url_template: String
  var file_extension: String
  var priority: int
  var enabled: bool

  func _init(type: String, url: String, extension: String = "png", prio: int = 0, enabled_by_default: bool = true):
    layer_type = type
    url_template = url
    file_extension = extension
    priority = prio
    enabled = enabled_by_default

# Configuration
@export var max_concurrent_downloads: int = 2
@export var cache_size: int = 25
@export var download_timeout: float = 30.0
@export var max_retry_attempts: int = 3

# Internal state
var layer_configs: Dictionary = {}
var loaded_tiles: Dictionary = {}
var tile_cache: Array = []
var download_queue: Array = []
var active_downloads: int = 0
var download_threads: Array = []
var should_exit: bool = false
var queue_mutex: Mutex
var queue_semaphore: Semaphore

func _ready() -> void:
  # Setup default layers
  register_layer(TileLayerConfig.new("heightmap",
    "https://elevation-tiles-prod.s3.amazonaws.com/terrarium/{z}/{x}/{y}.png", "png", 2))
  register_layer(TileLayerConfig.new("normal",
    "https://elevation-tiles-prod.s3.amazonaws.com/normal/{z}/{x}/{y}.png", "png", 1))
  register_layer(TileLayerConfig.new("satellite",
    "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
    "jpg", 0))
  register_layer(TileLayerConfig.new("googlemt",
    "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}", "jpg", 0))

  # Initialize threading only if not in editor (editor doesn't like threads)
  if not Engine.is_editor_hint():
    queue_mutex = Mutex.new()
    queue_semaphore = Semaphore.new()

    # Start download threads
    for i in range(max_concurrent_downloads):
      var thread = Thread.new()
      thread.start(_download_worker)
      download_threads.append(thread)

    print("TileManager: Started %d download threads" % max_concurrent_downloads)
  else:
    print("TileManager: Running in editor mode (single-threaded)")

func _process(_delta: float) -> void:
  # In editor, process downloads on main thread
  if Engine.is_editor_hint() and download_queue.size() > 0 and active_downloads < max_concurrent_downloads:
    var task = download_queue.pop_front()
    _process_download_editor(task)

func _exit_tree() -> void:
  should_exit = true

  # Signal threads to exit
  if not Engine.is_editor_hint():
    for i in range(download_threads.size()):
      queue_semaphore.post()

    # Wait for threads to finish
    for thread in download_threads:
      if thread.is_started():
        thread.wait_to_finish()

  print("TileManager: Shutdown complete")

# Public API
func register_layer(config: TileLayerConfig) -> void:
  layer_configs[config.layer_type] = config

func get_tile_data(tile_coords: Vector2i, zoom: int, layer_type: String) -> Resource:
  if not layer_configs.has(layer_type):
    return null

  var tile_key = _get_tile_key(tile_coords, zoom)

  # Check memory cache
  if loaded_tiles.has(tile_key) and loaded_tiles[tile_key].has(layer_type):
    return loaded_tiles[tile_key][layer_type]

  # Check disk cache
  var cached_data = _load_from_cache(tile_coords, zoom, layer_type)
  if cached_data:
    var resource = _create_resource_from_data(cached_data, layer_type)
    if resource:
      if not loaded_tiles.has(tile_key):
        loaded_tiles[tile_key] = {}
      loaded_tiles[tile_key][layer_type] = resource
      _update_tile_cache(tile_key, loaded_tiles[tile_key])
      return resource

  return null

func has_tile_data(tile_coords: Vector2i, zoom: int, layer_type: String = "") -> bool:
  if layer_type.is_empty():
    var tile_key = _get_tile_key(tile_coords, zoom)
    return loaded_tiles.has(tile_key)
  else:
    return get_tile_data(tile_coords, zoom, layer_type) != null

func queue_tile_download(tile_coords: Vector2i, zoom: int, layer_type: String) -> void:
  if not layer_configs.has(layer_type) or not layer_configs[layer_type].enabled:
    return

  # Check if already loaded
  var tile_key = _get_tile_key(tile_coords, zoom)
  if loaded_tiles.has(tile_key) and loaded_tiles[tile_key].has(layer_type):
    return

  # Check cache first
  var cached_data = _load_from_cache(tile_coords, zoom, layer_type)
  if cached_data:
    var resource = _create_resource_from_data(cached_data, layer_type)
    if resource:
      if not loaded_tiles.has(tile_key):
        loaded_tiles[tile_key] = {}
      loaded_tiles[tile_key][layer_type] = resource
      _update_tile_cache(tile_key, loaded_tiles[tile_key])
      tile_loaded.emit(tile_coords, zoom, loaded_tiles[tile_key])
      return

  # Check if already in queue
  if _is_tile_in_queue(tile_coords, zoom, layer_type):
    return

  # Create download task
  var config = layer_configs[layer_type]
  var task = {
    "coords": tile_coords,
    "zoom": zoom,
    "layer_type": layer_type,
    "url": _build_url(config.url_template, tile_coords, zoom),
    "priority": config.priority,
    "attempts": 0
  }

  # Add to queue based on priority
  if Engine.is_editor_hint():
    # In editor, just add to queue (processed in _process)
    download_queue.append(task)
  else:
    # At runtime, use threaded queue
    queue_mutex.lock()

    var insert_index = 0
    for i in range(download_queue.size()):
      if download_queue[i].priority < task.priority:
        break
      insert_index = i + 1

    download_queue.insert(insert_index, task)
    queue_mutex.unlock()
    queue_semaphore.post()

  print("Queued download: %s zoom %d %s" % [tile_coords, zoom, layer_type])

# Thread worker function
func _download_worker() -> void:
  while not should_exit:
    queue_semaphore.wait()
    if should_exit:
      break

    queue_mutex.lock()
    if download_queue.size() == 0:
      queue_mutex.unlock()
      continue

    var task = download_queue.pop_front()
    queue_mutex.unlock()

    _process_download(task)

func _process_download_editor(task: Dictionary) -> void:
  active_downloads += 1
  _process_download(task)
  active_downloads -= 1

func _process_download(task: Dictionary) -> void:
  var result = await _download_tile(task)

  if result.success:
    call_deferred("_handle_download_success", task, result.data)
  else:
    call_deferred("_handle_download_failure", task, result.error)

func _download_tile(task: Dictionary) -> Dictionary:
  var result = {
    "success": false,
    "data": PackedByteArray(),
    "error": ""
  }

  var http_request = HTTPRequest.new()

  # We need to add to scene tree to work
  if Engine.is_editor_hint():
    get_tree().root.add_child(http_request)
  else:
    call_deferred("add_child", http_request)

  # Wait for the request to be ready
  await get_tree().process_frame

  # Download the tile
  var error = http_request.request(task.url)
  if error != OK:
    result.error = "Failed to start HTTP request: %d" % error
    http_request.queue_free()
    return result

  # Wait for download to complete
  var response = await http_request.request_completed

  http_request.queue_free()

  var response_code = response[1]
  var body = response[3] as PackedByteArray

  if response_code != 200:
    result.error = "HTTP Error: %d" % response_code
    return result

  result.success = true
  result.data = body
  return result

func _handle_download_success(task: Dictionary, data: PackedByteArray) -> void:
  print("Download completed: %s zoom %d %s (%d bytes)" % [task.coords, task.zoom, task.layer_type, data.size()])

  # Save to cache
  _save_to_cache(task.coords, task.zoom, task.layer_type, data)

  # Create resource
  var resource = _create_resource_from_data(data, task.layer_type)
  if resource:
    var tile_key = _get_tile_key(task.coords, task.zoom)
    if not loaded_tiles.has(tile_key):
      loaded_tiles[tile_key] = {}

    loaded_tiles[tile_key]["coords"] = task.coords
    loaded_tiles[tile_key]["zoom"] = task.zoom
    loaded_tiles[tile_key][task.layer_type] = resource

    _update_tile_cache(tile_key, loaded_tiles[tile_key])

    tile_loaded.emit(task.coords, task.zoom, loaded_tiles[tile_key])
  else:
    tile_load_failed.emit(task.coords, task.zoom, task.layer_type, "Failed to create resource from downloaded data")

func _handle_download_failure(task: Dictionary, error: String) -> void:
  print("Download failed: %s zoom %d %s - %s" % [task.coords, task.zoom, task.layer_type, error])

  # Handle retries
  if task.attempts < max_retry_attempts:
    print("Retrying download (%d/%d): %s" % [task.attempts + 1, max_retry_attempts, task.coords])

    task.attempts += 1

    if Engine.is_editor_hint():
      download_queue.append(task)
    else:
      queue_mutex.lock()
      download_queue.append(task)
      queue_mutex.unlock()
      queue_semaphore.post()
  else:
    tile_load_failed.emit(task.coords, task.zoom, task.layer_type,
      "Failed after %d attempts: %s" % [max_retry_attempts, error])

func _is_tile_in_queue(tile_coords: Vector2i, zoom: int, layer_type: String) -> bool:
  for task in download_queue:
    if task.coords == tile_coords and task.zoom == zoom and task.layer_type == layer_type:
      return true
  return false

# Resource creation
func _create_resource_from_data(data: PackedByteArray, layer_type: String) -> Resource:
  var config = layer_configs[layer_type]
  if not config:
    return null

  match config.file_extension.to_lower():
    "png", "jpg", "jpeg", "webp":
      var image = Image.new()
      var error = OK

      match config.file_extension.to_lower():
        "png":
          error = image.load_png_from_buffer(data)
        "jpg", "jpeg":
          error = image.load_jpg_from_buffer(data)
        "webp":
          error = image.load_webp_from_buffer(data)
        _:
          # Try PNG as default
          error = image.load_png_from_buffer(data)

      if error == OK:
        return ImageTexture.create_from_image(image)

    "bin", "raw":
      var binary_resource = Resource.new()
      binary_resource.set_meta("binary_data", data)
      return binary_resource

  return null

# Cache management
func _get_tile_key(tile_coords: Vector2i, zoom: int) -> String:
  return "%d_%d_%d" % [tile_coords.x, tile_coords.y, zoom]

func _build_url(template: String, tile_coords: Vector2i, zoom: int) -> String:
  return template.format({
    "x": tile_coords.x,
    "y": tile_coords.y,
    "z": zoom
  })

func _get_cache_path(tile_coords: Vector2i, zoom: int, layer_type: String) -> String:
  var config = layer_configs[layer_type]
  if not config:
    return ""

  return "user://tile_cache/%s/zoom_%d/%d/%d.%s" % [
    layer_type, zoom, tile_coords.x, tile_coords.y, config.file_extension
  ]

func _ensure_cache_directory(cache_path: String) -> bool:
  var dir_path = cache_path.get_base_dir()
  if not DirAccess.dir_exists_absolute(dir_path):
    var err = DirAccess.make_dir_recursive_absolute(dir_path)
    if err != OK:
      print("ERROR: Failed to create cache directory: ", dir_path)
      return false
  return true

func _save_to_cache(tile_coords: Vector2i, zoom: int, layer_type: String, data: PackedByteArray) -> bool:
  var cache_path = _get_cache_path(tile_coords, zoom, layer_type)
  if cache_path.is_empty():
    return false

  if not _ensure_cache_directory(cache_path):
    return false

  var file = FileAccess.open(cache_path, FileAccess.WRITE)
  if file:
    file.store_buffer(data)
    file.close()
    return true

  return false

func _load_from_cache(tile_coords: Vector2i, zoom: int, layer_type: String) -> PackedByteArray:
  var cache_path = _get_cache_path(tile_coords, zoom, layer_type)
  if cache_path.is_empty() or not FileAccess.file_exists(cache_path):
    return PackedByteArray()

  var file = FileAccess.open(cache_path, FileAccess.READ)
  if file:
    var data = file.get_buffer(file.get_length())
    file.close()
    return data

  return PackedByteArray()

func _update_tile_cache(tile_key: String, tile_data: Dictionary) -> void:
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

# Utility functions
func cancel_all_downloads() -> void:
  if Engine.is_editor_hint():
    download_queue.clear()
  else:
    queue_mutex.lock()
    download_queue.clear()
    queue_mutex.unlock()

  print("Cancelled all downloads")

func get_active_download_count() -> int:
  return active_downloads

func get_queued_download_count() -> int:
  return download_queue.size()

func cleanup() -> void:
  cancel_all_downloads()
