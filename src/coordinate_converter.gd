class_name CoordinateConverter

const EARTH_CIRCUMFERENCE: float = 40075000.0

static func world_to_tile_coords(world_position: Vector3, start_lat: float, start_lon: float, zoom: int) -> Vector2i:
    var lat_lon = world_to_lat_lon(world_position, start_lat, start_lon)
    return lat_lon_to_tile(lat_lon.x, lat_lon.y, zoom)

static func world_to_lat_lon(world_pos: Vector3, start_lat: float, start_lon: float) -> Vector2:
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

static func get_tile_size_meters(zoom: int) -> float:
    return EARTH_CIRCUMFERENCE / pow(2.0, zoom)
