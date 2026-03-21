shader_type spatial;
render_mode blend_premul_alpha, depth_test_disabled, cull_back, unshaded;

uniform vec3 sun_dir = vec3(0.5, 0.8, 0.3);
uniform vec3 sun_color = vec3(1.0, 0.95, 0.9);
uniform vec3 ambient_color = vec3(0.2, 0.25, 0.35);
uniform vec3 snow_color = vec3(0.9, 0.95, 1.0);

uniform float density_multiplier = 10.0;
uniform float terrain_blend = 1.0;

uniform int max_steps = 64;

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

float sdVerticalCapsule( vec3 p, float h, float r )
{
  p.y -= clamp( p.y, 0.0, h );
  return length( p ) - r;
}

float sdRoundCone( vec3 p, float r1, float r2, float h )
{
  float b = (r1-r2)/h;
  float a = sqrt(1.0-b*b);

  vec2 q = vec2( length(p.xz), p.y );
  float k = dot(q,vec2(-b,a));
  if( k<0.0 ) return length(q) - r1;
  if( k>a*h ) return length(q-vec2(0.0,h)) - r2;
  return dot(q, vec2(a,b) ) - r1;
}

float trunk(vec3 p, vec3 id) {
	return sdVerticalCapsule(p, 1., 0.1);
}

float leaves(vec3 p, vec3 id) {
	return sdRoundCone(p - vec3(0., 1., 0.), 0.5, 0.2, 1.3);
}

float sdf(vec3 p, vec3 rid) {
	vec3 pt = p - vec3(rid.x, 0., rid.z) * 0.2;
	return min(trunk(pt, rid), leaves(pt, rid));
}

float repeated( vec3 p, float s )
{
    vec3 id = round(p/s);
    vec3  o = sign(p-s*id);
    
    float d = 1e20;
    for( int j=0; j<2; j++ )
    for( int i=0; i<2; i++ )
    {
        vec3 rid = id + vec3(float(i),float(j),0.)*o;
        vec3 r = p - s*rid;
        d = min( d, sdf(r, rid) );
    }
    return d;
}


float map_solid(vec3 p) {
	return repeated(p, 3.);
	vec2 spacing = vec2(3.);
	float h = hash(round(p.xz / spacing));
	p.xz = p.xz - round(p.xz / spacing) * spacing;
	vec4 pa = vec4(p + h * vec3(1., 0., 0.), h);
	return sdf(pa.xyz, pa.www);
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

float calculate_light(vec3 p, vec3 light_dir, float shadow_step) {
    //float shadow_step = 0.5;
    float transmittance = 1.0;
    vec3 current_pos = p + light_dir * 0.5;
    
    for(int i = 0; i < 40; i++) {
        if (map_solid(current_pos) < 0.0) {
            transmittance *= 0.1;
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
    
    for(int i = 0; i < 128; i++) {
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
	ALBEDO = solid_albedo;
	ALPHA = final_alpha;
}