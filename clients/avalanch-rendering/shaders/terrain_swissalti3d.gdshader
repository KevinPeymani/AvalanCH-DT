shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D height_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform sampler2D snow_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform sampler2D danger_tex : hint_default_black, filter_linear_mipmap, repeat_disable;

uniform vec3 uv_scale_albedo = vec3(1.0);
uniform vec3 uv_offset_albedo = vec3(0.0);
uniform vec3 uv_scale_height = vec3(1.0);
uniform vec3 uv_offset_height = vec3(0.0);
uniform vec3 uv_scale_snow = vec3(1.0);
uniform vec3 uv_offset_snow = vec3(0.0);
uniform vec3 uv_scale_danger = vec3(1.0);
uniform vec3 uv_offset_danger = vec3(0.0);

uniform float height_scale = 100.0; 
uniform float skirt_depth = 20.0;
uniform bool use_debug = false;
uniform vec3 debug_color = vec3(1.0);
uniform bool use_snow_overlay = false;
uniform bool use_danger_overlay = false;
uniform float snow_min_m = 0.0;
uniform float snow_max_m = 8.0;
uniform float danger_min = 0.0;
uniform float danger_max = 5.0;
uniform float snow_opacity = 0.65;
uniform float danger_opacity = 0.55;
uniform float snow_vis_min = 0.00;
uniform float snow_vis_max = 0.95;
uniform float snow_vis_gamma = 1.45;
uniform bool snow_use_bands = true;
uniform float snow_band_count = 7.0;

uniform vec4 stitch_edges = vec4(0.0);

// Must match mesh_subdivisions in the GDScript (e.g. 32.0).
uniform float mesh_subdivisions = 32.0;

vec3 snow_ramp(float t) {
	vec3 c0 = vec3(0.05, 0.10, 0.26);
	vec3 c1 = vec3(0.12, 0.25, 0.48);
	vec3 c2 = vec3(0.24, 0.45, 0.70);
	vec3 c3 = vec3(0.45, 0.66, 0.86);
	vec3 c4 = vec3(0.72, 0.86, 0.96);

	if (t < 0.25) return mix(c0, c1, t / 0.25);
	if (t < 0.50) return mix(c1, c2, (t - 0.25) / 0.25);
	if (t < 0.75) return mix(c2, c3, (t - 0.50) / 0.25);
	return mix(c3, c4, (t - 0.75) / 0.25);
}

vec3 danger_ramp(float t) {
	vec3 c0 = vec3(0.20, 0.80, 0.20);
	vec3 c1 = vec3(0.95, 0.85, 0.20);
	vec3 c2 = vec3(0.95, 0.55, 0.15);
	vec3 c3 = vec3(0.90, 0.20, 0.10);
	vec3 c4 = vec3(0.55, 0.00, 0.00);

	if (t < 0.25) return mix(c0, c1, t / 0.25);
	if (t < 0.50) return mix(c1, c2, (t - 0.25) / 0.25);
	if (t < 0.75) return mix(c2, c3, (t - 0.50) / 0.25);
	return mix(c3, c4, (t - 0.75) / 0.25);
}


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
		vec3 col = texture(albedo_tex, albedo_uv).rgb;

		if (use_snow_overlay) {
			vec2 snow_uv = UV * uv_scale_snow.xy + uv_offset_snow.xy;
			vec4 s = texture(snow_tex, snow_uv);
			if (s.a > 0.1) {
				float snow_norm = clamp(1.0 - s.r, 0.0, 1.0);
				float snow_scaled = clamp((snow_norm - snow_vis_min) / max(snow_vis_max - snow_vis_min, 0.0001), 0.0, 1.0);
				snow_scaled = pow(snow_scaled, snow_vis_gamma);
				if (snow_use_bands) {
					float bands = max(snow_band_count, 2.0);
					float band_index = floor(snow_scaled * bands);
					float band_t = clamp(band_index / (bands - 1.0), 0.0, 1.0);
					col = mix(col, snow_ramp(band_t), clamp(snow_opacity, 0.0, 1.0));
				} else {
					col = mix(col, snow_ramp(snow_scaled), clamp(snow_opacity, 0.0, 1.0));
				}
			}
		}

		if (use_danger_overlay) {
			vec2 danger_uv = UV * uv_scale_danger.xy + uv_offset_danger.xy;
			vec4 d = texture(danger_tex, danger_uv);
			if (d.a > 0.1) {
				float danger_norm = clamp(1.0 - d.r, 0.0, 1.0);
				col = mix(col, danger_ramp(danger_norm), clamp(danger_opacity, 0.0, 1.0));
			}
		}

		ALBEDO = col;
	}
}
