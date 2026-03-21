shader_type spatial;

render_mode unshaded, depth_test_disabled, depth_draw_never;

uniform sampler2D depth_texture : hint_depth_texture;

// raymarching from https://godotshaders.com/shader/ray-box-setup/
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

void fragment() {
	vec3 rd = -VIEW;
	vec3 ro = VERTEX - rd * VERTEX.z/rd.z;
	vec3 s = ro;

	mat4 inv_modelview = inverse(VIEW_MATRIX * MODEL_MATRIX);
	vec3 cam_pos = (inverse(VIEW_MATRIX) * vec4(ro, 1)).xyz;
	ro = (inv_modelview * vec4(ro,1)).xyz;
	rd = normalize( mat3(inv_modelview) * rd );

	vec3 n;
	vec2 result = boxIntersection(ro, rd, vec3(2000), n);
	
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float linear_depth = -view.z;


	float t = max(result.x, 0.0);
	vec3 point_box_entry = ro + rd * t;
	
	// ALGO
	vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 impact_scene = world.xyz / world.w;

	// discard any rays that made it all the way through the box
	if(result.y < t) discard;
	//if(linear_depth < (result.y + 10000.)) discard;

	// ALBEDO = vec3(mod((t-linear_depth), 100.)/100.);
	ALBEDO = impact_scene;
	ALBEDO = (inverse(VIEW_MATRIX) * vec4(s,1)).xyz;
	vec3 box_point = (MODEL_MATRIX * vec4(rd, 1) * t).xyz + cam_pos;
	ALBEDO = vec3(fract(length(impact_scene - box_point)/1000.));
	//ALBEDO = vec3(1., 0., 0.);
}