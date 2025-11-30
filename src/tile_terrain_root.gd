
@tool
extends Node3D
class_name TileTerrainRoot

# User-friendly lat/lon inputs
@export var centre_latitude: float = -15.708 : set = _set_centre_latitude
@export var centre_longitude: float = -48.56 : set = _set_centre_longitude
@export var zoom: int = 18 : set = _set_zoom
@export var layer: String = "googlemt" : set = _set_layer
@export_range(1, 100, 2) var grid_radius: int = 3 : set = _set_grid_radius
@export var add_collision: bool = true : set = _set_add_collision

# Use a simpler, direct initialization syntax:
@export_tool_button("Update") var _button_action: Callable

# Internal tile coordinates
var centre_tile: Vector2i = Vector2i.ZERO
var tile_manager: TileManager

# Proper setters for TileTerrainRoot
func _set_centre_latitude(value: float) -> void:
    centre_latitude = value
    CoordinateConverter.set_origin_from_tile(centre_tile, zoom)

func _set_centre_longitude(value: float) -> void:
    centre_longitude = value
    CoordinateConverter.set_origin_from_tile(centre_tile, zoom)

func _set_zoom(value: int) -> void:
    zoom = value
    CoordinateConverter.set_origin_from_tile(centre_tile, zoom)

func _set_layer(value: String) -> void:
    layer = value

func _set_grid_radius(value: int) -> void:
    grid_radius = value

func _set_add_collision(value: bool) -> void:
    add_collision = value

func _update_centre_tile():
    # Convert lat/lon to tile coordinates
    centre_tile = CoordinateConverter.lat_lon_to_tile(centre_latitude, centre_longitude, zoom)
    print("Centre coordinates: lat=", centre_latitude, " lon=", centre_longitude, " -> tile=", centre_tile)
    CoordinateConverter.set_origin_from_tile(centre_tile, zoom)
    if Engine.is_editor_hint() and is_inside_tree():
        call_deferred("_build")

func _enter_tree():
    # Initialize the Callable safely here
    _button_action = Callable(self, "_update_centre_tile")

func _ready() -> void:
    _update_centre_tile()

    # Create TileManager with threaded downloader
    if not is_instance_valid(tile_manager):
        tile_manager = TileManager.new()
        tile_manager.max_concurrent_downloads = 2  # Conservative for editor
        add_child(tile_manager)
        tile_manager.name = "TileManager"

    call_deferred("_build")

