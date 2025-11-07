shader_type spatial;

uniform sampler2D heightmap_texture;
uniform sampler2D normalmap_texture;
uniform vec2 tile_coords;
uniform int current_zoom;
uniform float terrain_scale = 1000.0;
uniform float height_scale = 1.0; // 1:1 height scale
uniform bool use_precomputed_normals = false;

// Topographic colors
uniform vec3 deep_water_color: source_color = vec3(0.0, 0.1, 0.3);
uniform vec3 shallow_water_color: source_color = vec3(0.0, 0.3, 0.6);
uniform vec3 sand_color: source_color = vec3(0.76, 0.7, 0.5);
uniform vec3 grass_low_color: source_color = vec3(0.2, 0.5, 0.2);
uniform vec3 grass_high_color: source_color = vec3(0.3, 0.6, 0.3);
uniform vec3 forest_color: source_color = vec3(0.1, 0.4, 0.1);
uniform vec3 rock_color: source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 snow_color: source_color = vec3(1.0, 1.0, 1.0);

// Height thresholds in meters (adjust based on your region)
uniform float water_level = 70.0;
uniform float sand_level = 120.0;
uniform float grass_level = 200.0;
uniform float forest_level = 500.0;
uniform float rock_level = 1000.0;
uniform float snow_level = 1500.0;

varying float v_height;

// Decode Terrarium format RGB to height (returns meters)
float decode_height(vec4 color) {
    float r = color.r * 255.0;
    float g = color.g * 255.0;
    float b = color.b * 255.0;
    return (r * 256.0 + g + b / 256.0) - 32768.0;
}

// Calculate normal from heightmap with proper scale
vec3 calculate_normal(vec2 uv, float delta) {
    float height_center = decode_height(texture(heightmap_texture, uv));
    
    vec2 texel_size = 1.0 / vec2(textureSize(heightmap_texture, 0));
    
    float height_right = decode_height(texture(heightmap_texture, uv + vec2(texel_size.x, 0.0)));
    float height_left = decode_height(texture(heightmap_texture, uv + vec2(-texel_size.x, 0.0)));
    float height_up = decode_height(texture(heightmap_texture, uv + vec2(0.0, texel_size.y)));
    float height_down = decode_height(texture(heightmap_texture, uv + vec2(0.0, -texel_size.y)));
    
    // Scale the normal calculation by the actual terrain scale
    float horizontal_scale = terrain_scale; // Use the actual terrain size
    vec3 normal = normalize(vec3(
        (height_left - height_right) * horizontal_scale,
        delta * 2.0, // This controls the normal strength
        (height_down - height_up) * horizontal_scale
    ));
    
    return normal;
}

void vertex() {
    vec2 uv = UV;
    
    // Sample height from texture (in meters)
    vec4 height_color = texture(heightmap_texture, uv);
    float raw_height = decode_height(height_color);
    
    // Apply 1:1 height scaling (1 meter in data = 1 meter in world)
    float height = raw_height * height_scale;
    v_height = raw_height;
    
    // Displace vertex - this is now in real meters
    VERTEX.y = height;
    
    // Calculate normal
    NORMAL = calculate_normal(uv, terrain_scale * 0.01); // Adjust normal strength based on terrain scale
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

    // Use precomputed normal map if available
    if (use_precomputed_normals) {
        vec3 normal_map = texture(normalmap_texture, UV).rgb;
        // Convert from [0,1] to [-1,1] range and apply
        NORMAL = normalize(normal_map * 2.0 - 1.0);
    }

    ALBEDO = color;
    METALLIC = 0.0;
    ROUGHNESS = 0.8;
    
    // Add some specular for water areas
    if (height < water_level) {
        METALLIC = 0.1;
        ROUGHNESS = 0.3;
    }
}