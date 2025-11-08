shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Heightmap & Geometry
uniform sampler2D heightmap_texture: source_color, filter_linear_mipmap;
uniform sampler2D normalmap_texture: source_color, filter_linear_mipmap;
uniform float terrain_scale = 1000.0;
uniform float height_scale = 1.0;
uniform bool use_precomputed_normals = true;

// Ambient Occlusion (heightmap-based)
uniform float ao_strength = 0.7;
uniform float slope_ao_strength = 0.5;
uniform float cavity_ao_strength = 0.8;
uniform float view_ao_strength = 0.3;
uniform float ao_sample_radius = 0.02;

// Terrain Texturing
uniform bool use_texture_splatting = true;

// Base textures
uniform sampler2D texture_sand: source_color, filter_linear_mipmap;
uniform sampler2D texture_grass: source_color, filter_linear_mipmap;
uniform sampler2D texture_rock: source_color, filter_linear_mipmap;
uniform sampler2D texture_snow: source_color, filter_linear_mipmap;
uniform sampler2D texture_dirt: source_color, filter_linear_mipmap;

// Control maps
uniform sampler2D splatmap: hint_default_white, filter_linear_mipmap;
uniform sampler2D noise_texture: hint_default_white, filter_linear_mipmap, repeat_enable;

// Texture scaling
uniform vec2 sand_scale = vec2(30.0, 30.0);
uniform vec2 grass_scale = vec2(40.0, 40.0);
uniform vec2 rock_scale = vec2(10.0, 10.0);
uniform vec2 snow_scale = vec2(60.0, 60.0);
uniform vec2 dirt_scale = vec2(25.0, 25.0);

// Blending parameters
uniform float height_blend_range = 30.0;
uniform float slope_blend_start = 0.6;
uniform float slope_blend_range = 0.3;
uniform float noise_blend_strength = 0.3;

// Water parameters
uniform vec4 water_color: source_color = vec4(0.0, 0.3, 0.5, 1.0);
uniform float water_level = 70.0;
uniform float shore_foam_width = 5.0;
uniform float shore_darken = 0.3;

// Material properties
uniform float base_roughness = 0.8;
uniform float water_roughness = 0.15;
uniform float snow_roughness = 0.3;
uniform float rock_metallic = 0.1;
uniform float snow_metallic = 0.05;

// Height thresholds (meters)
uniform float sand_level = 120.0;
uniform float grass_level = 200.0;
uniform float rock_level = 800.0;
uniform float snow_level = 1500.0;

varying float v_height;
varying vec3 v_normal;
varying vec3 v_world_position;
varying vec3 v_view_dir;
varying vec2 v_uv;

// Helper function to get texture size as vec2
vec2 get_texture_size(sampler2D tex) {
    ivec2 size = textureSize(tex, 0);
    return vec2(float(size.x), float(size.y));
}

// Decode Terrarium format RGB to height (meters)
float decode_height(vec4 color) {
    int r = int(color.r * 255.0);
    int g = int(color.g * 255.0);
    int b = int(color.b * 255.0);
    return float((r * 256 + g + b / 256) - 32768);
}

// Calculate normal from heightmap with proper scaling
vec3 calculate_normal(vec2 uv) {
    vec2 tex_size = get_texture_size(heightmap_texture);
    vec2 texel_size = 1.0 / tex_size;
    
    float h_c = decode_height(texture(heightmap_texture, uv));
    float h_r = decode_height(texture(heightmap_texture, uv + vec2(texel_size.x, 0.0)));
    float h_l = decode_height(texture(heightmap_texture, uv - vec2(texel_size.x, 0.0)));
    float h_u = decode_height(texture(heightmap_texture, uv + vec2(0.0, texel_size.y)));
    float h_d = decode_height(texture(heightmap_texture, uv - vec2(0.0, texel_size.y)));
    
    float h_scale = height_scale * terrain_scale * 0.001;
    vec3 normal = normalize(vec3(
        (h_l - h_r) * terrain_scale * 0.01,
        2.0 * texel_size.x * terrain_scale * h_scale,
        (h_d - h_u) * terrain_scale * 0.01
    ));
    return normal;
}

