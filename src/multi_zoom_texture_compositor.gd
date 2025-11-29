@tool
class_name MultiZoomTextureCompositor
extends RefCounted

static func get_heightmap_for_tile(tile_coords: Vector2i, tile_manager: TileManager) -> Texture2D:
    var zoom15_tile = _get_zoom15_tile_coords(tile_coords)
    var heightmap = tile_manager.get_tile_data(zoom15_tile, 15, "heightmap")

    if heightmap and heightmap is Texture2D:
        print("Found heightmap for zoom15 tile: ", zoom15_tile)
        return _extract_zoom18_region_from_zoom15(heightmap, tile_coords)
    else:
        print("No heightmap found for zoom15 tile: ", zoom15_tile)
        # Queue download
        tile_manager.queue_tile_download(zoom15_tile, 15, "heightmap")
        return null

static func get_normalmap_for_tile(tile_coords: Vector2i, tile_manager: TileManager) -> Texture2D:
    var zoom15_tile = _get_zoom15_tile_coords(tile_coords)
    var normalmap = tile_manager.get_tile_data(zoom15_tile, 15, "normal")

    if normalmap and normalmap is Texture2D:
        print("Found normalmap for zoom15 tile: ", zoom15_tile)
        return _extract_zoom18_region_from_zoom15(normalmap, tile_coords)
    else:
        print("No normalmap found for zoom15 tile: ", zoom15_tile)
        # Queue download
        tile_manager.queue_tile_download(zoom15_tile, 15, "normal")
        return null

static func _get_zoom15_tile_coords(zoom18_tile: Vector2i) -> Vector2i:
    # Each zoom15 tile covers 8x8 zoom18 tiles (2^(18-15) = 8)
    return Vector2i(zoom18_tile.x >> 3, zoom18_tile.y >> 3)

static func _extract_zoom18_region_from_zoom15(zoom15_texture: Texture2D, zoom18_tile: Vector2i) -> Texture2D:
    if not zoom15_texture or not is_instance_valid(zoom15_texture):
        print("ERROR: Zoom15 texture is invalid for tile ", zoom18_tile)
        return null

    var zoom15_image = zoom15_texture.get_image()
    if not zoom15_image or zoom15_image.is_empty():
        print("ERROR: Zoom15 image is invalid for tile ", zoom18_tile)
        return null

    var zoom15_size = zoom15_image.get_size()

    # Calculate which 1/8th section of the zoom15 tile this zoom18 tile corresponds to
    var sub_tile_x = zoom18_tile.x % 8
    var sub_tile_y = zoom18_tile.y % 8

    # Each zoom18 tile is 1/8 of the zoom15 tile in each dimension
    var region_width = zoom15_size.x / 8
    var region_height = zoom15_size.y / 8

    # Validate region bounds
    if region_width <= 0 or region_height <= 0:
        print("ERROR: Invalid region size for tile ", zoom18_tile, ": ", region_width, "x", region_height)
        return null

    var region_start_x = sub_tile_x * region_width
    var region_start_y = sub_tile_y * region_height

    # Ensure region is within bounds
    if region_start_x + region_width > zoom15_size.x or region_start_y + region_height > zoom15_size.y:
        print("ERROR: Region out of bounds for tile ", zoom18_tile)
        return null

    var region = Rect2i(region_start_x, region_start_y, region_width, region_height)

    # Extract the region
    var region_image = zoom15_image.get_region(region)
    if not region_image or region_image.is_empty():
        print("ERROR: Failed to extract region for tile ", zoom18_tile)
        return null

    # Create a new texture from the region
    var region_texture = ImageTexture.create_from_image(region_image)
    return region_texture
