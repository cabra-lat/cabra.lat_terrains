class_name LODManager
extends Node

@export var min_zoom: int = 15
@export var max_zoom: int = 10
@export var lod_max_height: float = 8000.0
@export var lod_min_height: float = 50.0

var current_zoom: int = min_zoom
var terrain_loader: DynamicTerrainLoader

func setup(loader: DynamicTerrainLoader):
    terrain_loader = loader

func calculate_dynamic_zoom(player_altitude: float) -> int:
    var effective_altitude = max(0.0, player_altitude - lod_min_height)
    var t = clamp(effective_altitude / lod_max_height, 0.0, 1.0)
    return int(lerp(float(min_zoom), float(max_zoom), t))

func debug_lod_status(target_node: Node3D):
    if not target_node:
        return

    var player_pos = target_node.global_position
    var calculated_zoom = calculate_dynamic_zoom(player_pos.y)

    print("=== LOD DEBUG ===")
    print("Absolute altitude: ", player_pos.y, "m")
    print("Current zoom: ", current_zoom)
    print("Calculated zoom: ", calculated_zoom)
    print("LOD range: ", min_zoom, " to ", max_zoom)

    if current_zoom != calculated_zoom:
        print("LOD MISMATCH: Should be at zoom ", calculated_zoom)
    else:
        print("LOD is correct")