// Heightmap-based Ambient Occlusion
float calculate_ambient_occlusion(vec2 uv, vec3 normal, vec3 view_dir) {
    // 1. Slope-based AO
    float slope = dot(normal, vec3(0.0, 1.0, 0.0));
    float slope_ao = 1.0 - pow(1.0 - slope, slope_ao_strength * 3.0);
    
    // 2. Cavity-based AO using heightmap samples
    vec2 tex_size = get_texture_size(heightmap_texture);
    vec2 texel_size = 1.0 / tex_size;
    float center_height = decode_height(texture(heightmap_texture, uv));
    float occlusion = 0.0;
    float sample_count = 0.0;
    
    // Efficient 8-sample pattern around center point
    vec2 offsets[8] = vec2[](
        vec2(1, 0), vec2(-1, 0), vec2(0, 1), vec2(0, -1),
        vec2(1, 1), vec2(-1, 1), vec2(1, -1), vec2(-1, -1)
    );
    
    for (int i = 0; i < 8; i++) {
        vec2 sample_uv = uv + offsets[i] * texel_size * ao_sample_radius;
        float sample_height = decode_height(texture(heightmap_texture, sample_uv));
        
        if (sample_height > center_height) {
            float height_diff = min(sample_height - center_height, 20.0);
            occlusion += height_diff * 0.05;
        }
        sample_count += 1.0;
    }
    
    float cavity_ao = 1.0 - (occlusion / sample_count) * cavity_ao_strength;
    
    // 3. View-dependent AO
    float view_dot = dot(normal, -view_dir);
    float view_ao = pow(max(0.0, view_dot), view_ao_strength * 4.0);
    
    // Combine with artistic control
    return clamp(slope_ao * cavity_ao * view_ao, 0.2, 1.0);
}

// Advanced texture blending system
vec3 blend_textures(vec2 uv, float height, float slope) {
    // Calculate base weights from height
    float sand_w = smoothstep(sand_level + height_blend_range, sand_level - height_blend_range, height);
    float grass_w = smoothstep(grass_level + height_blend_range, grass_level - height_blend_range, height) * (1.0 - sand_w);
    float rock_w = smoothstep(rock_level + height_blend_range, rock_level - height_blend_range, height) * (1.0 - sand_w - grass_w);
    float snow_w = smoothstep(snow_level + height_blend_range, snow_level - height_blend_range, height);
    float dirt_w = 1.0 - sand_w - grass_w - rock_w - snow_w;
    
    // Apply slope control
    float rock_slope_factor = 1.0 - smoothstep(slope_blend_start, slope_blend_start + slope_blend_range, slope);
    float snow_slope_factor = smoothstep(0.85, 1.0, slope);
    
    rock_w *= rock_slope_factor;
    snow_w *= snow_slope_factor;
    dirt_w += rock_w * (1.0 - rock_slope_factor) * 0.5;
    
    // Normalize weights
    float total = sand_w + grass_w + rock_w + snow_w + dirt_w;
    if (total > 0.0) {
        sand_w /= total; grass_w /= total; rock_w /= total; snow_w /= total; dirt_w /= total;
    }
    
    // Sample textures
    vec3 sand = texture(texture_sand, uv * sand_scale).rgb;
    vec3 grass = texture(texture_grass, uv * grass_scale).rgb;
    vec3 rock = texture(texture_rock, uv * rock_scale).rgb;
    vec3 snow = texture(texture_snow, uv * snow_scale).rgb;
    vec3 dirt = texture(texture_dirt, uv * dirt_scale).rgb;
    
    // Noise-based micro-blending
    vec2 noise_uv = uv * 50.0;
    float noise = texture(noise_texture, noise_uv).r;
    
    // Blend noise patterns based on dominant material
    float grass_noise = smoothstep(0.3, 0.7, noise) * noise_blend_strength;
    float rock_noise = smoothstep(0.4, 0.8, noise) * noise_blend_strength * 0.7;
    float sand_noise = smoothstep(0.2, 0.6, noise) * noise_blend_strength * 0.5;
    
    grass = mix(grass, dirt, grass_noise);
    rock = mix(rock, dirt, rock_noise);
    sand = mix(sand, dirt, sand_noise);
    
    // Base blend
    vec3 blended = sand * sand_w + grass * grass_w + rock * rock_w + snow * snow_w + dirt * dirt_w;
    
    // Splatmap influence (R=Snow, G=Rock, B=Grass, A=Dirt)
    vec2 splat_uv = uv * 0.1;
    vec4 splat_weights = texture(splatmap, splat_uv);
    
    float snow_override = splat_weights.r * smoothstep(snow_level - 100.0, snow_level, height) * smoothstep(0.8, 1.0, slope);
    float rock_override = splat_weights.g * smoothstep(rock_level - 100.0, rock_level, height) * (1.0 - smoothstep(0.7, 1.0, slope));
    float grass_override = splat_weights.b * (1.0 - smoothstep(grass_level + 50.0, grass_level + 150.0, height));
    
    blended = mix(blended, snow, snow_override);
    blended = mix(blended, rock, rock_override);
    blended = mix(blended, grass, grass_override);
    
    return blended;
}

