#pragma language glsl3

extern vec2 resolution;
extern float color_depth;
extern float dithering;
extern float pixelation;

vec4 effect(
    vec4 color,
    Image texture,
    vec2 texture_coords,
    vec2 screen_coords
) {
    vec2 uv = texture_coords;

    vec2 pixel_size = vec2(1.0) / resolution;
    uv = floor(uv / pixel_size) * pixel_size;

    vec4 pixel = Texel(texture, uv) * color;

    float levels = max(color_depth, 1.0);
    pixel.rgb = floor(pixel.rgb * levels + 0.5) / levels;

    float noise = fract(
        sin(dot(screen_coords, vec2(12.9898, 78.233)))
        * 43758.5453
    ) - 0.5;

    pixel.rgb += noise * dithering / 255.0;

    return pixel;
}