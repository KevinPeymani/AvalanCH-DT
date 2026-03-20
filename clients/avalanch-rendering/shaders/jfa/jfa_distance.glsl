#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, rgba32f) uniform image3D jfa_final;
layout(set = 0, binding = 1, r32f) uniform image3D sdf_out;
layout(set = 0, binding = 2) uniform sampler2D heightmap;
layout(set = 0, binding = 3) uniform sampler2D hflow;

layout(push_constant, std430) uniform Params {
    vec2 height_range;
    float hflow_scale;
} params;

void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(jfa_final);
    if (pos.x >= size.x || pos.y >= size.y || pos.z >= size.z) return;

    vec4 data = imageLoad(jfa_final, pos);
    float dist = 1.0; 

    if (data.w > 0.5) {
        float d = distance(vec3(pos), data.xyz);
        dist = d / float(max(size.x, max(size.y, size.z)));
    }

    vec2 uv = vec2(pos.x, pos.y) / vec2(size.x, size.y);
    float h = (texture(heightmap, uv).r - params.height_range.x) / (params.height_range.y - params.height_range.x);
    float f_ps = texture(hflow, uv).r;
    float f = f_ps / (params.height_range.y - params.height_range.x) * params.hflow_scale;
    
    float terrain_z = h * float(size.z);
    float surface_z = (h + f) * float(size.z);

    if (pos.z <= ceil(surface_z) && f_ps > 0.001) {
        dist = -dist;
    }

    imageStore(sdf_out, pos, vec4(dist, 0.0, 0.0, 1.0));
}