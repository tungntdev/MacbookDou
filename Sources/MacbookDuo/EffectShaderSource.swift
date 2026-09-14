/// The render pipeline's Metal Shading Language source, compiled at launch
/// with `MTLDevice.makeLibrary(source:options:)`.
///
/// Kept as a runtime-compiled string (rather than a `.metal` file compiled
/// into a `.metallib` at build time) because Swift Package Manager's default
/// build system does not compile `.metal` sources for a plain executable
/// target the way Xcode's build system does.
enum EffectShaderSource {
    static let code = """
    #include <metal_stdlib>
    using namespace metal;

    // Kept in sync by hand with the Swift `EffectUniforms` struct in
    // EffectRenderer.swift: three float4 columns (xyz used, w padding) for
    // the screen->picture homography, followed by plain scalars in
    // declaration order.
    struct EffectUniforms {
        float4 pictureColumn0;
        float4 pictureColumn1;
        float4 pictureColumn2;
        float pointsPerPixel;
        float viewHeightPoints;
        float pictureWidthPoints;
        float pictureHeightPoints;
        float paddingPoints;
        float maxMipLevel;
        float maxBlurRadiusPixels;
        float blurStrength;
        float blurFloor;
        float dimStrength;
        float dimFloor;
        float dimReach;
    };

    struct VertexOut {
        float4 position [[position]];
    };

    // The classic "big triangle" trick: three vertices that overdraw past
    // every clip-space edge cover the whole viewport with a single
    // triangle, so no vertex/index buffer for a quad is needed.
    vertex VertexOut depthVertexMain(uint vertexID [[vertex_id]]) {
        float2 corners[3] = { float2(-1, -3), float2(-1, 1), float2(3, 1) };
        VertexOut out;
        out.position = float4(corners[vertexID], 0, 1);
        return out;
    }

    fragment float4 depthFragmentMain(
        VertexOut in [[stage_in]],
        texture2d<float> picture [[texture(0)]],
        constant EffectUniforms &u [[buffer(0)]]
    ) {
        constexpr sampler pictureSampler(mip_filter::linear, mag_filter::linear, min_filter::linear, address::clamp_to_edge);

        float2 screenPoint = float2(
            in.position.x * u.pointsPerPixel,
            u.viewHeightPoints - in.position.y * u.pointsPerPixel
        );

        float3x3 screenToPicture = float3x3(u.pictureColumn0.xyz, u.pictureColumn1.xyz, u.pictureColumn2.xyz);
        float3 mapped = screenToPicture * float3(screenPoint, 1.0);
        float2 picturePoint = mapped.xy / mapped.z;

        float pad = u.paddingPoints;
        float u0 = (picturePoint.x + pad) / (u.pictureWidthPoints + 2 * pad);
        float v0 = (u.pictureHeightPoints - picturePoint.y + pad) / (u.pictureHeightPoints + 2 * pad);

        if (u0 < 0 || u0 > 1 || v0 < 0 || v0 > 1) {
            return float4(0, 0, 0, 1);
        }

        float height = saturate(picturePoint.y / max(u.pictureHeightPoints, 1.0));

        float blurAmount = u.blurStrength * mix(u.blurFloor, 1.0, height);
        float mipLevel = clamp(log2(max(blurAmount * u.maxBlurRadiusPixels, 1.0)), 0.0, u.maxMipLevel);
        float4 color = picture.sample(pictureSampler, float2(u0, v0), level(mipLevel));

        float spread = smoothstep(0.0, max(u.dimReach, 0.02), height);
        float fade = u.dimStrength * mix(u.dimFloor, 1.0, spread);
        float keep = pow(saturate(1.0 - fade), 2.2);
        color.rgb *= keep;

        return float4(color.rgb, 1.0);
    }
    """
}
