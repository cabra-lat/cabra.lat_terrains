class_name HeightSampler

static func get_height_data(texture) -> PackedFloat32Array:
    var image = texture.get_image() if texture is Texture2D else texture as Image

    var size = image.get_size()
    var height_data = PackedFloat32Array()
    height_data.resize(size.x * size.y)

    # Convert all pixels to height values
    var index = 0
    for z in range(size.y):
        for x in range(size.x):
            var color = image.get_pixel(x, z)
            height_data[index] = HeightSampler.decode_height_from_color(color)
            index += 1
    return height_data

static func sample_height(texture: Texture2D, percent: float = 0.05) -> Vector2:
    var height_data = get_height_data(texture)
    # Sort the height data
    height_data.sort()

    # Calculate the window (exclude top and bottom 0.05%)
    var exclude_count = floor(height_data.size() * percent / 100.0)
    var start_idx = exclude_count
    var end_idx = height_data.size() - exclude_count

    # Extract windowed data
    var windowed_data = height_data.slice(start_idx, end_idx)

    # Get min/max from windowed data
    var min_height = windowed_data[0]
    var max_height = windowed_data[windowed_data.size() - 1]

    return Vector2(min_height, max_height)

#static func sample_height_at_position(texture: Texture2D, world_pos: Vector3, tile_coords: Vector2i, zoom: int) -> float:
    #var image = texture.get_image()
    #var tile_size = CoordinateConverter.get_tile_size_meters(zoom)
#
    ## Get tile corner position relative to spawn
    #var tile_corner = CoordinateConverter.get_precise_world_pos(tile_coords, zoom)
#
    ## Calculate UVs relative to tile corner
    #var u = (world_pos.x - tile_corner.x) / tile_size
    #var v = (world_pos.z - tile_corner.z) / tile_size
#
    #u = clamp(u, 0.0, 1.0)
    #v = clamp(v, 0.0, 1.0)
#
    #return sample_height_bilinear(image, u, v)

static func sample_height_at_uv(texture: Texture2D, u: float, v: float) -> float:
    if not texture or not texture.get_image():
        return 0.0

    var image = texture.get_image()
    if image.is_empty():
        return 0.0

    return sample_height_bilinear(image, u, v)

static func sample_height_bilinear(image: Image, u: float, v: float) -> float:
    var width = image.get_width()
    var height = image.get_height()

    # Convert UV to image coordinates
    # Note: In images, (0,0) is top-left, but in UV (0,0) is bottom-left
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

    var x_factor = x - x1
    var y_factor = y - y1

    var top = lerp(q11, q21, x_factor)
    var bottom = lerp(q12, q22, x_factor)

    return lerp(top, bottom, y_factor)

static func decode_height_from_color(color: Color) -> float:
    var r = floor(color.r * 255.0)
    var g = floor(color.g * 255.0)
    var b = floor(color.b * 255.0)
    return floor((r * 256.0 + g + b / 256.0) - 32768.0)
