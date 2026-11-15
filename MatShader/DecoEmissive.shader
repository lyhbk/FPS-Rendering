Shader "Custom/DecoEmissive"
{
    // ============================================================
    // 装饰灯/窗户面片专用:只发光,不参与光照计算
    //
    // 用途:霓虹招牌、窗户面片、灯带、屏幕、UI 发光元素等
    //      "次要灯光"(视觉上发光,但不需要照亮别人)
    //
    // 对比 Cyber/Sharp(Lit PBR):
    //   每像素贴图采样: 1 次  vs  3~30 次(含 POM)
    //   光照计算:       0      vs  主光 PBR + N×附加光 PBR
    //   GI/IBL:         无     vs  SampleSH + 反射探针
    //
    // 亮度靠 HDR 颜色(_EmissionColor 的 Intensity > 1)→ Bloom 采样产生光晕
    // ============================================================
    Properties
    {
        [MainTexture] _BaseMap("基础贴图(RGB) 可留空", 2D) = "white" {}
        [MainColor][HDR] _EmissionColor("自发光颜色 HDR", Color) = (1, 1, 1, 1)
        _EmissionIntensity("自发光强度", Range(0, 20)) = 1.0

        [Header(Alpha)]
        [Toggle(_ALPHATEST_ON)] _AlphaTestOn("启用 Alpha 裁剪", Float) = 0
        _Cutoff("裁剪阈值", Range(0,1)) = 0.5

        [Header(Flicker)]
        [Toggle(_FLICKER_ON)] _FlickerOn("启用闪烁", Float) = 0
        _FlickerSpeed("闪烁速度", Range(0.1, 10)) = 3.0
        _FlickerAmount("闪烁幅度", Range(0, 1)) = 0.15
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 100
        Cull Back
        ZWrite On
        ZTest LEqual

        // =============== ForwardUnlit ===============
        Pass
        {
            Name "ForwardUnlit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // ===== 外部可控开关 =====
            #pragma shader_feature_local _ _ALPHATEST_ON
            #pragma shader_feature_local _ _FLICKER_ON

            // 注意:这里刻意【不】声明 _ADDITIONAL_LIGHTS / _NORMALMAP 系列。
            // 装饰灯不需要被照亮,多一个光照循环就多一份逐像素开销。

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                half4  _EmissionColor;
                half   _EmissionIntensity;
                half   _Cutoff;
                half   _FlickerSpeed;
                half   _FlickerAmount;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                // 唯一的贴图采样
                half3 base = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, input.uv).rgb;

                half intensity = _EmissionIntensity;

                #ifdef _FLICKER_ON
                    // 用 uv 做便宜的伪随机相位,让每块窗户错开闪烁,无需额外贴图
                    half phase = input.uv.x * 12.9898 + input.uv.y * 78.233;
                    half f = sin(_Time.y * _FlickerSpeed + phase);
                    intensity *= 1.0 - _FlickerAmount * (0.5 + 0.5 * f);
                #endif

                half3 color = base * _EmissionColor.rgb * intensity;
                return half4(color, 1);
            }
            ENDHLSL
        }

        // =============== DepthOnly Pass ===============
        // 保证装饰灯写进深度图 → 后续贴花 / 遮挡关系正确(且开 Depth Priming 时不失效)
        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

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

        // =============== ShadowCaster Pass ===============
        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            float3 _LightDirection;

            struct Attributes { float4 positionOS : POSITION; float3 normalOS : NORMAL; };
            struct Varyings   { float4 positionCS : SV_POSITION; };

            Varyings vert(Attributes input)
            {
                Varyings o;
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS   = TransformObjectToWorldNormal(input.normalOS);
                float3 biasedWS   = ApplyShadowBias(positionWS, normalWS, _LightDirection);
                o.positionCS = TransformWorldToHClip(biasedWS);

                #if UNITY_REVERSED_Z
                    o.positionCS.z = min(o.positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    o.positionCS.z = max(o.positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif
                return o;
            }

            half4 frag(Varyings i) : SV_Target { return 0; }
            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
