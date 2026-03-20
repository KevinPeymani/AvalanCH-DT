shader_type spatial;

uniform sampler2D terrain: repeat_disable;
uniform float height_scale: hint_range(0.0, 0.001, 0.0000001) = 0.001;
uniform vec2 mesh_size = vec2(2.0, 2.0);


uniform vec3 grass_dark : source_color = vec3(0.15, 0.22, 0.10);
uniform vec3 grass_light : source_color = vec3(0.25, 0.35, 0.15);
uniform vec3 rock_dark : source_color = vec3(0.20, 0.20, 0.20);
uniform vec3 rock_light : source_color = vec3(0.35, 0.32, 0.30);
uniform vec3 snow_color : source_color = vec3(0.90, 0.95, 1.00);

uniform float terrain_scale = 1000.0;
uniform float snow_height = 1800.0;
uniform float snow_spread = 250.0;
uniform float slope_threshold = 0.75;
uniform float slope_spread = 0.2;

varying vec3 v_pos;
varying vec3 v_norm;

// const float min_h = 999.0;
// const float max_h = 2934.625;
// const float min_h = 0.0;
// const float max_h = 2934.625;
uniform float min_h = 999.0;
uniform float max_h = 3009.0;


void vertex() {
	ivec2 tex_size = textureSize(terrain, 0);
	ivec2 coord = ivec2(UV * vec2(tex_size) * 0.9999);

    vec2 spacing = mesh_size / vec2(tex_size);

    float h = (texelFetch(terrain, coord, 0).r - min_h) / (max_h - min_h);
    VERTEX.y = h;

    float h_left  = texelFetch(terrain, clamp(coord + ivec2(-1, 0), ivec2(0), tex_size - 1), 0).r * height_scale;
	float h_right = texelFetch(terrain, clamp(coord + ivec2( 1, 0), ivec2(0), tex_size - 1), 0).r * height_scale;
	float h_up    = texelFetch(terrain, clamp(coord + ivec2(0, -1), ivec2(0), tex_size - 1), 0).r * height_scale;
	float h_down  = texelFetch(terrain, clamp(coord + ivec2(0,  1), ivec2(0), tex_size - 1), 0).r * height_scale;

	vec3 v_x = vec3(spacing.x * 2.0, h_right - h_left, 0.0);
	vec3 v_z = vec3(0.0, h_down - h_up, spacing.y * 2.0);
	NORMAL = normalize(cross(v_z, v_x));
	
	v_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_norm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float noise(vec3 x) {
	vec3 p = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(p + vec3(0,0,0)), hash(p + vec3(1,0,0)), f.x),
			       mix(hash(p + vec3(0,1,0)), hash(p + vec3(1,1,0)), f.x), f.y),
		       mix(mix(hash(p + vec3(0,0,1)), hash(p + vec3(1,0,1)), f.x),
			       mix(hash(p + vec3(0,1,1)), hash(p + vec3(1,1,1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float f = 0.0;
	float amp = 0.5;
	for(int i = 0; i < 5; i++) {
		f += amp * noise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return f;
}

void fragment() {
	vec3 scaled_pos = v_pos / terrain_scale;
	
	float n_terrain = fbm(scaled_pos * 0.2);
	float n_macro = fbm(scaled_pos * 2.0);
	float n_micro = fbm(scaled_pos * 50.0);
	float n_detail = fbm(scaled_pos * 500.0);
	
	vec3 grass = mix(grass_dark, grass_light, fbm(scaled_pos * 15.0));
	vec3 rock = mix(rock_dark, rock_light, fbm(scaled_pos * 25.0));
	
	float slope = dot(v_norm, vec3(0.0, 1.0, 0.0));
	float slope_noise = (n_macro * 0.5 + n_micro * 0.3 + n_detail * 0.2) * slope_spread;
	float slope_mask = step(slope_threshold - slope_noise, slope);
	
	float height_noise = (10. * (n_terrain - 0.5) + n_macro * 0.6 + n_micro * 0.3 + n_detail * 0.1) * snow_spread;
	float snow_mask = step(snow_height - height_noise, v_pos.y);
	
	vec3 final_color = mix(rock, grass, slope_mask);
	ALBEDO = mix(final_color, snow_color, snow_mask);
	
	ROUGHNESS = mix(0.85, 0.5, snow_mask) - (n_micro * 0.1);
	SPECULAR = 0.1;
}
