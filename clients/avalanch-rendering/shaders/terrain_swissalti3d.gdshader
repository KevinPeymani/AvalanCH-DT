shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D height_tex : hint_default_black, filter_linear_mipmap, repeat_disable;

uniform vec3 uv_scale_albedo = vec3(1.0);
uniform vec3 uv_offset_albedo = vec3(0.0);
uniform vec3 uv_scale_height = vec3(1.0);
uniform vec3 uv_offset_height = vec3(0.0);

uniform float height_scale = 100.0; 
uniform bool use_debug = false;
uniform vec3 debug_color = vec3(1.0);

void vertex() {
	vec2 height_uv = UV * uv_scale_height.xy + uv_offset_height.xy;
	vec4 h_sample = texture(height_tex, height_uv);
	
	float h = h_sample.r;
	if (h_sample.a < 0.1) {
		h = 0.0;
	}
	
	VERTEX.y += h * height_scale;
}

void fragment() {
	if (use_debug) {
		ALBEDO = debug_color;
	} else {
		vec2 albedo_uv = UV * uv_scale_albedo.xy + uv_offset_albedo.xy;
		ALBEDO = texture(albedo_tex, albedo_uv).rgb;
	}
}