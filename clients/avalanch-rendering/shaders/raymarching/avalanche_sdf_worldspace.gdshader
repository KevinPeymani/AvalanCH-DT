shader_type spatial;
render_mode blend_premul_alpha, depth_test_disabled, depth_draw_never, cull_back, unshaded;

uniform vec3 sun_dir = vec3(0.5, 0.8, 0.3);
uniform vec3 sun_color = vec3(1.0, 0.95, 0.9);
uniform vec3 ambient_color = vec3(0.2, 0.25, 0.35);
uniform vec3 snow_color = vec3(0.9, 0.95, 1.0);

uniform float density_multiplier = 10.0;
uniform float cloud_radius = 1.2;
uniform vec3 cloud_center = vec3(1.5, 0.0, 0.0);

uniform float cloud_scale = 1.0;
uniform float cloud_height = 10.0;

uniform bool show_cloud = false;

uniform float solid_radius = 1.0;
uniform vec3 solid_center = vec3(-1.5, 0.0, 0.0);
uniform float terrain_blend = 1.0;

uniform int max_steps = 64;
uniform float noise_freq = 1.0;
uniform float noise_amp = 20.0;

uniform sampler2D clouds;
uniform sampler3D sdf : filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D snow;
uniform sampler2D terrain;
uniform float depth_test_bias: hint_range(0.0, 0.1, 0.0000001) = 0.001;
uniform float hit_epsilon: hint_range(0.0, 0.05, 0.000001) = 0.01;
uniform float normal_sample_scale: hint_range(0.01, 10.00, 0.000001) = 1.0;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 world_camera;
varying vec3 world_position;

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_camera = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float map_solid(vec3 p_local) {
    vec3 uvw = p_local + vec3(0.5);
    uvw = clamp(vec3(uvw.x, uvw.z, uvw.y), vec3(0.0), vec3(1.0));
    return texture(sdf, uvw).r;
}

vec3 calc_normal(vec3 p) {
    float e = hit_epsilon * normal_sample_scale;
    return normalize(vec3(
        map_solid(p + vec3(e, 0, 0)) - map_solid(p - vec3(e, 0, 0)),
        map_solid(p + vec3(0, e, 0)) - map_solid(p - vec3(0, e, 0)),
        map_solid(p + vec3(0, 0, e)) - map_solid(p - vec3(0, 0, e))
    ));
}

vec2 intersect_aabb(vec3 ray_origin, vec3 ray_dir, vec3 box_min, vec3 box_max) {
    vec3 inv_dir = 1.0 / (ray_dir + 1e-6);
    vec3 t_min = (box_min - ray_origin) * inv_dir;
    vec3 t_max = (box_max - ray_origin) * inv_dir;
    vec3 t1 = min(t_min, t_max);
    vec3 t2 = max(t_min, t_max);
    float t_near = max(max(t1.x, t1.y), t1.z);
    float t_far = min(min(t2.x, t2.y), t2.z);
    return vec2(t_near, t_far);
}

float get_cloud_density(vec3 p) {
    float bounds = (-0.5 < p.x && p.x < 0.5 && -0.5 < p.z && p.z < 0.5) ? 1.0 : 0.0;

    // return 0.1 * bounds;
    vec3 p_local = (p - 0.5) * 0.5;
    vec3 uvw = p_local + vec3(0.5);
    uvw = vec3(uvw.x, uvw.z, uvw.y - 0.1);
    return texture(sdf, uvw).r * bounds;

    // float s = texture(clouds, p.xz / cloud_scale).r;
    // s *= max(0.0, 1.0 - abs((p.y - cloud_center.y)) / cloud_height);
    // s *= bounds;
    
    // vec3 local_p = p - cloud_center;
    // local_p.y *= 3.5;
    
    // float displacement = sin(local_p.x * noise_freq) * sin(local_p.y * noise_freq) * sin(local_p.z * noise_freq) * noise_amp;
    // float distance_to_sphere = length(local_p) - (cloud_radius + displacement);
    // float d = min(0.0, -pow(s - 0.3, 1.0));
    
    // return -min(0.0, d * density_multiplier);
}

float calculate_light(vec3 p_world, vec3 light_dir, float shadow_step, mat4 inv_model) {
    float transmittance = 1.0;
    vec3 current_pos = p_world + light_dir * 0.5;
    
    for(int i = 0; i < 40; i++) {
        float d = show_cloud ? get_cloud_density(current_pos) : -1.;
        
        vec3 local_pos = (inv_model * vec4(current_pos, 1.0)).xyz;
        if (all(greaterThanEqual(local_pos, vec3(-0.5))) && all(lessThanEqual(local_pos, vec3(0.5)))) {
            if (map_solid(local_pos) < 0.0) {
                transmittance *= 0.1;
            }
        }
        
        if (d > 0.0) {
            transmittance *= exp(-d * shadow_step);
        }
        
        if (transmittance < 0.01) break;
        current_pos += light_dir * shadow_step;
    }
    return transmittance;
}

