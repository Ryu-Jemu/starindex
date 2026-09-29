// Sky color shader (plan 4.4). Must stay 1:1 with SkyCore.SkyColorModel (CPU reference, T17).
// Inputs are LINEAR sRGB; the result is encoded with the sRGB OETF right before returning.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float HORIZON_EXP = 3.0;

static float oetf(float x) {
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// rect: viewport (x, y, w, h) · f: focal length in points · r0..r2: rows of device→HOR rotation
/// sun: unit vector toward the (refracted) Sun · cZ/cA/cS: zenith / anti-sun / sun-side horizon
/// cNight: moon + light-pollution term · cGround · misc = (glowStrength, glowWidth, cloud, nightGlow)
[[ stitchable ]] half4 skyColor(float2 p, float4 rect, float f,
                                float3 r0, float3 r1, float3 r2, float3 sun,
                                float3 cZ, float3 cA, float3 cS, float3 cNight, float3 cGround,
                                float4 misc) {
    float2 c0 = rect.xy + 0.5 * rect.zw;
    float3 v = normalize(float3((p.x - c0.x) / f, -(p.y - c0.y) / f, -1.0));
    float3 d = float3(dot(r0, v), dot(r1, v), dot(r2, v));
    float mu = d.z;
    float t = pow(1.0 - saturate(mu), HORIZON_EXP);
    float2 nd = d.xy * rsqrt(max(dot(d.xy, d.xy), 1e-8));
    float side = 0.5 + 0.5 * dot(nd, sun.xy);           // sun.xy not normalized: |.| = cos h_sun
    float3 base = mix(cZ, mix(cA, cS, side), t);
    float glow = misc.x * exp(-(1.0 - dot(d, sun)) / max(misc.y, 1e-3)) * t * smoothstep(-0.02, 0.0, mu);
    float3 col = base + glow * cS + misc.w * cNight;
    float cloud = misc.z;
    col = mix(col, float3(luma(col) * (1.0 - 0.25 * cloud)), 0.7 * cloud);
    col = mix(cGround, col, smoothstep(-0.10, 0.0, mu));
    col = saturate(col);
    return half4(half(oetf(col.r)), half(oetf(col.g)), half(oetf(col.b)), 1.0h);
}
