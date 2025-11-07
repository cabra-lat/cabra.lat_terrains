shader_type spatial;

uniform sampler2D heightmap_texture;
uniform vec2 tile_coords;
uniform int current_zoom;
uniform float terrain_scale = 100.0;
uniform float height_scale = 0.1;
uniform float start_lat = -15.708;
uniform float start_lon = -48.560;
uniform float tile_center_lat = -15.708;
uniform float tile_center_lon = -48.560;

// Topographic colors
uniform vec3 deep_water_color: source_color = vec3(0.0, 0.1, 0.3);
uniform vec3 shallow_water_color: source_color = vec3(0.0, 0.3, 0.6);
uniform vec3 sand_color: source_color = vec3(0.76, 0.7, 0.5);
uniform vec3 grass_low_color: source_color = vec3(0.2, 0.5, 0.2);
uniform vec3 grass_high_color: source_color = vec3(0.3, 0.6, 0.3);
uniform vec3 forest_color: source_color = vec3(0.1, 0.4, 0.1);
uniform vec3 rock_color: source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 snow_color: source_color = vec3(1.0, 1.0, 1.0);

// Height thresholds
uniform float water_level = 100.0;
uniform float sand_level = 120.0;
uniform float grass_level = 200.0;
uniform float forest_level = 500.0;
uniform float rock_level = 1000.0;
uniform float snow_level = 1500.0;

varying float v_height;

// Decode Terrarium format RGB to height
float decode_height(vec4 color) {
    float r = color.r * 255.0;
    float g = color.g * 255.0;
    float b = color.b * 255.0;
    return (r * 256.0 + g + b / 256.0) - 32768.0;
}

void vertex() {
    // Use UV coordinates directly from the PlaneMesh
    vec2 uv = UV;
    
    // Sample height from texture
    vec4 height_color = texture(heightmap_texture, uv);
    float raw_height = decode_height(height_color);
    
    // Apply height scaling
    float height = raw_height * height_scale;
    v_height = height;
    
    // Displace vertex
    VERTEX.y = height;
    
    // Simple normal calculation
    NORMAL = normalize(vec3(0.0, 1.0, 0.0));
}

void fragment() {
    float height = v_height;
    vec3 color = deep_water_color;

    // Apply topographic coloring based on height
    if (height < water_level) {
        float t = height / water_level;
        color = mix(deep_water_color, shallow_water_color, t);
    } else if (height < sand_level) {
        color = sand_color;
    } else if (height < grass_level) {
        float t = (height - sand_level) / (grass_level - sand_level);
        color = mix(sand_color, grass_low_color, t);
    } else if (height < forest_level) {
        float t = (height - grass_level) / (forest_level - grass_level);
        color = mix(grass_high_color, forest_color, t);
    } else if (height < rock_level) {
        float t = (height - forest_level) / (rock_level - forest_level);
        color = mix(forest_color, rock_color, t);
    } else if (height < snow_level) {
        float t = (height - rock_level) / (snow_level - rock_level);
        color = mix(rock_color, snow_color, t);
    } else {
        color = snow_color;
    }

    ALBEDO = color;
    METALLIC = 0.0;
    ROUGHNESS = 0.8;
}