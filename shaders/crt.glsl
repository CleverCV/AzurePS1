#pragma language glsl3

extern float scanline_strength;
extern float curvature;
extern float vignette_strength;
extern vec2 resolution;

vec4 effect(
    vec4 color,
    Image texture,
    vec2 uv,
    vec2 screen_coords
) {
    vec2 centered = uv * 2.0 - 1.0;

    vec2 curved = centered;

    curved *= 1.0 + curvature *
        vec2(centered.y * centered.y,
             centered.x * centered.x);

    vec2 warped_uv = curved * 0.5 + 0.5;

    if (
        warped_uv.x < 0.0 ||
        warped_uv.x > 1.0 ||
        warped_uv.y < 0.0 ||
        warped_uv.y > 1.0
    ) {
        return vec4(0.0, 0.0, 0.0, 1.0);
    }

    vec4 pixel = Texel(texture, warped_uv) * color;

    float scanline = sin(
        warped_uv.y * resolution.y * 3.14159265
    );

    pixel.rgb *= 1.0 - scanline_strength *
        (0.5 + 0.5 * scanline);

    float vignette = 1.0 -
        vignette_strength *
        dot(centered, centered);

    pixel.rgb *= clamp(vignette, 0.0, 1.0);

    return pixel;
}