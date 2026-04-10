shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D height_tex : hint_default_black, filter_linear_mipmap, repeat_disable;

uniform vec3 uv_scale_albedo = vec3(1.0);
uniform vec3 uv_offset_albedo = vec3(0.0);
uniform vec3 uv_scale_height = vec3(1.0);
uniform vec3 uv_offset_height = vec3(0.0);

uniform float height_scale = 100.0; 
uniform float skirt_depth = 20.0;
uniform bool use_debug = false;
uniform vec3 debug_color = vec3(1.0);

uniform vec4 stitch_edges = vec4(0.0);

// Must match mesh_subdivisions in the GDScript (e.g. 32.0).
uniform float mesh_subdivisions = 32.0;


void vertex() {
	vec2 uv = UV;


	// ---- Edge-stitch snapping ----
	// coarse_step: the UV spacing of one vertex on a tile one LOD coarser.
	float coarse_step = 2.0 / mesh_subdivisions;

	// North edge: UV.y == 0.0  (PlaneMesh: top = UV.y 0, bottom = UV.y 1)
	if (stitch_edges.x > 0.5 && uv.y < 0.001) {
		uv.x = round(uv.x / coarse_step) * coarse_step;
	}
	// South edge: UV.y == 1.0
	if (stitch_edges.y > 0.5 && uv.y > 0.999) {
		uv.x = round(uv.x / coarse_step) * coarse_step;
	}
	// West edge: UV.x == 0.0
	if (stitch_edges.z > 0.5 && uv.x < 0.001) {
		uv.y = round(uv.y / coarse_step) * coarse_step;
	}
	// East edge: UV.x == 1.0
	if (stitch_edges.w > 0.5 && uv.x > 0.999) {
		uv.y = round(uv.y / coarse_step) * coarse_step;
	}
	// ---- End stitch snapping ----

	vec2 inset_uv = uv * (127.0 / 128.0) + (0.5 / 128.0);
	vec2 height_uv = inset_uv * uv_scale_height.xy + uv_offset_height.xy;
	vec4 h_sample = texture(height_tex, height_uv);
	
	float h = h_sample.r;
	if (h_sample.a < 0.1) {
		h = 0.0;
	}
	
	VERTEX.y += h * height_scale;
	
	if (uv.x < 0.001 || uv.x > 0.999 || uv.y < 0.001 || uv.y > 0.999) {
		VERTEX.y -= skirt_depth;
	}


	// Height displacement (your existing logic, using snapped UV).
	// Replace "UV" with "uv" in the height sample below.
	// Example (adapt to match your actual shader):
	//
	//   vec2 h_uv = uv * uv_scale_height.xy + uv_offset_height.xy;
	//   float h   = texture(height_tex, h_uv).r;
	//   VERTEX.y  = h * height_scale - skirt_depth * float(
	//                   abs(UV.x) < 0.001 || abs(UV.x - 1.0) < 0.001 ||
	//                   abs(UV.y) < 0.001 || abs(UV.y - 1.0) < 0.001);
	//
	// The skirt pushes edge vertices DOWN so they hide under neighbours.
	// Use the ORIGINAL UV for the skirt test (all edge verts get skirted),
	// but the SNAPPED uv for the height sample.
}


void fragment() {
	if (use_debug) {
		ALBEDO = debug_color;
	} else {
		vec2 albedo_uv = UV * uv_scale_albedo.xy + uv_offset_albedo.xy;
		ALBEDO = texture(albedo_tex, albedo_uv).rgb;
	}
}
