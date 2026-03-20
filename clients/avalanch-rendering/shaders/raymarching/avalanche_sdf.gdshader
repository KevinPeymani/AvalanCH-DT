shader_type spatial;
render_mode blend_premul_alpha, depth_test_disabled, depth_draw_never, cull_back, unshaded;

group_uniforms Misc;
uniform vec3 sdf_size = vec3(64.0, 64.0, 64.0);
uniform float depth_test_bias: hint_range(0.0, 0.1, 0.0000001) = 0.001;
group_uniforms;

group_uniforms SolidSnow;
uniform vec3 ambient_color: source_color = vec3(0.2, 0.25, 0.35);
uniform vec3 snow_color: source_color = vec3(0.9, 0.95, 1.0);
uniform vec3 snow_cloud_color: source_color = vec3(0.9, 0.95, 1.0);
uniform int raymarching_steps = 64;
uniform float hit_epsilon: hint_range(0.0, 0.05, 0.000001) = 0.01;
uniform float normal_sample_scale: hint_range(0.01, 10.00, 0.000001) = 1.0;
uniform float snow_shadow_step: hint_range(0.01, 10.00, 0.000001) = 0.5;
group_uniforms;

uniform samplerCube sky_cubemap;

group_uniforms DustySnow;
uniform bool show_dusty_snow = false;
uniform float density_multiplier = 10.0;
uniform int raytracing_steps = 64;
uniform float snow_dust_height: hint_range(0., 0.01, 0.0001) = 0.002;
uniform float dusty_snow_shadow_step: hint_range(0.00001, 0.01, 0.000001) = 0.01;
group_uniforms;

group_uniforms Shadows;
uniform float shadow_softness: hint_range(0.1, 10.0) = 2.0;
uniform float shadow_factor_a: hint_range(0.01, 10.0, 0.0001) = 1.;
uniform float shadow_factor_b: hint_range(0.01, 10.0, 0.0001) = 1.;
uniform int shadow_steps: hint_range(0, 100) = 40;
uniform float shadow_epsilon: hint_range(0., 0.01, 0.00001) = 0.001;
uniform float shadow_normal_bias: hint_range(0., 0.1, 0.00001) = 0.01;
uniform float shadow_distribution_power: hint_range(0.1, 10.0, 0.01) = 1.0;
group_uniforms;

group_uniforms Sun;
uniform vec3 sun_dir = vec3(0.5, 0.8, 0.3);
uniform vec3 sun_color: source_color = vec3(1.0, 0.95, 0.9);
uniform float sun_energy = 1.0;
uniform float sun_size = 1.0;
group_uniforms;

group_uniforms Maps;
uniform sampler2D s_vflow;
uniform sampler3D sdf : filter_linear, repeat_disable;
group_uniforms;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying vec3 world_camera;
varying vec3 world_position;

const float min_h = 1000.0;
const float max_h = 3000.0;

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_camera = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

float get_ign(vec2 pos) {
    return fract(52.9829189 * fract(dot(pos, vec2(0.06711056, 0.00583715))));
}

float map_solid(vec3 p_local) {
    vec3 uvw = p_local + vec3(0.5);
    uvw = clamp(vec3(uvw.x, uvw.z, uvw.y), vec3(0.0), vec3(1.0));
    return textureLod(sdf, uvw, 0.0).r;
}

