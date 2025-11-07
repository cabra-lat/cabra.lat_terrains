@tool
extends MeshInstance3D
class_name TerrainChunk

var has_collision = false
var collision_body: StaticBody3D = null
var tile_position: Vector2
var chunk_position: Vector2

func setup_chunk(size: Vector3, world_position: Vector3, height_texture: Texture2D,
                max_height_meters: float, subdivisions: int,
                tile_pos: Vector2, chunk_pos: Vector2, chunks_per_tile_vec: Vector2):

    tile_position = tile_pos
    chunk_position = chunk_pos

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(size.x, size.z)
    plane_mesh.subdivide_width = subdivisions - 1
    plane_mesh.subdivide_depth = subdivisions - 1
    plane_mesh.orientation = PlaneMesh.FACE_Y

    self.mesh = plane_mesh
    self.position = world_position

    # Create basic material
    var chunk_material = ShaderMaterial.new()
    chunk_material.shader = preload("shaders/topographic_shader.gdshader")

    # Set shader parameters
    chunk_material.set_shader_parameter("max_height", max_height_meters)
    chunk_material.set_shader_parameter("height_texture", height_texture)
    chunk_material.set_shader_parameter("use_map_slice", true)
    chunk_material.set_shader_parameter("tile_position", Vector2(tile_pos.y, tile_pos.x))
    chunk_material.set_shader_parameter("chunk_position", Vector2(chunk_pos.x, chunk_pos.y))
    chunk_material.set_shader_parameter("chunks_per_tile", chunks_per_tile_vec)

    self.material_override = chunk_material

func add_collision(max_height_meters: float):
    if has_collision:
        return

    print("Creating collision for chunk ", chunk_position, " of tile ", tile_position)

    # Get the height texture from the material
    var height_texture = self.material_override.get_shader_parameter("height_texture")
    if not height_texture:
        print("No height texture found for collision")
        return

    var image = height_texture.get_image()
    if not image:
        print("Failed to get image from texture")
        return

    # Ensure image is readable
    if image.is_compressed():
        var result = image.decompress()
        if result != OK:
            print("Failed to decompress image for collision")
            return

    # Get chunk dimensions from shader parameters
    var chunks_per_tile = self.material_override.get_shader_parameter("chunks_per_tile")
    var chunk_pos = self.material_override.get_shader_parameter("chunk_position")

    var chunk_width = int(image.get_width() / chunks_per_tile.x)
    var chunk_height = int(image.get_height() / chunks_per_tile.y)

    print("Chunk dimensions: ", chunk_width, "x", chunk_height)

    var height_data = PackedFloat32Array()
    height_data.resize(chunk_width * chunk_height)

    for y in range(chunk_height):
        for x in range(chunk_width):
            var image_x = int(chunk_pos.x * chunk_width) + x
            var image_y = int(chunk_pos.y * chunk_height) + y
            var pixel = image.get_pixel(image_x, image_y)
            height_data[y * chunk_width + x] = pixel.r * max_height_meters

    # Create collision shape
    var heightmap_shape = HeightMapShape3D.new()
    heightmap_shape.map_width = chunk_width
    heightmap_shape.map_depth = chunk_height
    heightmap_shape.map_data = height_data

    # Create static body
    collision_body = StaticBody3D.new()
    var collision_shape = CollisionShape3D.new()
    collision_shape.shape = heightmap_shape

    # Scale collision to match visual size
    var scale_x = mesh.size.x / (chunk_width - 1)
    var scale_z = mesh.size.y / (chunk_height - 1)
    collision_shape.scale = Vector3(scale_x, 1.0, scale_z)

    collision_body.add_child(collision_shape)
    add_child(collision_body)
    has_collision = true

    print("Successfully added collision to chunk")

func remove_collision():
    if collision_body:
        remove_child(collision_body)
        collision_body.queue_free()
        collision_body = null
    has_collision = false
