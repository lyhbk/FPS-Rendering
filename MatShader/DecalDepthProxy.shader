Shader "Custom/DecalDepthProxy"
{
    // ============================================================
    // 深度代理 (Depth Proxy)
    //
    // 用途:给「只有碰撞体、没有可见网格」的位置提供一个可供贴花采样的深度。
    //
    // 典型场景:
    //   房子 01
    //   ├── 01_1  只有 BoxCollider   → 射线命中目标
    //   └── 01_2  MeshFilter+Renderer → 给贴花的 SampleSceneDepth 提供深度
    //
    // 关键设计:
    //   1. ColorMask 0  → 不写任何颜色,画面上完全不可见,不会产生闪烁
    //   2. ZWrite On    → 仍然写深度,贴花的 SampleSceneDepth 能采到它
    //   3. Offset 1, 1  → 深度往后推一点,与真实墙面共面时【让墙面赢】,
    //                     只有在墙面没覆盖的像素上才由本代理兜底
    //                     → 既消除 Z-fighting,又保留兜底功能
    //   4. 不声明任何光照/贴图 → 无 fragment 输出,开销几乎为零
    // ============================================================
    Properties
    {
        [Header(Depth Offset)]
        // 正数 = 深度往后推(让真实墙面优先);负数 = 往前拉(让代理优先)
        _OffsetFactor("Offset Factor", Float) = 1.0
        _OffsetUnits("Offset Units", Float) = 1.0
        [Toggle(_STENCIL_KEEP)] _StencilKeep("保留模板(默认关)", Float) = 0
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            // 比默认 Geometry(2000) 早一点,确保在真实墙面之前写入深度,
            // 这样墙面之后用 ZTest LEqual 覆盖它,最终深度取墙面的
            "Queue" = "Geometry-1"
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 100
        Cull Back
        ZWrite On
        ZTest LEqual

        Pass
        {
            Name "DepthProxy"
            Tags { "LightMode" = "UniversalForward" }

            // 多边形偏移:把深度沿多边形平面法线方向推远,打破共面平局
            Offset [_OffsetFactor], [_OffsetUnits]

            // 关键:不写颜色通道,只写深度
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
            };

            Varyings vert(Attributes input)
            {
                Varyings o;
                o.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return o;
            }

            // ColorMask 0 时这个返回值不会写入任何通道,保持最简
            half4 frag(Varyings i) : SV_Target
            {
                return half4(0, 0, 0, 0);
            }
            ENDHLSL
        }

        // =============== DepthOnly ===============
        // 万一以后开了 Depth Priming,保证它依然进深度图
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back
            Offset [_OffsetFactor], [_OffsetUnits]

            HLSLPROGRAM
            #pragma vertex vertDepthOnly
            #pragma fragment fragDepthOnly

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings   { float4 positionHCS : SV_POSITION; };

            Varyings vertDepthOnly(Attributes input)
            {
                Varyings o;
                o.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return o;
            }
            half4 fragDepthOnly(Varyings i) : SV_Target { return 0; }
            ENDHLSL
        }
    }

    // 刻意不写 ShadowCaster pass:代理盒不应该投射阴影
    FallBack Off
}
