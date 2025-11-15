class_name CoordinateConverter

const EARTH_CIRCUMFERENCE: float = 40075000.0

static func get_tile_center_world_pos(tile_coords: Vector2i, zoom: int, start_lat: float, start_lon: float) -> Vector3:
    var tile_corner = tile_to_world(tile_coords, zoom)
    var tile_size = get_tile_size_meters(zoom)
    var origin = lat_lon_to_world(start_lat, start_lon, zoom)

    # Center the tile and make relative to origin
    return tile_corner - origin + Vector3(tile_size / 2, 0, tile_size / 2)

static func tile_to_lat_lon(tile_coords: Vector2i, zoom: int) -> Vector2:
    var world_coords = tile_to_world(tile_coords, zoom)
    return world_to_lat_lon(world_coords)

static func tile_to_world(tile_coords: Vector2i, zoom: int) -> Vector3:
    # Get tile size for current zoom level
    var tile_size = get_tile_size_meters(zoom)

    # Calculate world position
    var world_x = tile_coords.x * tile_size
    var world_z = tile_coords.y * tile_size

    # Center the tile (so center of tile is at position)
    return Vector3(world_x, 0, world_z)

# In coordinate_converter.gd
static func world_to_tile(world_pos: Vector3, zoom: int) -> Vector2i:
    var tile_size = get_tile_size_meters(zoom)
    var tile_offset_x = int(floor(world_pos.x / tile_size))
    var tile_offset_y = int(floor(world_pos.z / tile_size))
    return Vector2i(tile_offset_x, tile_offset_y)

static func world_to_lat_lon(world_pos: Vector3, start_lat: float = 0.0, start_lon: float = 0.0) -> Vector2:
    var meters_per_degree_lat = 111000.0
    var meters_per_degree_lon = 111000.0 * cos(deg_to_rad(start_lat))

    var lat = start_lat - (world_pos.z / meters_per_degree_lat)
    var lon = start_lon + (world_pos.x / meters_per_degree_lon)
    return Vector2(lat, lon)

static func lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Vector2i:
    var n = pow(2.0, zoom)
    var x_tile = int((lon + 180.0) / 360.0 * n)
    var lat_rad = deg_to_rad(lat)
    var y_tile = int((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n)
    return Vector2i(x_tile, y_tile)

static func lat_lon_to_world(lat: float, lon: float, zoom: int) -> Vector3:
    var tile_coords = lat_lon_to_tile(lat, lon, zoom)
    return tile_to_world(tile_coords, zoom)

static func get_tile_size_meters(zoom: int) -> float:
    return EARTH_CIRCUMFERENCE / pow(2.0, zoom)
