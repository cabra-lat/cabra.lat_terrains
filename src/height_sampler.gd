class_name HeightSampler

static func sample_height_at_position(texture: Texture2D, world_pos: Vector3, zoom: int) -> float:
    var image = texture.get_image()
    var tile_size = CoordinateConverter.get_tile_size_meters(zoom)

    # FIXED: Convert world position to UV coordinates correctly
    # The mesh is centered at (0,0,0) and spans from -tile_size/2 to tile_size/2
    var u = (world_pos.x + tile_size / 2) / tile_size
    var v = (world_pos.z + tile_size / 2) / tile_size

    u = clamp(u, 0.0, 1.0)
    v = clamp(v, 0.0, 1.0)

    # Debug sampling
    #print("Height sampling - World: ", world_pos, " UV: (", u, ", ", v, ")")

    return sample_height_bilinear(image, u, v)

static func sample_height_at_uv(texture: Texture2D, u: float, v: float) -> float:
    var image = texture.get_image()
    return sample_height_bilinear(image, u, v)

static func sample_height_bilinear(image: Image, u: float, v: float) -> float:
    var width = image.get_width()
    var height = image.get_height()

    # Convert UV to image coordinates
    # Note: In images, (0,0) is top-left, but in UV (0,0) is bottom-left
    var x = u * (width - 1)
    var y = (1.0 - v) * (height - 1)  # Flip V coordinate for image sampling

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
    var r = color.r * 255.0
    var g = color.g * 255.0
    var b = color.b * 255.0
    return (r * 256.0 + g + b / 256.0) - 32768.0

# Debug function to verify coordinate mapping
static func debug_coordinate_mapping(texture: Texture2D, tile_size: float):
    var image = texture.get_image()
    print("=== COORDINATE MAPPING DEBUG ===")
    print("Image size: ", image.get_size())
    print("Tile size: ", tile_size, "m")

    var test_points = [
        {"uv": Vector2(0.0, 0.0), "world": Vector3(-tile_size/2, 0, -tile_size/2), "label": "Bottom-Left"},
        {"uv": Vector2(1.0, 0.0), "world": Vector3(tile_size/2, 0, -tile_size/2), "label": "Bottom-Right"},
        {"uv": Vector2(0.0, 1.0), "world": Vector3(-tile_size/2, 0, tile_size/2), "label": "Top-Left"},
        {"uv": Vector2(1.0, 1.0), "world": Vector3(tile_size/2, 0, tile_size/2), "label": "Top-Right"}
    ]

    for point in test_points:
        var height = sample_height_at_uv(texture, point.uv.x, point.uv.y)
        print("  ", point.label)
        print("    UV: ", point.uv, " -> Height: ", height, "m")
        print("    World: ", point.world)
