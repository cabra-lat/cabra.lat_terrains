@tool
class_name MultiZoomTextureCompositor
extends RefCounted

static func build_atlas_for_grid(tile_coords_list: Array, zoom: int, layer_type: String, tile_manager: TileManager) -> Dictionary:
    var atlas_data = {
        "texture": null,
        "offsets": {},  # tile_coords -> Vector2 uv_offset
        "scales": {},   # tile_coords -> Vector2 uv_scale
        "indices": {},  # tile_coords -> Vector2i atlas_index
        "size": Vector2.ZERO,
        "tile_count": Vector2i.ZERO
    }

    if zoom != 18:
        print("Warning: Only zoom 18 is supported for atlas building")
        return atlas_data

    # Determine grid bounds
    var min_x = INF
    var max_x = -INF
    var min_y = INF
    var max_y = -INF

    for coords in tile_coords_list:
        if coords is Vector2i:
            min_x = min(min_x, coords.x)
            max_x = max(max_x, coords.x)
            min_y = min(min_y, coords.y)
            max_y = max(max_y, coords.y)

    var grid_width = int(max_x - min_x + 1)
    var grid_height = int(max_y - min_y + 1)

    print("Building ",layer_type," atlas for grid: ", grid_width, " x ", grid_height)

    # For zoom 18, we need to get zoom 15 tiles and extract regions
    var zoom15_tiles = {}

    # First, collect all unique zoom15 tiles needed
    for coords in tile_coords_list:
        if coords is Vector2i:
            var zoom15_coords = _get_zoom15_tile_coords(coords)
            if not zoom15_tiles.has(zoom15_coords):
                zoom15_tiles[zoom15_coords] = []
            zoom15_tiles[zoom15_coords].append(coords)

    # Download all needed zoom15 tiles
    var all_tiles_ready = true
    for zoom15_coords in zoom15_tiles.keys():
        var texture = tile_manager.get_tile_data(zoom15_coords, 15, layer_type)
        if not texture:
            tile_manager.queue_tile_download(zoom15_coords, 15, layer_type)
            all_tiles_ready = false

    if not all_tiles_ready:
        print("Waiting for ", layer_type, " zoom15 tiles...")
        return atlas_data

    # Each zoom18 tile is 1/8 of zoom15 tile
    var source_resolution = 256  # Assuming 256x256 zoom15 tiles
    var region_size = source_resolution / 8

    # Create atlas image
    var atlas_width = grid_width * region_size
    var atlas_height = grid_height * region_size

    print("Creating {", layer_type, "} atlas: {", atlas_width, "}x{", atlas_height, "}")

    var atlas_image = Image.create(atlas_width, atlas_height, false, Image.FORMAT_RGBA8)

    # Fill atlas with tile regions
    for coords in tile_coords_list:
        if not (coords is Vector2i):
            continue

        var zoom15_coords = _get_zoom15_tile_coords(coords)
        var zoom15_texture = tile_manager.get_tile_data(zoom15_coords, 15, layer_type)

        if not zoom15_texture:
            print("Missing zoom15 tile: ", zoom15_coords)
            continue

        var zoom15_image = zoom15_texture.get_image()
        if zoom15_image.is_empty():
            print("Empty zoom15 image for tile: {", zoom15_coords, "}")
            continue

        # Convert to RGBA8 if needed
        if zoom15_image.get_format() != Image.FORMAT_RGBA8:
            zoom15_image.convert(Image.FORMAT_RGBA8)

        # Calculate sub-tile position within zoom15 tile
        var sub_tile_x = coords.x % 8
        var sub_tile_y = coords.y % 8

        # Extract region
        var region_start_x = sub_tile_x * region_size
        var region_start_y = sub_tile_y * region_size

        # Ensure region is within bounds
        if region_start_x + region_size > zoom15_image.get_width() or region_start_y + region_size > zoom15_image.get_height():
            print("Region out of bounds for tile", coords)
            continue

        var region = Rect2i(region_start_x, region_start_y, region_size, region_size)
        var tile_image = zoom15_image.get_region(region)

        if tile_image.is_empty():
            print("Empty region for tile", coords)
            continue

        # Calculate atlas position
        var atlas_x = int((coords.x - min_x) * region_size)
        var atlas_y = int((coords.y - min_y) * region_size)

        # Blit tile image to atlas
        atlas_image.blit_rect(tile_image, Rect2i(0, 0, region_size, region_size), Vector2i(atlas_x, atlas_y))

        # Calculate UV offset and scale - convert to Vector2 for division
        var atlas_size_vec = Vector2(atlas_image.get_size())
        atlas_data.offsets[coords] = Vector2(atlas_x, atlas_y) / atlas_size_vec
        atlas_data.scales[coords] = Vector2(region_size, region_size) / atlas_size_vec
        atlas_data.indices[coords] = Vector2i(coords.x - min_x, coords.y - min_y)

    # Create texture from atlas
    atlas_data.texture = ImageTexture.create_from_image(atlas_image)
    atlas_data.size = atlas_image.get_size()
    atlas_data.tile_count = Vector2i(grid_width, grid_height)

    print(layer_type, " atlas built: ", atlas_image.get_size())
    return atlas_data

static func _get_zoom15_tile_coords(zoom18_tile: Vector2i) -> Vector2i:
    return Vector2i(zoom18_tile.x >> 3, zoom18_tile.y >> 3)

static func _extract_zoom18_region_from_zoom15(zoom15_texture: Texture2D, zoom18_tile: Vector2i) -> Texture2D:
    # Keep this for backward compatibility
    if not zoom15_texture or not is_instance_valid(zoom15_texture):
        return null

    var zoom15_image = zoom15_texture.get_image()
    if not zoom15_image or zoom15_image.is_empty():
        return null

    var sub_tile_x = zoom18_tile.x % 8
    var sub_tile_y = zoom18_tile.y % 8

    var region_size = zoom15_image.get_size() / 8
    var region = Rect2i(sub_tile_x * region_size.x, sub_tile_y * region_size.y, region_size.x, region_size.y)

    var region_image = zoom15_image.get_region(region)
    return ImageTexture.create_from_image(region_image)

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