void fragment() {
    vec3 ray_dir = normalize(world_position - world_camera);
    mat4 inv_model = inverse(MODEL_MATRIX);
    
    float depth_tex = texture(depth_texture, SCREEN_UV).x;
    vec4 scene_world_pos = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
    scene_world_pos.xyz /= scene_world_pos.w;
    float max_world_dist = length(scene_world_pos.xyz - world_camera);
    
    // vec3 local_ro = (inv_model * vec4(world_camera, 1.0)).xyz;
    // // vec3 local_rd = normalize((inv_model * vec4(ray_dir, 0.0)).xyz);
    // vec3 local_rd = (inv_model * vec4(ray_dir, 0.0)).xyz;

    // float rescl = length(local_rd);
    // local_rd = normalize(local_rd);
    
    // vec3 scene_local_pos = (inv_model * vec4(scene_world_pos.xyz, 1.0)).xyz;
    // float max_local_dist = length(scene_local_pos - local_ro);

    // vec2 hit = intersect_aabb(local_ro, local_rd, vec3(-0.5), vec3(0.5));
    // // clamped to 0 if we are inside the box
    // float t = max(hit.x, 0.0);
    // float t_max = min(hit.y, max_local_dist);
    
    // // float t = max(hit.x, 0.0);
    // bool hit_solid = false;
    // vec3 solid_hit_pos_local;

    // if (t < hit.y && hit.x <= hit.y) {
    //     for(int i = 0; i < max_steps && t < t_max; i++) {
    //         vec3 p_local = local_ro + local_rd * t;
    //         float d = map_solid(p_local);
            
    //         if (d < -0.001) {
    //             hit_solid = true;
    //             solid_hit_pos_local = p_local;
    //             break;
    //         }
            
    //         t += (d / rescl) * 0.9;
    //         if (t > hit.y)
    //         break;
    //     }
    // }
    vec3 local_ro = (inv_model * vec4(world_camera, 1.0)).xyz;
    vec3 local_rd_raw = (inv_model * vec4(ray_dir, 0.0)).xyz;
    float rescl = length(local_rd_raw);
    vec3 local_rd = local_rd_raw / rescl;

    vec3 scene_local_pos = (inv_model * vec4(scene_world_pos.xyz, 1.0)).xyz;
    float max_local_dist = length(scene_local_pos - local_ro) + depth_test_bias;

    vec2 hit = intersect_aabb(local_ro, local_rd, vec3(-0.50), vec3(0.50));
    float t_min = max(hit.x, 0.0);
    float t_max = min(hit.y, max_local_dist / rescl);
    max_world_dist = min(max_world_dist, hit.y / rescl);
    float t = t_min;

    bool hit_solid = false;
    vec3 solid_hit_pos_local;

    if (t < t_max) {
        for(int i = 0; i < max_steps; i++) {
            vec3 p_local = local_ro + local_rd * t;
            float d = map_solid(p_local);
            
            if (d < hit_epsilon) {
                hit_solid = true;
                solid_hit_pos_local = p_local;
                break;
            }
            
            t += d * 0.8; // To check, seems to improve a liiiiittle bit
            if (t > t_max) break;
        }
    }

    vec3 solid_albedo = vec3(0.0);
    float final_alpha = 0.0;
    float volume_hit_world_dist = max_world_dist;
    
    if (hit_solid) {
        vec3 local_n = calc_normal(solid_hit_pos_local);
        vec3 world_n = normalize((MODEL_MATRIX * vec4(local_n, 0.0)).xyz);
        vec3 norm_sun_dir = normalize(sun_dir);
        float diff = max(dot(world_n, norm_sun_dir), 0.0);
        
        vec3 world_solid_hit = (MODEL_MATRIX * vec4(solid_hit_pos_local, 1.0)).xyz;
        volume_hit_world_dist = length(world_solid_hit - world_camera);
        
        float shadow = calculate_light(world_solid_hit + world_n * 0.0005, norm_sun_dir, 0.5, inv_model);
        solid_albedo = snow_color * (sun_color * diff * shadow + ambient_color);
        final_alpha = 1.0;
        
        vec4 clip_pos = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_solid_hit, 1.0);
        DEPTH = clip_pos.z / clip_pos.w;
        NORMAL = world_n;
    }

    if (show_cloud) {
        float step_size = volume_hit_world_dist / float(max_steps);
        vec3 world_step = ray_dir * step_size;
        
        float dither = hash(FRAGCOORD.xy) * 1.0;
        vec3 current_pos = world_camera + world_step * dither;
        
        float transmittance = 1.0;
        vec3 scattered_light = vec3(0.0);
        vec3 norm_sun_dir = normalize(sun_dir);

        for(int i = 0; i < max_steps; i++) {
            float density = get_cloud_density(current_pos);
            if (density > 0.0) {
                float light_trans = calculate_light(current_pos, norm_sun_dir, 0.01, inv_model);
                vec3 S = (sun_color * light_trans + ambient_color) * density * snow_color;
                float dt = density * step_size;
                float step_trans = exp(-dt);
                
                scattered_light += S * (transmittance - transmittance * step_trans) / density;
                transmittance *= step_trans;
                
                if (transmittance < 0.01) break;
            }
            current_pos += world_step;
        }
        
        ALBEDO = scattered_light + solid_albedo * transmittance;
        ALPHA = (1.0 - transmittance) + final_alpha * transmittance;
    } else {
        ALBEDO = solid_albedo;
        ALPHA = final_alpha;
    }
}