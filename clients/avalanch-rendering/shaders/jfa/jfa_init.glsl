#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0) uniform sampler2D heightmap;
layout(set = 0, binding = 1) uniform sampler2D hflow;
layout(set = 0, binding = 2, rgba32f) uniform writeonly image3D jfa_data;

layout(push_constant, std430) uniform Params {
    vec2 height_range;
    float hflow_scale;
} params;

void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(jfa_data);
    if (any(greaterThanEqual(pos, size))) return;

    vec2 uv = vec2(pos.x, pos.y) / vec2(size.x, size.y);
    float h = (texture(heightmap, uv).r - params.height_range.x) / (params.height_range.y - params.height_range.x);
    float f_ps = texture(hflow, uv).r;
    float f = f_ps / (params.height_range.y - params.height_range.x) * params.hflow_scale;
    float surface_z = (h + f) * float(size.z);
    int surface_z_coord = clamp(int(floor(surface_z)), 0, size.z);

    float epsilon = 1./150.;

    bool edge = texture(hflow, uv + vec2(epsilon, 0)).r <= 0.001 ||
                texture(hflow, uv + vec2(-epsilon, 0)).r <= 0.001 ||
                texture(hflow, uv + vec2(0, epsilon)).r <= 0.001 ||
                texture(hflow, uv + vec2(0, -epsilon)).r <= 0.001;

    bool has_snow = f_ps > 0.001;
    float w = ((pos.z == 0 || pos.z == surface_z_coord || (pos.z <= surface_z_coord && edge)) && has_snow) ? 1. : 0.;
    vec3 seed_pos = (w > 0.5) ? vec3(pos) : vec3(-1.0);

    imageStore(jfa_data, pos, vec4(seed_pos, w));
}