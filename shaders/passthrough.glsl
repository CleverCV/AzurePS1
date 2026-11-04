#pragma language glsl3

vec4 effect(
    vec4 color,
    Image texture,
    vec2 uv,
    vec2 screen_coords
) {
    return Texel(texture, uv) * color;
}