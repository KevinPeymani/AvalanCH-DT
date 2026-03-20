#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, rgba32f) uniform image3D jfa_in;
layout(set = 0, binding = 1, rgba32f) uniform image3D jfa_out;

layout(push_constant) uniform Constants {
    int step_size;
    int pad1; // Padding to meet 16-byte alignment
    int pad2;
    int pad3;
} pc;

void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(jfa_in);
    
    vec3 best_seed = imageLoad(jfa_in, pos).xyz;
    float min_dist = (best_seed.x < 0.0) ? 1e10 : distance(vec3(pos), best_seed);

    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                ivec3 offset = ivec3(x, y, z) * pc.step_size;
                ivec3 neighbor_pos = pos + offset;

                if (neighbor_pos.x >= 0 && neighbor_pos.x < size.x &&
                    neighbor_pos.y >= 0 && neighbor_pos.y < size.y &&
                    neighbor_pos.z >= 0 && neighbor_pos.z < size.z) {
                    
                    vec4 neighbor_data = imageLoad(jfa_in, neighbor_pos);
                    if (neighbor_data.w > 0.5) {
                        float d = distance(vec3(pos), neighbor_data.xyz);
                        if (d < min_dist) {
                            min_dist = d;
                            best_seed = neighbor_data.xyz;
                        }
                    }
                }
            }
        }
    }
    float valid = (best_seed.x < 0.0) ? 0.0 : 1.0;
    imageStore(jfa_out, pos, vec4(best_seed, valid));
    // imageStore(jfa_out, pos, vec4(best_seed, 1.0));
}