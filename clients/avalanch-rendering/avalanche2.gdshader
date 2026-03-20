shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never;

uniform sampler2D depth_texture : hint_depth_texture;
uniform sampler2D scene_texture : hint_screen_texture;

uniform sampler3D cloud_texture;

// axis aligned box centered at the origin, with size boxSize
vec2 boxIntersection( in vec3 ro, in vec3 rd, vec3 boxSize, out vec3 outNormal )
{
    vec3 m = 1.0/rd; // can precompute if traversing a set of aligned boxes
    vec3 n = m*ro;   // can precompute if traversing a set of aligned boxes
    vec3 k = abs(m)*boxSize;
    vec3 t1 = -n - k;
    vec3 t2 = -n + k;
    float tN = max( max( t1.x, t1.y ), t1.z );
    float tF = min( min( t2.x, t2.y ), t2.z );
    if( tN>tF || tF<0.0) return vec2(-1.0); // no intersection
    outNormal = (tN>0.0) ? step(vec3(tN),t1) : // ro ouside the box
                           step(t2,vec3(tF));  // ro inside the box
    outNormal *= -sign(rd);
    return vec2( tN, tF );
}

float sample_cloud(vec3 position) {
    float main_cloud = texture(cloud_texture, position / 2000.).r;
	float r = length(position - vec3(0.)) / 2000.;
    return clamp(1. - r, 0., 1.);
}

void fragment() {
	vec3 camera_position = CAMERA_POSITION_WORLD;
	
	vec3 ray_origin = camera_position.xyz;
	vec3 ray_direction = (INV_VIEW_MATRIX * (-vec4(VIEW, 0.))).xyz;
	
	mat4 inv_model = inverse(MODEL_MATRIX);
	vec3 ray_origin_model = (inv_model * vec4(ray_origin, 1.)).xyz;
	vec3 ray_direction_model = (inv_model * vec4(ray_direction, 0.)).xyz;
	
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);

	vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 world_position = world.xyz / world.w;
	
	vec3 outNormal;
	vec2 res = boxIntersection(ray_origin_model, ray_direction_model, vec3(1.), outNormal);
	
	vec3 intersection_near_model = ray_origin_model + ray_direction_model * res.x;
	vec3 intersection_near_world = (MODEL_MATRIX * vec4(intersection_near_model, 1.)).xyz;
	
	vec3 intersection_far_model = ray_origin_model + ray_direction_model * res.y;
	vec3 intersection_far_world = (MODEL_MATRIX * vec4(intersection_far_model, 1.)).xyz;
	
	const int max_steps = 100;
	float total_density = 0.;
	vec3 dir = normalize(intersection_far_world - intersection_near_world);
	float t = 0.;
	float max_t = length(intersection_far_world - intersection_near_world);
	float step_size = 10.;
	float cloud_threshold = 0.00001;
	float cloud_threshold_multiplier = 1.;
	for (int i = 0; i < max_steps && t < max_t; i++) {
		vec3 p = intersection_near_world + t * dir;
		t += step_size;
		float density = sample_cloud(p);
        //density = smoothstep(cloud_threshold - 0.05, cloud_threshold + cloud_threshold_multiplier, density);
        total_density += .001 * density * step_size;
	}
	
	total_density = clamp(total_density, 0., 1.);

	// ALBEDO = vec3(fract(length(intersection_near_world-camera_position)/1000.));
	ALBEDO = vec3(0.8, 0.8, 0.9) * total_density;
	ALPHA = total_density;
	//ALPHA = d;
}