#pragma language glsl3

extern float pixel_size;

vec4 effect(
    vec4 color,
    Image texture,
    vec2 uv,
    vec2 screen_coords
) {
    vec2 size = vec2(
        max(pixel_size, 1.0)
    );

    vec2 resolution = love_ScreenSize.xy;

    vec2 pixel_uv =
        floor(uv * resolution / size) *
        size / resolution;

    return Texel(texture, pixel_uv) * color;
}