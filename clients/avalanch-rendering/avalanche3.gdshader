shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, unshaded;

uniform vec3 sphere_center = vec3(0.);
uniform vec3 sun_dir = vec3(0.5, 0.8, 0.3);
uniform vec3 sun_color = vec3(1.0, 0.95, 0.9);
uniform vec3 ambient_color = vec3(0.2, 0.25, 0.35);
uniform vec3 snow_color = vec3(0.9, 0.95, 1.0);
uniform float density_multiplier = 10.0;
uniform float sphere_radius = 2.0;
uniform int max_steps = 64;

uniform float noise_freq = 1.;
uniform float noise_amp = 20.;

varying vec3 world_camera;
varying vec3 world_position;

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_camera = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
}

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
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

float get_density(vec3 p) {
    vec3 local_p = p - sphere_center;
    float displacement = sin(local_p.x * noise_freq) * sin(local_p.y * noise_freq) * sin(local_p.z * noise_freq) * noise_amp;
	float distance_to_sphere = length(local_p) - (sphere_radius + displacement);
    float d = -pow(-distance_to_sphere / sphere_radius, 1.0);
    return -min(0.0, d * density_multiplier);
}

float calculate_light(vec3 p, vec3 light_dir, float step_size) {
    float transmittance = 1.0;
    vec3 current_pos = p + light_dir * 0.5;
    for(int i = 0; i < 48; i++) {
        current_pos += light_dir * step_size * 2.0;
        float d = get_density(current_pos);
        transmittance *= exp(-d * step_size * 2.0);
    }
    return transmittance;
}

void fragment() {
    vec3 ray_dir = normalize(world_position - world_camera);
    
    mat4 inv_model = inverse(MODEL_MATRIX);
    vec3 local_ro = (inv_model * vec4(world_camera, 1.0)).xyz;
    vec3 local_rd = normalize((inv_model * vec4(ray_dir, 0.0)).xyz);
    
    vec2 hit = intersect_aabb(local_ro, local_rd, vec3(-1.0), vec3(1.0));
    
    if (hit.x > hit.y || hit.y < 0.0) {
        discard;
    }

    hit.x = max(hit.x, 0.0);
    
    vec3 node_center = MODEL_MATRIX[3].xyz;
    vec3 norm_sun_dir = normalize(sun_dir);
    
    vec3 local_start_pos = local_ro + local_rd * hit.x;
    vec3 world_start_pos = (MODEL_MATRIX * vec4(local_start_pos, 1.0)).xyz;
    vec3 world_end_pos = (MODEL_MATRIX * vec4(local_ro + local_rd * hit.y, 1.0)).xyz;
    float world_distance = length(world_end_pos - world_start_pos);
    
    float step_size = world_distance / float(max_steps);
    vec3 world_step = ray_dir * step_size;
    
    vec3 current_pos = world_start_pos;
    
    float transmittance = 1.0;
    vec3 scattered_light = vec3(0.0);

    for(int i = 0; i < max_steps; i++) {
        float density = get_density(current_pos);

        if (density > 0.0) {
            float light_trans = calculate_light(current_pos, norm_sun_dir, 10.);
            vec3 S = (sun_color * light_trans + ambient_color) * density * snow_color;

            float dt = density * step_size;
            float step_trans = exp(-dt);

            scattered_light += S * (transmittance - transmittance * step_trans) / density;
            transmittance *= step_trans;

            if (transmittance < 0.01) break;
        }
        current_pos += world_step;
    }

    ALBEDO = scattered_light;
    ALPHA = 1.0 - transmittance;
}