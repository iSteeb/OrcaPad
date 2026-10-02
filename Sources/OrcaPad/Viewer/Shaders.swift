// MARK: - Metal Shading Language sources
//
// NOTE: The Linux/xtool toolchain cannot compile .metallib files (Apple's
// offline Metal compiler is macOS-only). Shaders are therefore compiled at
// runtime from these source strings via MTLDevice.makeLibrary(source:).
// Cost: a few ms of app-launch time. Keep all MSL in this file.

enum Shaders {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;

    // --- Lit (triangles) ---
    struct CubeUniforms {
        float4x4 mvp;
        float4x4 model;
        float4 color;
        float3 lightDir;
        float pad;
    };

    struct VIn {
        float3 position [[attribute(0)]];
        float3 normal   [[attribute(1)]];
    };

    struct VOutLit {
        float4 position [[position]];
        float3 worldNormal;
    };

    vertex VOutLit vertexMain(VIn in [[stage_in]],
                              constant CubeUniforms &u [[buffer(1)]]) {
        VOutLit out;
        out.position = u.mvp * float4(in.position, 1.0);
        out.worldNormal = (u.model * float4(in.normal, 0.0)).xyz;
        return out;
    }

    fragment float4 fragmentLit(VOutLit in [[stage_in]],
                                constant CubeUniforms &u [[buffer(1)]]) {
        float3 n = normalize(in.worldNormal);
        float3 l = -normalize(u.lightDir);
        float lambert = saturate(dot(n, l));
        float shade = 0.30 + 0.70 * lambert;
        return float4(u.color.rgb * shade, 1.0);
    }

    // --- Flat (lines) ---
    struct LineUniforms {
        float4x4 mvp;
    };

    struct VInLine {
        float3 position [[attribute(0)]];
        float4 color    [[attribute(1)]];
    };

    struct VOutFlat {
        float4 position [[position]];
        float4 color;
    };

    vertex VOutFlat vertexFlat(VInLine in [[stage_in]],
                               constant LineUniforms &u [[buffer(1)]]) {
        VOutFlat out;
        out.position = u.mvp * float4(in.position, 1.0);
        out.color = in.color;
        return out;
    }

    fragment float4 fragmentFlat(VOutFlat in [[stage_in]]) {
        return in.color;
    }
    """
}