void vertex() {
    v_uv = UV;
    
    // Sample height
    vec4 height_color = texture(heightmap_texture, UV);
    float raw_height = decode_height(height_color);
    v_height = raw_height * height_scale;
    
    // Displace vertex
    VERTEX.y = v_height;
    
    // Calculate normals
    if (use_precomputed_normals) {
        vec3 normal_map = texture(normalmap_texture, UV).rgb;
        v_normal = normalize(normal_map * 2.0 - 1.0);
    } else {
        v_normal = calculate_normal(UV);
    }
    
    // World position and view direction
    v_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 camera_pos = INV_VIEW_MATRIX[3].xyz;
    v_view_dir = normalize(v_world_position - camera_pos);
    
    // Pass to fragment
    NORMAL = v_normal;
}

void fragment() {
    vec3 world_normal = normalize(v_normal);
    vec3 view_dir = normalize(v_view_dir);
    
    // Calculate AO
    float ao = calculate_ambient_occlusion(v_uv, world_normal, view_dir);
    ao = mix(1.0, ao, ao_strength);
    
    vec3 final_color;
    float roughness = base_roughness;
    float metallic = 0.0;
    
    if (v_height < water_level) {
        // Water with shore effects
        float depth = water_level - v_height;
        float foam = smoothstep(0.0, shore_foam_width, depth);
        final_color = mix(water_color.rgb * 0.6, vec3(0.95, 0.95, 1.0), foam);
        final_color *= 1.0 - shore_darken * (1.0 - foam) * (1.0 - foam);
        roughness = water_roughness;
    } else if (use_texture_splatting) {
        // Advanced terrain texturing
        vec2 terrain_uv = v_uv * vec2(terrain_scale, terrain_scale);
        float slope = dot(world_normal, vec3(0.0, 1.0, 0.0));
        
        final_color = blend_textures(terrain_uv, v_height, slope);
        
        // Material properties
        float snow_influence = smoothstep(snow_level - 50.0, snow_level, v_height) * smoothstep(0.85, 1.0, slope);
        float rock_influence = smoothstep(rock_level - 50.0, rock_level, v_height) * (1.0 - smoothstep(0.7, 1.0, slope));
        
        if (snow_influence > 0.1) {
            roughness = mix(base_roughness, snow_roughness, snow_influence);
            metallic = snow_metallic * snow_influence;
        } else if (rock_influence > 0.3) {
            roughness = mix(base_roughness, 0.9, rock_influence);
            metallic = rock_metallic * rock_influence;
        }
    } else {
        // Simple topographic coloring with slope variation
        vec3 color;
        if (v_height < sand_level) {
            color = vec3(0.85, 0.8, 0.65); // Sand
        } else if (v_height < grass_level) {
            float t = smoothstep(sand_level, grass_level, v_height);
            color = mix(vec3(0.85, 0.8, 0.65), vec3(0.3, 0.6, 0.3), t);
        } else if (v_height < rock_level) {
            float t = smoothstep(grass_level, rock_level, v_height);
            color = mix(vec3(0.3, 0.6, 0.3), vec3(0.45, 0.4, 0.35), t);
        } else if (v_height < snow_level) {
            float t = smoothstep(rock_level, snow_level, v_height);
            color = mix(vec3(0.45, 0.4, 0.35), vec3(0.9, 0.95, 1.0), t);
        } else {
            color = vec3(0.95, 0.97, 1.0); // Snow
        }
        
        // Add slope-based darkening
        float slope = dot(world_normal, vec3(0.0, 1.0, 0.0));
        final_color = color * (0.6 + 0.4 * slope);
    }
    
    // Apply AO and final output
    ALBEDO = final_color * ao;
    ROUGHNESS = roughness;
    METALLIC = metallic;
    SPECULAR = 0.5;
}