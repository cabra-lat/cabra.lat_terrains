shader_type spatial;
render_mode cull_disabled;

// Atlases
uniform sampler2D heightmap_atlas: hint_default_black, source_color, repeat_disable, filter_linear_mipmap;
uniform sampler2D normalmap_atlas: hint_normal, repeat_disable, filter_linear_mipmap;
uniform sampler2D albedo_atlas: source_color, repeat_disable, filter_linear_mipmap;

// UV offset and scale for this tile in the atlas
uniform vec2 uv_offset;
uniform vec2 uv_scale;

// Terrain parameters
uniform float terrain_scale = 1000.0;
uniform float height_scale = 1.0;
uniform bool use_precomputed_normals = true;

varying float v_height;

// Decode Terrarium format RGB to height (returns meters)
float decode_height(vec4 color) {
    float r = floor(color.r * 255.0);
    float g = floor(color.g * 255.0);
    float b = floor(color.b * 255.0);
    return floor(r * 256.0 + g + b / 256.0 - 32768.0);
}

// Transform local UV to atlas UV
vec2 transform_uv(vec2 local_uv) {
    return uv_offset + local_uv * uv_scale;
}

void vertex() {
    vec2 local_uv = UV;
    vec2 atlas_uv = transform_uv(local_uv);

    // Sample height from atlas
    vec4 height_color = texture(heightmap_atlas, atlas_uv);
    float raw_height = decode_height(height_color);
    float height = raw_height * height_scale;
    v_height = raw_height;

    // Displace vertex
    VERTEX.y = height;

    // Calculate normal from heightmap atlas (fallback if precomputed normals are disabled)
    if (!use_precomputed_normals) {
        float delta = 0.001;

        // Sample neighboring heights in atlas space
        float h_center = decode_height(texture(heightmap_atlas, atlas_uv));
        float h_right = decode_height(texture(heightmap_atlas, atlas_uv + vec2(delta * uv_scale.x, 0.0)));
        float h_up = decode_height(texture(heightmap_atlas, atlas_uv + vec2(0.0, delta * uv_scale.y)));

        // Calculate gradient
        vec3 normal = normalize(vec3(
            (h_center - h_right) * terrain_scale,
            delta * terrain_scale * 100.0,  // Scale factor for normal strength
            (h_center - h_up) * terrain_scale
        ));

        NORMAL = normal;
    }
}

void fragment() {
    vec2 local_uv = UV;
    vec2 atlas_uv = transform_uv(local_uv);

    // Sample albedo from atlas
    vec4 albedo_color = texture(albedo_atlas, atlas_uv);
    ALBEDO = albedo_color.rgb;

    // Use precomputed normal map if available
    if (use_precomputed_normals) {
        vec4 normal_color = texture(normalmap_atlas, atlas_uv);
        vec3 normal_map = normal_color.rgb * 2.0 - 1.0;
        NORMAL = normalize(normal_map);
    }

    // Material properties
    METALLIC = 0.0;
    ROUGHNESS = 0.8;

    // Add some specular for water areas
    if (v_height < 70.0) {
        METALLIC = 0.1;
        ROUGHNESS = 0.3;
        // Tint water areas blue
        ALBEDO = mix(ALBEDO, vec3(0.0, 0.2, 0.8), 0.3);
    }

    // Optional: Add height-based fog
    float fog_factor = clamp(v_height / 1000.0, 0.0, 0.3);
    ALBEDO = mix(ALBEDO, vec3(0.8, 0.8, 0.9), fog_factor);
}