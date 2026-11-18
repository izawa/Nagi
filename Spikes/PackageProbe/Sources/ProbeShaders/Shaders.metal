#include <metal_stdlib>
using namespace metal;

kernel void writeProbePixels(
    texture2d<half, access::write> output [[texture(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    uint index = position.y * output.get_width() + position.x;
    output.write(half4(half(index) * 0.25h, 0.5h, 1.0h, 1.0h), position);
}
