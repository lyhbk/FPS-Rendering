Shader "Custom/URP/Rendering"
{
    Properties
    {
    }
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry+1"
            "RenderPipeline" = "UniversalPipeline"
        }
        Pass
        {
            Name "InvisibleDepthWrite"
            Tags { "LightMode" = "UniversalForward" }

            ColorMask 0     // 不写颜色 → 完全隐形
            ZWrite On       // 写深度 ← 关键
            ZTest LEqual
            Cull Back

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 frag() : SV_Target
            {
                // ColorMask 0 已屏蔽所有颜色写入,这里的返回值不会被写入帧缓冲
                return half4(0, 0, 0, 0);
            }
            ENDHLSL
        }

        // ================= Pass 2: DepthOnly =================
        // URP Asset → Rendering → Depth Priming 开启时,深度图由这个预通道生成。
        // 缺了它,即使主通道 ZWrite On,URP 也会整片跳过该物体 → 贴花依然不可见。
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ColorMask 0
            ZWrite On
            ZTest LEqual
            Cull Back

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 frag() : SV_Target
            {
                return half4(0, 0, 0, 0);
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}


