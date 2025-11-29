class_name CoordinateConverter

const EARTH_CIRCUMFERENCE: float = 40075000.0
const TILE_PIXEL_RESOLUTION: int = 256

static var origin_tile: Vector2i = Vector2i(0, 0)
static var origin_set: bool = false

# Set origin from tile coordinates
static func set_origin_from_tile(tile: Vector2i, zoom: int):
    origin_tile = tile
    origin_set = true
    print("Coordinate origin set to tile: ", tile, " at zoom: ", zoom)

# Set origin from lat/lon coordinates
static func set_origin_from_lat_lon(lat: float, lon: float, zoom: int):
    origin_tile = lat_lon_to_tile(lat, lon, zoom)
    origin_set = true
    print("Coordinate origin set to lat=", lat, " lon=", lon, " -> tile=", origin_tile, " at zoom: ", zoom)

static func tile_to_world(tile_coords: Vector2i, zoom: int) -> Vector3:
    if not origin_set:
        push_error("Coordinate origin not set! Call CoordinateConverter.set_origin_from_tile() or set_origin_from_lat_lon() first.")
        return Vector3.ZERO

    var tile_size = get_tile_size_meters(zoom)

    # Calculate position relative to origin tile
    var dx = tile_coords.x - origin_tile.x
    var dy = tile_coords.y - origin_tile.y

    var world_pos = Vector3(dx * tile_size, 0, dy * tile_size)

    print("tile_to_world: tile=%s, origin_tile=%s, dx=%d, dy=%d, tile_size=%.2f -> world_pos=%s" %
          [tile_coords, origin_tile, dx, dy, tile_size, world_pos])

    return world_pos

static func get_tile_size_meters(zoom: int) -> float:
    return EARTH_CIRCUMFERENCE / pow(2.0, zoom)

# Convert lat/lon to tile coordinates
static func lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Vector2i:
    var n = pow(2.0, zoom)
    var x_tile = int((lon + 180.0) / 360.0 * n)
    var lat_rad = deg_to_rad(lat)
    var y_tile = int((1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / PI) / 2.0 * n)
    return Vector2i(x_tile, y_tile)

# Convert tile coordinates to lat/lon
static func tile_to_lat_lon(tile_coords: Vector2i, zoom: int) -> Vector2:
    var n = pow(2.0, zoom)
    var x = tile_coords.x
    var y = tile_coords.y

    # Convert tile coordinates to lat/lon using the inverse of the Web Mercator projection
    var lon_deg = x / n * 360.0 - 180.0
    var lat_rad = atan(sinh(PI * (1.0 - 2.0 * y / n)))
    var lat_deg = rad_to_deg(lat_rad)

    return Vector2(lat_deg, lon_deg)

# Debug function to verify conversions
static func debug_coordinate_conversion(lat: float, lon: float, zoom: int):
    var tile = lat_lon_to_tile(lat, lon, zoom)
    var converted_lat_lon = tile_to_lat_lon(tile, zoom)

    print("=== COORDINATE CONVERSION DEBUG ===")
    print("Original: lat=%.6f, lon=%.6f" % [lat, lon])
    print("Tile: %s at zoom %d" % [tile, zoom])
    print("Converted back: lat=%.6f, lon=%.6f" % [converted_lat_lon.x, converted_lat_lon.y])
    print("Error: lat=%.6f, lon=%.6f" % [abs(lat - converted_lat_lon.x), abs(lon - converted_lat_lon.y)])
    print("===================================")
