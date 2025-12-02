@tool
class_name SimpleTerrainTile
extends MeshInstance3D

@export var tile_coords: Vector2i
@export var zoom_level: int = 18
@export var albedo_texture: Texture2D
@export var heightmap_texture: Texture2D
@export var normalmap_texture: Texture2D
@export var terrain_scale: float = 1000.0

func _ready():
    _create_mesh()

func _create_mesh():
    var plane_mesh = PlaneMesh.new()
    plane_mesh.size = Vector2(terrain_scale, terrain_scale)
    plane_mesh.subdivide_depth = 31
    plane_mesh.subdivide_width = 31

    var shader_mat = ShaderMaterial.new()
    shader_mat.shader = preload("../shaders/terrain_shader.gdshader")

    if albedo_texture:
        shader_mat.set_shader_parameter("albedo_texture", albedo_texture)
    if heightmap_texture:
        shader_mat.set_shader_parameter("heightmap_texture", heightmap_texture)
    if normalmap_texture:
        shader_mat.set_shader_parameter("normalmap_texture", normalmap_texture)
        shader_mat.set_shader_parameter("use_precomputed_normals", true)

    shader_mat.set_shader_parameter("terrain_scale", terrain_scale)
    shader_mat.set_shader_parameter("height_scale", 1.0)

    plane_mesh.material = shader_mat
    mesh = plane_mesh
