class_name LODManager
extends Node

var min_zoom: int
var max_zoom: int
var lod_max_height: float
var lod_min_height: float

var current_zoom: int
var terrain_loader: DynamicTerrainLoader

func setup(loader: DynamicTerrainLoader):
    terrain_loader = loader
    min_zoom = terrain_loader.min_zoom
    max_zoom = terrain_loader.max_zoom
    lod_max_height = terrain_loader.lod_max_height
    lod_min_height = terrain_loader.lod_min_height
    current_zoom = min_zoom

func calculate_dynamic_zoom(height_above_terrain: float) -> int:
    var effective_height = max(0.0, height_above_terrain - lod_min_height)
    var t = clamp(effective_height / lod_max_height, 0.0, 1.0)
    return int(lerp(float(max_zoom), float(min_zoom), t))

func debug_lod_status(target_node: Node3D):
    if not target_node:
        return

    var player_pos = target_node.global_position
    var terrain_height = terrain_loader.terrain_mesh_manager.get_terrain_elevation_at_position(player_pos)
    var height_above_terrain = max(0.0, player_pos.y - terrain_height)
    var calculated_zoom = calculate_dynamic_zoom(height_above_terrain)

    print("=== LOD DEBUG ===")
    print("Absolute altitude: ", player_pos.y, "m")
    print("Terrain elevation: ", terrain_height, "m")
    print("Height above terrain: ", height_above_terrain, "m")
    print("Current zoom: ", current_zoom)
    print("Calculated zoom: ", calculated_zoom)
    print("LOD range: ", min_zoom, " to ", max_zoom)

    if current_zoom != calculated_zoom:
        print("LOD MISMATCH: Should be at zoom ", calculated_zoom)
    else:
        print("LOD is correct")
