class_name TileTextureType

enum { TERRARIUM, NORMAL }

static func get_type_path(texture_type: int) -> String:
    match texture_type:
        TERRARIUM:
            return "terrarium"
        NORMAL:
            return "normal"
        _:
            return ""

static func get_type_url(texture_type: int) -> String:
    match texture_type:
        TERRARIUM:
            return "https://elevation-tiles-prod.s3.amazonaws.com/terrarium/{z}/{x}/{y}.png"
        NORMAL:
            return "https://elevation-tiles-prod.s3.amazonaws.com/normal/{z}/{x}/{y}.png"
        _:
            return ""