func _build(_v = null) -> void:
    if not is_inside_tree():
        return

    print("Building terrain grid with radius: ", grid_radius)
    print("Centre tile: ", centre_tile, " at zoom: ", zoom)

    # Clear previous (but keep TileManager if it exists)
    for c in get_children():
        if c != tile_manager:
            remove_child(c)
            c.queue_free()

    # Get the actual tile size for this zoom level
    var tile_size = CoordinateConverter.get_tile_size_meters(zoom)
    print("Tile size at zoom ", zoom, ": ", tile_size, " meters")

    # Preload zoom 15 tiles for the entire area (if we're at zoom 18)
    if zoom == 18:
        _preload_zoom15_tiles(centre_tile, grid_radius)

    # Debug: Track tile positions
    var tile_positions = []
    var created_tiles = 0

    for dy in range(-grid_radius, grid_radius + 1):
        for dx in range(-grid_radius, grid_radius + 1):
            var tile := centre_tile + Vector2i(dx, dy)

            # Check if tile coordinates are valid
            var max_tile = 1 << zoom
            if tile.x < 0 or tile.x >= max_tile or tile.y < 0 or tile.y >= max_tile:
                print("Skipping invalid tile: ", tile, " (max tile: ", max_tile - 1, ")")
                continue

            print("Creating tile ", tile)

            var tile_root := StaticBody3D.new()
            tile_root.name = "tile_%d_%d" % [tile.x, tile.y]

            if add_collision:
                var col := CollisionShape3D.new()
                tile_root.add_child(col)

            var mesh := TileTerrainTile.new()

            # Set properties using tile coordinates
            mesh.tile_x = tile.x
            mesh.tile_y = tile.y
            mesh.zoom_level = zoom
            mesh.layer_type = layer
            mesh.terrain_scale = tile_size  # Set to actual tile size

            # Pass the tile_manager reference directly
            if is_instance_valid(tile_manager):
                mesh.tile_manager = tile_manager

            # Calculate world position using CoordinateConverter
            var world_pos = CoordinateConverter.tile_to_world(tile, zoom)
            print("Tile ", tile, " world position: ", world_pos)

            # Track position for debugging
            tile_positions.append({
                "tile": tile,
                "position": world_pos,
                "dx": dx,
                "dy": dy
            })

            # Set position
            mesh.position = world_pos

            # Add to scene tree AFTER setting all properties
            tile_root.add_child(mesh)
            add_child(tile_root)
            created_tiles += 1

            # Only set owner if we're in the editor and have a valid scene root
            if Engine.is_editor_hint() and is_inside_tree() and get_tree().edited_scene_root != null:
                pass
                #tile_root.owner = get_tree().edited_scene_root
                #mesh.owner = get_tree().edited_scene_root
                #for child in tile_root.get_children():
                #    child.owner = get_tree().edited_scene_root
    _check_download_status()
    # Debug: Print tile positions in a grid format
    print("=== TILE POSITIONS GRID ===")
    for dy in range(-grid_radius, grid_radius + 1):
        var row = ""
        for dx in range(-grid_radius, grid_radius + 1):
            var found = false
            for pos in tile_positions:
                if pos.dx == dx and pos.dy == dy:
                    row += "[X] "
                    found = true
                    break
            if not found:
                row += "[ ] "
        print("Row dy=", dy, ": ", row)
    print("===========================")

    print("Created ", created_tiles, " tiles out of ", pow(grid_radius * 2 + 1, 2), " expected")

func _preload_zoom15_tiles(centre_tile: Vector2i, radius: int):
    print("Preloading zoom 15 tiles...")

    # Calculate the zoom 15 tile range
    var min_x15 = (centre_tile.x - radius) >> 3
    var max_x15 = (centre_tile.x + radius) >> 3
    var min_y15 = (centre_tile.y - radius) >> 3
    var max_y15 = (centre_tile.y + radius) >> 3

    # Preload heightmap and normalmap tiles at zoom 15
    for y in range(min_y15, max_y15 + 1):
        for x in range(min_x15, max_x15 + 1):
            var tile_15 = Vector2i(x, y)

            # Check if we already have the tiles
            if not tile_manager.has_tile_data(tile_15, 15, "heightmap"):
                tile_manager.queue_tile_download(tile_15, 15, "heightmap")
                print("Queued heightmap download for zoom15 tile: ", tile_15)

            if not tile_manager.has_tile_data(tile_15, 15, "normal"):
                tile_manager.queue_tile_download(tile_15, 15, "normal")
                print("Queued normalmap download for zoom15 tile: ", tile_15)

    print("Finished preloading zoom 15 tiles")

# In TileTerrainRoot
func get_centre_lat_lon() -> Vector2:
    return CoordinateConverter.tile_to_lat_lon(centre_tile, zoom)

func get_tile_coordinates() -> Vector2i:
    return centre_tile

func _check_download_status():
    print("=== DOWNLOAD STATUS ===")
    for dy in range(-grid_radius, grid_radius + 1):
        for dx in range(-grid_radius, grid_radius + 1):
            var tile := centre_tile + Vector2i(dx, dy)
            var has_albedo = tile_manager.has_tile_data(tile, zoom, "googlemt")
            var status = "LOADED" if has_albedo else "MISSING"
            print("Tile ", tile, " (dx=", dx, ", dy=", dy, "): ", status)
    print("======================")
