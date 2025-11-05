shader_type spatial;

uniform sampler2D height_texture;
uniform bool use_map_slice = false;
uniform vec2 tile_position = vec2(0.0);
uniform vec2 chunk_position = vec2(0.0);
uniform vec2 chunks_per_tile = vec2(1.0);

// Global tint color
uniform vec4 global_tint: source_color = vec4(1.0, 1.0, 1.0, 1.0);

// Topographic colors with source_color hints
uniform vec3 deep_water_color: source_color = vec3(0.0, 0.1, 0.3);
uniform vec3 shallow_water_color: source_color = vec3(0.0, 0.3, 0.6);
uniform vec3 sand_color: source_color = vec3(0.76, 0.7, 0.5);
uniform vec3 grass_low_color: source_color = vec3(0.2, 0.5, 0.2);
uniform vec3 grass_high_color: source_color = vec3(0.3, 0.6, 0.3);
uniform vec3 forest_color: source_color = vec3(0.1, 0.4, 0.1);
uniform vec3 rock_color: source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 snow_color: source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 contour_color: source_color = vec3(0.0, 0.0, 0.0);

// TERRAIN SCALING PARAMETERS
uniform float max_height = 2995.0; // Maximum terrain height in meters

// Height thresholds IN METERS
uniform float water_level = 100.0;
uniform float sand_level = 120.0;
uniform float grass_level = 200.0;
uniform float forest_level = 500.0;
uniform float rock_level = 1000.0;
uniform float snow_level = 1500.0;

// Visualization
uniform bool show_contour_lines = false;
uniform float contour_spacing = 100.0;
uniform float contour_width = 10.0;

// Improved lighting
uniform float normal_strength = 2.0;
uniform float ambient_occlusion_strength = 0.5;

// Varyings
varying float v_height;
varying float v_ao;

// Function to calculate improved normals from heightmap
vec3 calculate_normal(vec2 uv, float strength) {
    vec2 texel_size = vec2(1.0) / vec2(textureSize(height_texture, 0));

    float center = texture(height_texture, uv).r;
    float right = texture(height_texture, uv + vec2(texel_size.x, 0.0)).r;
    float left = texture(height_texture, uv - vec2(texel_size.x, 0.0)).r;
    float top = texture(height_texture, uv + vec2(0.0, texel_size.y)).r;
    float bottom = texture(height_texture, uv - vec2(0.0, texel_size.y)).r;

    float dx = (right - left) * strength;
    float dy = (top - bottom) * strength;

    return normalize(vec3(-dx, 1.0, -dy));
}

void vertex() {
    // Calculate UV coordinates for this chunk
    vec2 chunk_uv = UV;

    if (use_map_slice) {
        // Calculate the portion of the texture for this chunk
        vec2 chunk_uv_size = vec2(1.0) / chunks_per_tile;
        vec2 chunk_uv_offset = chunk_position / chunks_per_tile;

        // Map local UV to the chunk's portion of the texture
        chunk_uv = chunk_uv_offset + UV * chunk_uv_size;
    }

    // Sample height
    float height_normalized = texture(height_texture, chunk_uv).r;
    v_height = height_normalized * max_height;

    // Displace in Y direction
    VERTEX.y += v_height;

    // Calculate improved normals
    NORMAL = calculate_normal(chunk_uv, normal_strength);

    // Simple AO calculation (using chunk UV)
    vec2 texel_size = vec2(1.0) / vec2(textureSize(height_texture, 0));
    float sample_dist = 0.001;

    float occlusion = 0.0;
    occlusion += max(texture(height_texture, chunk_uv + vec2(sample_dist, 0.0)).r - height_normalized, 0.0);
    occlusion += max(texture(height_texture, chunk_uv + vec2(-sample_dist, 0.0)).r - height_normalized, 0.0);
    occlusion += max(texture(height_texture, chunk_uv + vec2(0.0, sample_dist)).r - height_normalized, 0.0);
    occlusion += max(texture(height_texture, chunk_uv + vec2(0.0, -sample_dist)).r - height_normalized, 0.0);

    occlusion *= 0.25;
    v_ao = 1.0 - clamp(occlusion * ambient_occlusion_strength, 0.0, 1.0);
}

void fragment() {
    float height_meters = v_height;

    // Topographic coloring
    vec3 final_color = deep_water_color;

    if (height_meters < water_level) {
        float t = height_meters / water_level;
        final_color = mix(deep_water_color, shallow_water_color, t);
    } else if (height_meters < sand_level) {
        final_color = sand_color;
    } else if (height_meters < grass_level) {
        float t = (height_meters - sand_level) / (grass_level - sand_level);
        final_color = mix(sand_color, grass_low_color, t);
    } else if (height_meters < forest_level) {
        float t = (height_meters - grass_level) / (forest_level - grass_level);
        final_color = mix(grass_high_color, forest_color, t);
    } else if (height_meters < rock_level) {
        float t = (height_meters - forest_level) / (rock_level - forest_level);
        final_color = mix(forest_color, rock_color, t);
    } else if (height_meters < snow_level) {
        float t = (height_meters - rock_level) / (snow_level - rock_level);
        final_color = mix(rock_color, snow_color, t);
    } else {
        final_color = snow_color;
    }

    // Apply global tint
    final_color *= global_tint.rgb;

    // Contour lines
    if (show_contour_lines) {
        float contour_dist = abs(mod(height_meters, contour_spacing) - contour_spacing * 0.5);
        if (contour_dist < contour_width) {
            final_color = mix(contour_color, final_color, 0.3);
        }
    }

    // Apply ambient occlusion
    final_color *= v_ao;

    // Lighting
    vec3 normal = normalize(NORMAL);
    vec3 light_dir = normalize(vec3(1.0, 2.0, 1.0));
    float diffuse = max(dot(normal, light_dir), 0.2);
    final_color *= diffuse;

    ALBEDO = final_color;
    METALLIC = 0.0;
    ROUGHNESS = 0.8;
}