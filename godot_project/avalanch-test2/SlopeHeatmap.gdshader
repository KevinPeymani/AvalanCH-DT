shader_type spatial;

// Cesium automatically looks for this name to pass the imagery
uniform sampler2D base_texture : source_color; 
uniform float heatmap_opacity : hint_range(0.0, 1.0) = 0.5;

void fragment() {
    // 1. Pull the actual Swiss satellite image
    vec4 tex_color = texture(base_texture, UV);
    
    // 2. Your existing slope calculation
    float slope = acos(dot(NORMAL, vec3(0.0, 1.0, 0.0)));
    float slope_degrees = degrees(slope);

    vec3 final_color = tex_color.rgb;

    // 3. Layer the heatmap OVER the imagery
    if (slope_degrees >= 30.0 && slope_degrees < 35.0) {
        final_color = mix(tex_color.rgb, vec3(1.0, 1.0, 0.0), heatmap_opacity);
    } 
    else if (slope_degrees >= 35.0 && slope_degrees < 45.0) {
        final_color = mix(tex_color.rgb, vec3(1.0, 0.0, 0.0), heatmap_opacity);
    } 
    else if (slope_degrees >= 45.0) {
        final_color = mix(tex_color.rgb, vec3(0.5, 0.0, 1.0), heatmap_opacity);
    }

    ALBEDO = tex_color.rgb;
}