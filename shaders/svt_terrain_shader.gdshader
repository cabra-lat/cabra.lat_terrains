shader_type spatial;
render_mode cull_disabled;

// Sparse Virtual Texturing System
uniform sampler2DArray physical_texture_pages;
uniform sampler2D page_table;
uniform ivec2 virtual_texture_size = ivec2(8, 8);
uniform ivec2 physical_texture_size = ivec2(2, 2);
uniform vec2 page_size_pixels = vec2(1536, 1536);

// World configuration
uniform vec3 sampling_center;
uniform vec2 sampling_size;
uniform float max_height_meters = 2995.0;

// Terrain configuration  
uniform vec2 tile_size_km = vec2(439.296, 439.296);

// Camera for LOD
uniform vec3 camera_position;

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
varying vec2 v_world_uv;

// Convert world position to virtual texture coordinates
vec2 world_to_virtual_uv(vec3 world_pos) {
    vec2 world_size_km = vec2(virtual_texture_size) * tile_size_km;
    vec2 world_size_m = world_size_km * 1000.0;
    
    // Convert world position to normalized UV [0, 1] across entire world
    return vec2(
        (world_pos.x + world_size_m.x * 0.5) / world_size_m.x,
        (world_pos.z + world_size_m.y * 0.5) / world_size_m.y
    );
}

// Page table lookup
vec4 page_table_lookup(ivec2 virtual_page_coord) {
    // Add 0.5 to sample from the center of the page table texel
    vec2 page_table_uv = (vec2(virtual_page_coord) + 0.5) / vec2(virtual_texture_size);
    return texture(page_table, page_table_uv);
}

// Sample height from SVT system with proper tile transitions
float sample_svt_height(vec3 world_pos) {
    vec2 virtual_uv = world_to_virtual_uv(world_pos);
    virtual_uv = clamp(virtual_uv, 0.0, 1.0);
    
    // Calculate which virtual page we're in
    vec2 virtual_texel = virtual_uv * vec2(virtual_texture_size);
    ivec2 virtual_page_coord = ivec2(floor(virtual_texel));
    vec2 within_page_uv = fract(virtual_texel);
    
    // Clamp page coordinates to valid range
    virtual_page_coord.x = clamp(virtual_page_coord.x, 0, virtual_texture_size.x - 1);
    virtual_page_coord.y = clamp(virtual_page_coord.y, 0, virtual_texture_size.y - 1);
    
    // Page table lookup
    vec4 page_entry = page_table_lookup(virtual_page_coord);
    
    // Check if page is loaded (alpha channel as validity flag)
    if (page_entry.a > 0.5) {
        // Extract physical page coordinates from page table
        ivec2 physical_page_coord = ivec2(page_entry.rg * 255.0);
        int physical_array_index = physical_page_coord.y * physical_texture_size.x + physical_page_coord.x;
        
        // Clamp physical array index to valid range
        physical_array_index = clamp(physical_array_index, 0, physical_texture_size.x * physical_texture_size.y - 1);
        
        // Sample from physical texture
        vec3 physical_uv = vec3(within_page_uv, float(physical_array_index));
        return texture(physical_texture_pages, physical_uv).r;
    }
    
    // Page not loaded - return 0 height
    return 0.0;
}

// Calculate normal using cross product of tangents
vec3 calculate_normal(vec3 world_pos) {
    float delta = 1.0; // Smaller delta for more accurate normals
    
    // Calculate height at current position and surrounding positions
    float h_center = sample_svt_height(world_pos);
    float h_right = sample_svt_height(world_pos + vec3(delta, 0.0, 0.0));
    float h_left = sample_svt_height(world_pos + vec3(-delta, 0.0, 0.0));
    float h_forward = sample_svt_height(world_pos + vec3(0.0, 0.0, delta));
    float h_back = sample_svt_height(world_pos + vec3(0.0, 0.0, -delta));
    
    // Calculate surface tangents
    vec3 tangent_x = vec3(2.0 * delta, (h_right - h_left) * max_height_meters, 0.0);
    vec3 tangent_z = vec3(0.0, (h_forward - h_back) * max_height_meters, 2.0 * delta);
    
    // Normal is cross product of tangents
    return normalize(cross(tangent_x, tangent_z));
}

void vertex() {
    // Calculate world position - use the mesh's transformed position
    vec3 world_pos = VERTEX + NODE_POSITION_WORLD + sampling_center;
    v_world_uv = world_pos.xz;
    
    // Sample height from SVT system
    float height_normalized = sample_svt_height(world_pos);
    v_height = height_normalized * max_height_meters;
    
    // Displace vertex in local space
    VERTEX.y = v_height;
    
    // Calculate normal
    NORMAL = calculate_normal(world_pos);
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