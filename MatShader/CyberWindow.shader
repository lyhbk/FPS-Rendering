Shader "Custom/CyberWindow"
{
    Properties
    {
        [Header(Window Pattern)]
        // 可选:一张窗格图案图集(4x4 之类的格子,每格一种窗型/窗帘/剪影)。
        // 留空(white)也能正常工作 —— 只是没有图案差异,仅靠颜色与亮度区分。
        _WindowTex("窗格图案图集(可空)", 2D) = "white" {}
        _AtlasGrid("图集行列数 XY", Vector) = (4, 4, 0, 0)
        _PatternInfluence("图案影响强度", Range(0, 1)) = 0.85

        [Header(Emisson Palette)]
        // 四色板随机抽取:营造"不同住户不同灯光"的真实感
        _ColorA("色板1 暖白", Color) = (1.00, 0.82, 0.55, 1)
        _ColorB("色板2 冷白", Color) = (0.72, 0.88, 1.00, 1)
        _ColorC("色板3 青",   Color) = (0.45, 0.95, 1.00, 1)
        _ColorD("色板4 粉",   Color) = (1.00, 0.55, 0.80, 1)

        [Header(Brightness)]
        _IntensityMin("最暗亮度", Range(0, 3)) = 0.35
        _IntensityMax("最亮亮度", Range(0, 3)) = 1.25
        _DarkRatio("关灯窗户比例", Range(0, 0.8)) = 0.18
        _DarkColor("关灯窗户颜色", Color) = (0.03, 0.035, 0.06, 1)

        [Header(Flicker)]
        _FlickerRatio("闪烁窗户比例(坏灯管)", Range(0, 1)) = 0.12
        _FlickerSpeed("闪烁速度", Range(0.5, 10)) = 3.0
        _FlickerAmount("闪烁幅度", Range(0, 1)) = 0.4

        [Header(Global)]
        _GlobalTint("整体色调", Color) = (1, 1, 1, 1)
        _SeedOffset("随机种子偏移", Float) = 0

        [Header(Fog)]
        // 窗户是自发光:0 = 完全穿透雾(远景窗户依然亮),1 = 与表面一样被雾吃掉
        _EmissionFogAmount("自发光受雾影响", Range(0, 1)) = 0.3
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
        }

        Pass
        {
            Name "WindowUnlit"
            Tags { "LightMode" = "UniversalForward" }

            Cull Back
            ZWrite On
            ZTest LEqual

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // 雾:URP 的雾是【逐 shader 声明】的,缺了这行本 shader 的物体完全不吃雾
            #pragma multi_compile_fog

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_WindowTex);
            SAMPLER(sampler_WindowTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _WindowTex_ST;
                float4 _AtlasGrid;
                float  _PatternInfluence;
                half4  _ColorA;
                half4  _ColorB;
                half4  _ColorC;
                half4  _ColorD;
                float  _IntensityMin;
                float  _IntensityMax;
                float  _DarkRatio;
                half4  _DarkColor;
                float  _FlickerRatio;
                float  _FlickerSpeed;
                float  _FlickerAmount;
                half4  _GlobalTint;
                float  _SeedOffset;
                float  _EmissionFogAmount;
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
                float  fogFactor   : TEXCOORD1;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _WindowTex);
                output.fogFactor = ComputeFogFactor(output.positionHCS.z);
                return output;
            }

            // 稳定哈希:给定同一个输入恒定返回同一个值(逐帧/逐像素不变)
            float Hash13(float3 p)
            {
                p = frac(p * 0.3183099 + 0.1);
                p *= 17.0;
                return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
            }

            half4 frag(Varyings input) : SV_Target
            {
                // ===== 随机种子:取物体原点的世界坐标 =====
                // 关键点:用 UNITY_MATRIX_M 的平移分量(物体原点),而不是逐像素的世界坐标,
                // 这样同一扇窗户的所有像素得到完全相同的种子 → 整扇窗户表现一致,
                // 而不同窗户因为原点不同 → 自动各不相同。
                float3 origin = UNITY_MATRIX_M._m03_m13_m23 + _SeedOffset;
                float h1 = Hash13(origin);
                float h2 = Hash13(origin + 13.7);
                float h3 = Hash13(origin + 27.3);
                float h4 = Hash13(origin + 41.9);
                float h5 = Hash13(origin + 57.1);
                float h6 = Hash13(origin + 71.3);

                // ===== 1. 图集:按哈希抽一格窗格图案 =====
                float2 grid = max(_AtlasGrid.xy, float2(1, 1));
                float2 cell = floor(float2(h1, h2) * grid);
                cell = min(cell, grid - 1.0);
                float2 atlasUV = (frac(input.uv) + cell) / grid;
                half pattern = SAMPLE_TEXTURE2D(_WindowTex, sampler_WindowTex, atlasUV).r;
                pattern = lerp(1.0, pattern, _PatternInfluence);

                // ===== 2. 色板四选一(无分支,靠 step 链式选择) =====
                float pick = h3 * 4.0;
                half3 col = _ColorA.rgb;
                col = lerp(col, _ColorB.rgb, step(1.0, pick));
                col = lerp(col, _ColorC.rgb, step(2.0, pick));
                col = lerp(col, _ColorD.rgb, step(3.0, pick));

                // ===== 3. 亮度 + 部分窗户关灯 =====
                float bright = lerp(_IntensityMin, _IntensityMax, h4);
                float isDark = step(1.0 - _DarkRatio, h5);
                col    = lerp(col, _DarkColor.rgb, isDark);
                bright = lerp(bright, 0.0, isDark);

                // ===== 4. 少量窗户闪烁(老化灯管) =====
                // 方波式明暗比正弦更像坏灯管;只对 _FlickerRatio 比例的窗户生效
                float isFlicker = step(1.0 - _FlickerRatio, h6);
                float phase     = h1 * 6.2831;
                float flick     = step(0.35, frac(_Time.y * _FlickerSpeed * 0.5 + phase * 0.159));
                bright *= lerp(1.0, lerp(1.0 - _FlickerAmount, 1.0, flick), isFlicker);

                // 输出 HDR:亮度 >1 时会被 Bloom 拾取,形成窗户溢光
                half3 final = col * bright * _GlobalTint.rgb * pattern;

                // 雾:窗户是自发光,按 _EmissionFogAmount 决定吃多少雾。
                // 若直接全量 MixFog,远景窗户会全部死掉,失去"远处城市灯火"的层次。
                final = lerp(final, MixFog(final, input.fogFactor), _EmissionFogAmount);

                return half4(final, 1);
            }
            ENDHLSL
        }

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

            struct DepthOnlyAttributes { float4 positionOS : POSITION; };
            struct DepthOnlyVaryings   { float4 positionHCS : SV_POSITION; };

            DepthOnlyVaryings vertDepthOnly(DepthOnlyAttributes input)
            {
                DepthOnlyVaryings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 fragDepthOnly(DepthOnlyVaryings input) : SV_Target { return 0; }
            ENDHLSL
        }
    }
    Fallback Off
}
