shader_type spatial;
render_mode blend_premul_alpha, depth_test_disabled, cull_back, unshaded;

uniform vec3 sun_dir = vec3(0.5, 0.8, 0.3);
uniform vec3 sun_color = vec3(1.0, 0.95, 0.9);
uniform vec3 ambient_color = vec3(0.2, 0.25, 0.35);
uniform vec3 snow_color = vec3(0.9, 0.95, 1.0);

uniform float density_multiplier = 10.0;
uniform float cloud_radius = 1.2;
uniform vec3 cloud_center = vec3(1.5, 0.0, 0.0);

uniform float cloud_scale = 1.;
uniform float cloud_height = 10.;

uniform bool show_cloud = false;

uniform float solid_radius = 1.0;
uniform vec3 solid_center = vec3(-1.5, 0.0, 0.0);
uniform float terrain_blend = 1.0;

uniform int max_steps = 64;
uniform float noise_freq = 1.0;
uniform float noise_amp = 20.0;

uniform sampler2D clouds;

uniform sampler2D snow;
uniform sampler2D terrain;
uniform float height_scale: hint_range(0.0, 0.001, 0.0000001) = 0.001;

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

float map_solid(vec3 p) {
	vec2 uv = clamp((p.xz + vec2(1.)) * 0.5, vec2(0.), vec2(1.));
	
    float h_snow = 1. * texture(snow, uv).r * height_scale;
    float h_terrain = texture(terrain, uv).r * height_scale;
	float h = h_snow + h_terrain - 0.01;
	return p.y - h;
}

vec3 calc_normal(vec3 p) {
    vec2 e = vec2(0.01, 0.0);
    return normalize(vec3(
        map_solid(p + e.xyy) - map_solid(p - e.xyy),
        map_solid(p + e.yxy) - map_solid(p - e.yxy),
        map_solid(p + e.yyx) - map_solid(p - e.yyx)
    ));
}

vec2 intersect_aabb(vec3 ray_origin, vec3 ray_dir, vec3 box_min, vec3 box_max) {
    vec3 t_min = (box_min - ray_origin) / ray_dir;
    vec3 t_max = (box_max - ray_origin) / ray_dir;
    vec3 t1 = min(t_min, t_max);
    vec3 t2 = max(t_min, t_max);
    float t_near = max(max(t1.x, t1.y), t1.z);
    float t_far = min(min(t2.x, t2.y), t2.z);
    return vec2(t_near, t_far);
}

float get_cloud_density(vec3 p) {
	float bounds = (-3000.<p.x && p.x<3000. && -1800.<p.z && p.z<1800.) ? 1. : 0.;
	float s = texture(clouds, p.xz / cloud_scale).r;
	s *= max(0., 1. - abs((p.y - cloud_center.y)) / cloud_height);
	s *= bounds;
    vec3 local_p = p - cloud_center;
	local_p.y *= 3.5;
    float displacement = sin(local_p.x * noise_freq) * sin(local_p.y * noise_freq) * sin(local_p.z * noise_freq) * noise_amp;
    float distance_to_sphere = length(local_p) - (cloud_radius + displacement);
    float d = min(0., -pow(s - 0.3, 1.0));
    return -min(0.0, d * density_multiplier);
}

//float get_cloud_density(vec3 p) {
    //vec3 local_p = p - cloud_center;
    //float displacement = sin(local_p.x * noise_freq) * sin(local_p.y * noise_freq) * sin(local_p.z * noise_freq) * noise_amp;
    //float distance_to_sphere = length(local_p) - (cloud_radius + displacement);
    //float d = -pow(-distance_to_sphere / cloud_radius, 1.0);
    //return -min(0.0, d * density_multiplier);
//}

float calculate_light(vec3 p, vec3 light_dir, float shadow_step) {
    //float shadow_step = 0.5;
    float transmittance = 1.0;
    vec3 current_pos = p + light_dir * 0.5;
    
    for(int i = 0; i < 40; i++) {
        float d = get_cloud_density(current_pos);
        if (map_solid(current_pos) < 0.0) {
            transmittance *= 0.1;
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
    vec3 local_ro = (inv_model * vec4(world_camera, 1.0)).xyz;
    vec3 local_rd = normalize((inv_model * vec4(ray_dir, 0.0)).xyz);
    
    vec2 hit = intersect_aabb(local_ro, local_rd, vec3(-0.5), vec3(0.5));
    
    if (hit.x > hit.y || hit.y < 0.0) {
        discard;
    }

    hit.x = max(hit.x, 0.0);
    
    vec3 world_start = (MODEL_MATRIX * vec4(local_ro + local_rd * hit.x, 1.0)).xyz;
    vec3 world_end = (MODEL_MATRIX * vec4(local_ro + local_rd * hit.y, 1.0)).xyz;
    
    float depth_tex = texture(depth_texture, SCREEN_UV).x;
    vec4 scene_world_pos = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
    scene_world_pos.xyz /= scene_world_pos.w;
    
    float max_ray_dist = length(scene_world_pos.xyz - world_camera) - length(world_start - world_camera);
    
    if (max_ray_dist <= 0.0) {
        discard;
    }

    vec3 rd = normalize(world_end - world_start);
    float total_dist = min(length(world_end - world_start), max_ray_dist);
    
    float t = 0.0;
    bool hit_solid = false;
    vec3 solid_hit_pos;
    
    for(int i = 0; i < 64; i++) {
        vec3 p = world_start + rd * t;
        float d = map_solid(p);
        
        if (d < 0.001) {
            hit_solid = true;
            solid_hit_pos = p;
            break;
        }
        t += d;
        if (t > total_dist) break;
    }

    vec3 background_color = vec3(0.0);
    float final_alpha = 0.0;
    vec3 norm_sun_dir = normalize(sun_dir);
    
    float max_vol_dist = total_dist;
    
    if (hit_solid) {
        vec3 n = calc_normal(solid_hit_pos);
        float diff = max(dot(n, norm_sun_dir), 0.0);
        float shadow = calculate_light(solid_hit_pos + n * 0.05, norm_sun_dir, 0.5); 
        background_color = snow_color * (sun_color * diff * shadow + ambient_color);
        
        final_alpha = smoothstep(0.0, terrain_blend, max_ray_dist - t);
        max_vol_dist = t;
    }
	
	vec3 solid_albedo = background_color * final_alpha;
    
	if (show_cloud) {
	    float step_size = max_vol_dist / float(max_steps);
	    vec3 world_step = rd * step_size;
	    
	    float dither = hash(FRAGCOORD.xy);
	    vec3 current_pos = world_start + world_step * dither;
	    
	    float transmittance = 1.0;
	    vec3 scattered_light = vec3(0.0);

	    for(int i = 0; i < max_steps; i++) {
	        float density = get_cloud_density(current_pos);
	        if (density > 0.0) {
	            float light_trans = calculate_light(current_pos, norm_sun_dir, 100.);
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