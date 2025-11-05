@tool
extends MeshInstance3D
class_name TerrainChunk

var has_collision = false
var collision_body: StaticBody3D = null
var tile_position: Vector2
var chunk_position: Vector2
var chunks_per_tile: Vector2
var chunk_state: String = "UNLOADED"
var wireframe_material: StandardMaterial3D
var wireframe_instance: MeshInstance3D = null
var pending_collision: bool = false
var pending_collision_height: float = 0.0

func setup_tile_local(size: Vector3, local_position: Vector3, height_texture: Texture2D,
                material_template: ShaderMaterial, max_height_meters: float,
                render_dist: float, subdivisions: int, tile_pos: Vector2 = Vector2.ZERO,
                chunk_pos: Vector2 = Vector2.ZERO, chunks_per_tile_vec: Vector2 = Vector2.ONE):

    tile_position = tile_pos
    chunk_position = chunk_pos
    chunks_per_tile = chunks_per_tile_vec

    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(size.x, size.z)
    plane_mesh.subdivide_width = subdivisions - 1
    plane_mesh.subdivide_depth = subdivisions - 1
    plane_mesh.orientation = PlaneMesh.FACE_Y

    self.mesh = plane_mesh
    self.position = local_position  # Use local position

    # Only set visibility ranges in game mode
    if not Engine.is_editor_hint():
        self.visibility_range_begin = 0
        self.visibility_range_end = render_dist
        self.visibility_range_end_margin = 200
        self.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

    # Create material
    var chunk_material = ShaderMaterial.new()
    if material_template and material_template.shader:
        chunk_material.shader = material_template.shader
        # Copy shader parameters
        for param in material_template.get_shader_parameter_list():
            chunk_material.set_shader_parameter(param.name, material_template.get_shader_parameter(param.name))
    else:
        chunk_material.shader = preload("shaders/topographic_shader.gdshader")

    # Set parameters for chunk-based rendering
    chunk_material.set_shader_parameter("use_map_slice", true)
    chunk_material.set_shader_parameter("tile_position", Vector2(tile_pos.y, tile_pos.x))
    chunk_material.set_shader_parameter("chunk_position", Vector2(chunk_pos.x, chunk_pos.y))
    chunk_material.set_shader_parameter("chunks_per_tile", chunks_per_tile_vec)
    chunk_material.set_shader_parameter("max_height", max_height_meters)
    chunk_material.set_shader_parameter("height_texture", height_texture)

    self.material_override = chunk_material
    chunk_state = "VISUAL_ONLY"

    # Create wireframe material for editor
    _create_wireframe_material()

# NEW: Safe collision addition that handles tree state
func add_collision(max_height_meters: float):
    if has_collision:
        return

    if not is_inside_tree():
        # Queue collision for when we're in the tree
        pending_collision = true
        pending_collision_height = max_height_meters
        return

    _add_collision_internal(max_height_meters)

# NEW: Internal collision method that assumes we're in the tree
func _add_collision_internal(max_height_meters: float):
    if has_collision or not is_inside_tree():
        return

    # Get the height texture from the material
    var height_texture = self.material_override.get_shader_parameter("height_texture")
    if not height_texture:
        print("No height texture found for collision")
        return

    var image = height_texture.get_image()
    if not image:
        print("Failed to get image from texture")
        return

    # Ensure image is decompressed
    if image.is_compressed():
        if image.decompress() != OK:
            print("Failed to decompress image for collision")
            return

    if image.is_compressed():
        print("ERROR: Image is still compressed after decompress attempt!")
        return

    # Calculate the portion of the image for this chunk
    var chunk_width = int(image.get_width() / chunks_per_tile.x)
    var chunk_height = int(image.get_height() / chunks_per_tile.y)

    var height_data = PackedFloat32Array()
    height_data.resize(chunk_width * chunk_height)

    for y in range(chunk_height):
        for x in range(chunk_width):
            var image_x = int(chunk_position.x * chunk_width) + x
            var image_y = int(chunk_position.y * chunk_height) + y
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
    collision_body.position = Vector3.ZERO  # Local to chunk

    add_child(collision_body)
    has_collision = true
    chunk_state = "WITH_COLLISION"

    # Set owner only if we're in the editor and in the tree
    if Engine.is_editor_hint() and is_inside_tree():
        var scene_root = get_tree().get_edited_scene_root()
        if scene_root:
            collision_body.set_owner(scene_root)
            collision_shape.set_owner(scene_root)

    print("Added collision to chunk %s of tile %s" % [chunk_position, tile_position])

# NEW: Handle when chunk enters tree
func _enter_tree():
    if pending_collision:
        call_deferred("_add_collision_internal", pending_collision_height)
        pending_collision = false
        pending_collision_height = 0.0

func remove_collision():
    if collision_body:
        if collision_body.is_inside_tree():
            remove_child(collision_body)
        collision_body.queue_free()
        collision_body = null
    has_collision = false
    chunk_state = "VISUAL_ONLY"
    pending_collision = false

func set_visual_only():
    remove_collision()

func get_tile_position() -> Vector2:
    return tile_position

func get_chunk_position() -> Vector2:
    return chunk_position

func _exit_tree():
    remove_collision()
    if wireframe_instance and wireframe_instance.is_inside_tree():
        remove_child(wireframe_instance)
    wireframe_instance = null

func _create_wireframe_material():
    wireframe_material = StandardMaterial3D.new()
    wireframe_material.flags_unshaded = true
    wireframe_material.vertex_color_use_as_albedo = true
    wireframe_material.flags_transparent = true
    wireframe_material.albedo_color = Color(0, 1, 0, 0.3)

func set_wireframe_mode(enabled: bool):
    if not wireframe_material:
        _create_wireframe_material()

    if enabled and wireframe_instance == null:
        # Create wireframe using the existing mesh but with lines
        var wireframe_mesh = ArrayMesh.new()
        var surface_tool = SurfaceTool.new()
        surface_tool.begin(Mesh.PRIMITIVE_LINES)

        if mesh is PlaneMesh:
            # Get mesh data and create wireframe
            var mesh_data = mesh.get_mesh_arrays()
            if mesh_data.size() > 0 and mesh_data[Mesh.ARRAY_VERTEX] != null:
                var vertices: PackedVector3Array = mesh_data[Mesh.ARRAY_VERTEX]
                var indices: PackedInt32Array = mesh_data[Mesh.ARRAY_INDEX]

                # Create wireframe from triangles
                for i in range(0, indices.size(), 3):
                    if i + 2 < indices.size():
                        var v0 = vertices[indices[i]]
                        var v1 = vertices[indices[i + 1]]
                        var v2 = vertices[indices[i + 2]]

                        # Add triangle edges
                        surface_tool.add_vertex(v0)
                        surface_tool.add_vertex(v1)

                        surface_tool.add_vertex(v1)
                        surface_tool.add_vertex(v2)

                        surface_tool.add_vertex(v2)
                        surface_tool.add_vertex(v0)

                wireframe_mesh = surface_tool.commit()

                wireframe_instance = MeshInstance3D.new()
                wireframe_instance.mesh = wireframe_mesh
                wireframe_instance.material_override = wireframe_material
                wireframe_instance.name = "Wireframe"
                add_child(wireframe_instance)

                # Set owner only if we're in the editor and in the tree
                if Engine.is_editor_hint() and is_inside_tree():
                    wireframe_instance.set_owner(get_tree().get_edited_scene_root())
    elif not enabled and wireframe_instance != null:
        remove_child(wireframe_instance)
        wireframe_instance.queue_free()
        wireframe_instance = null