vec3 calc_normal(vec3 p) {
    float e = 2. * normal_sample_scale / sdf_size.x;
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

float get_cloud_density(vec3 p_local) {
    vec2 uv = p_local.xz + vec2(0.5);
    float flow = texture(s_vflow, uv).r;
    
    if (flow <= 0.01) return 0.0;
    
    float solid_dist = map_solid(p_local);
    if (solid_dist < 0.0) return 0.0;
    
    float max_height = flow * snow_dust_height;
    if (solid_dist > max_height) return 0.0;
    
    float falloff = 1.0 - (solid_dist / max_height);
    
    float density = flow * falloff * density_multiplier;
    float bounds = (abs(p_local.x) < 0.5 && abs(p_local.z) < 0.5 && abs(p_local.y) < 0.5) ? 1.0 : 0.0;
    
    return density * bounds;
}

vec3 get_sky(vec3 sun_direction, vec3 ray_dir) {
    return ambient_color;
}

float calculate_light(vec3 p_local, vec3 local_light_dir, float shadow_step, float dither) {
    float transmittance = 1.0;
    vec3 current_local_pos_start = p_local + local_light_dir * shadow_epsilon;
    vec2 res = intersect_aabb(p_local, local_light_dir, vec3(-0.5), vec3(0.5));
    
    float t = max(0.0, res.x);
    float max_t = max(0.0, res.y);
    float shadow_length = max(max_t - t, 0.001);
    
    float current_t = 0.0;
    
    for(int i = 0; i < shadow_steps; i++) {
        float normalized_next = (float(i) + dither) / float(shadow_steps);
        float next_t = pow(normalized_next, shadow_distribution_power) * shadow_length;
        float dt = next_t - current_t;
        
        float sample_t = current_t + dt * 0.5;
        vec3 current_local_pos = current_local_pos_start + local_light_dir * sample_t;
        
        if (all(greaterThanEqual(current_local_pos, vec3(-0.5))) && all(lessThanEqual(current_local_pos, vec3(0.5)))) {
            float solid_d = map_solid(current_local_pos);
            if (solid_d < shadow_normal_bias) {
                float penumbra = clamp((shadow_normal_bias - solid_d) / shadow_normal_bias, 0.0, 1.0);
                transmittance *= exp(-penumbra * dt * 50.0);
            }
        }
        
        if (show_dusty_snow) {
            float d = get_cloud_density(current_local_pos);
            if (d > 0.0) {
                transmittance *= exp(-d * dt * shadow_factor_a);
            }
        }
        
        if (transmittance < 0.01) break;
        current_t = next_t;
    }
    
    return transmittance * shadow_factor_b;
}

void fragment() {
    vec3 ray_dir = normalize(world_position - world_camera);
    mat4 inv_model = inverse(MODEL_MATRIX);
    
    float depth_tex = texture(depth_texture, SCREEN_UV).x;
    vec4 scene_world_pos = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
    scene_world_pos.xyz /= scene_world_pos.w;
    float max_world_dist = length(scene_world_pos.xyz - world_camera);
    
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
        for(int i = 0; i < raymarching_steps; i++) {
            vec3 p_local = local_ro + local_rd * t;
            float d = map_solid(p_local);
            
            if (d < hit_epsilon) {
                hit_solid = true;
                solid_hit_pos_local = p_local;
                break;
            }
            
            t += d * 0.8;
            if (t > t_max) break;
        }
    }

    vec3 solid_albedo = vec3(0.0);
    float final_alpha = 0.0;
    float volume_hit_world_dist = max_world_dist;
    
    vec3 local_sun_dir = normalize((inv_model * vec4(sun_dir, 0.0)).xyz);

    float dither = get_ign(FRAGCOORD.xy);

    if (hit_solid) {
        vec3 local_n = calc_normal(solid_hit_pos_local);
        
        mat3 normal_matrix = transpose(mat3(inv_model));
        vec3 world_n = normalize(normal_matrix * local_n);
        NORMAL = world_n;
        
        float diff = max(dot(world_n, normalize(sun_dir)), 0.0);
        
        vec3 world_solid_hit = (MODEL_MATRIX * vec4(solid_hit_pos_local, 1.0)).xyz;
        volume_hit_world_dist = length(world_solid_hit - world_camera);

        t_max = min(t_max, volume_hit_world_dist);
        
        float shadow = calculate_light(solid_hit_pos_local + local_n * shadow_normal_bias, local_sun_dir, snow_shadow_step, dither);
        vec3 ambient = get_sky(sun_dir, local_n);
        solid_albedo = snow_color * (sun_color * diff * shadow + ambient);
        final_alpha = 1.0;
        
        vec4 clip_pos = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_solid_hit, 1.0);
    }

    if (show_dusty_snow && t_min < t_max) {
        float box_t_min = max(hit.x, 0.0);
        float local_step_size = (hit.y - box_t_min) / float(raytracing_steps);
        
        float current_t = t_min + local_step_size * dither;
        
        float transmittance = 1.0;
        vec3 scattered_light = vec3(0.0);

        for(int i = 0; i < raytracing_steps; i++) {
            if (current_t > t_max) break;
            
            vec3 current_local_pos = local_ro + local_rd * current_t;
            float density = get_cloud_density(current_local_pos);
            
            if (density > 0.001) {
                float light_trans = calculate_light(current_local_pos, local_sun_dir, dusty_snow_shadow_step, dither);
                vec3 ambient = get_sky(sun_dir, vec3(0, 1, 0));
                vec3 S = (sun_color * light_trans + ambient) * density * snow_cloud_color;
                
                float dt = density * local_step_size;
                float step_trans = exp(-dt);
                
                scattered_light += S * (transmittance - transmittance * step_trans) / density;
                transmittance *= step_trans;
                
                if (transmittance < 0.01) break;
            }
            current_t += local_step_size;
        }
        
        ALBEDO = scattered_light + solid_albedo * transmittance;
        ALPHA = (1.0 - transmittance) + final_alpha * transmittance;
    } else {
        ALBEDO = solid_albedo;
        ALPHA = final_alpha;
    }
}