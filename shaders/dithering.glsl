#pragma language glsl3

extern float strength;
extern float color_levels;

float randomValue(vec2 p) {
    return fract(
        sin(dot(p, vec2(127.1, 311.7))) *
        43758.5453
    );
}

vec4 effect(
    vec4 color,
    Image texture,
    vec2 uv,
    vec2 screen_coords
) {
    vec4 pixel = Texel(texture, uv) * color;

    float noise = randomValue(screen_coords) - 0.5;

    pixel.rgb += noise * strength / 255.0;

    float levels = max(color_levels, 1.0);

    pixel.rgb =
        floor(pixel.rgb * levels + 0.5) / levels;

    return pixel;
}