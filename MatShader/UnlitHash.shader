Shader "Custom/UnlitHash"
{
    Properties
    {
        [Header(Object Seed)]
        _SeedOffset("种子偏移(换一批随机结果)", Float) = 0

        [Header(Color Palette)]
        // 四色板随机抽取:营造"不同住户不同灯光"的真实感
        _ColorA("色板1", Color) = (1.00, 0.85, 0.60, 1)
        _ColorB("色板2", Color) = (0.70, 0.90, 1.00, 1)
        _ColorC("色板3", Color) = (0.45, 0.95, 1.00, 1)
        _ColorD("色板4", Color) = (1.00, 0.50, 0.85, 1)
        // 在选中色板基础上做小幅色相扰动,让颜色连续变化而非只有 4 档。
        // 设为 0 可完全关闭(省掉 cos/sin),此时只有 4 种颜色。
        _HueVariation("色相扰动幅度", Range(0, 1)) = 0.10

        [Header(Brightness)]
        _IntensityMin("最暗亮度", Range(0, 3)) = 0.40
        _IntensityMax("最亮亮度", Range(0, 3)) = 1.30
        _DarkRatio("熄灭比例", Range(0, 0.8)) = 0.15
        _DarkColor("熄灭颜色", Color) = (0.03, 0.035, 0.06, 1)

        [Header(Flicker)]
        _FlickerRatio("闪烁比例", Range(0, 1)) = 0.12
        _FlickerSpeed("闪烁速度", Range(0.5, 10)) = 3.0
        _FlickerAmount("闪烁幅度", Range(0, 1)) = 0.40

        [Header(Global)]
        // 全部物件统一乘的最终色调,用于整体调色(如偏冷/偏暖)
        _GlobalTint("整体色调", Color) = (1, 1, 1, 1)

        [Header(Fog)]
        // 本 shader 全自发光:0 = 完全穿透雾(远景霓虹依然亮),1 = 与表面一样被雾吃掉
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
            Name "UnlitHashForward"
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

            CBUFFER_START(UnityPerMaterial)
                float  _SeedOffset;
                half4  _ColorA;
                half4  _ColorB;
                half4  _ColorC;
                half4  _ColorD;
                float  _HueVariation;
                float  _IntensityMin;
                float  _IntensityMax;
                float  _DarkRatio;
                half4  _DarkColor;
                float  _FlickerRatio;
                float  _FlickerSpeed;
                float  _FlickerAmount;
                half4  _GlobalTint;
                float  _EmissionFogAmount;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                half3  color       : TEXCOORD0;
                float  fogFactor   : TEXCOORD1;
            };

            // 稳定哈希:同一输入恒定返回同一值(不随帧/顶点变化)
            float Hash13(float3 p)
            {
                p = frac(p * 0.3183099 + 0.1);
                p *= 17.0;
                return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
            }

            // 色相旋转(绕 RGB 空间对角线 (1,1,1) 旋转,比 HSV 转换便宜得多)
            half3 HueShift(half3 col, float angle)
            {
                const half3 axis = half3(0.57735, 0.57735, 0.57735);
                float c = cos(angle);
                return col * c + cross(axis, col) * sin(angle) + axis * dot(axis, col) * (1.0 - c);
            }

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);

                // ===== 逐物体随机种子 =====
                // UNITY_MATRIX_M 的平移列 = 物体原点的世界坐标。
                float3 origin = UNITY_MATRIX_M._m03_m13_m23 + _SeedOffset;
                float h1 = Hash13(origin);              // 色板抽取
                float h2 = Hash13(origin + 13.7);       // 色相扰动
                float h3 = Hash13(origin + 27.3);       // 亮度
                float h4 = Hash13(origin + 41.9);       // 是否熄灭
                float h5 = Hash13(origin + 57.1);       // 是否闪烁
                float h6 = Hash13(origin + 71.3);       // 闪烁相位

                // ===== 色板四选一(无分支:step 链式选择) =====
                float pick = h1 * 4.0;
                half3 col = _ColorA.rgb;
                col = lerp(col, _ColorB.rgb, step(1.0, pick));
                col = lerp(col, _ColorC.rgb, step(2.0, pick));
                col = lerp(col, _ColorD.rgb, step(3.0, pick));

                // 色相扰动(幅度为 0 时结果是恒等变换,可安全保留)
                col = HueShift(col, (h2 - 0.5) * _HueVariation * 6.2831);

                // ===== 亮度 + 闪烁(方波更像坏灯管,而非平滑呼吸) =====
                float bright = lerp(_IntensityMin, _IntensityMax, h3);
                float isFlicker = step(1.0 - _FlickerRatio, h5);
                float flick     = step(0.35, frac(_Time.y * _FlickerSpeed * 0.5 + h6 * 6.2831 * 0.159));
                bright *= lerp(1.0, lerp(1.0 - _FlickerAmount, 1.0, flick), isFlicker);

                // ===== 熄灭:直接换成暗色,亮度归一(暗色本身已足够暗) =====
                // 熄灭时不再乘亮度,避免暗上加暗变成纯黑
                float isDark = step(1.0 - _DarkRatio, h4);
                col    = lerp(col, _DarkColor.rgb, isDark);
                bright = lerp(bright, 1.0, isDark);

                // ===== 唯一一次色彩合成:颜色 × 亮度 × 全局色调 =====
                output.color = col * bright * _GlobalTint.rgb;

                // 雾因子:必须传【裁剪空间 z】,不能传 NDC z(z/w 已不是线性深度)
                output.fogFactor = ComputeFogFactor(output.positionHCS.z);

                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                // 雾:本 shader 全自发光,按 _EmissionFogAmount 决定吃多少雾。
                // 全量混雾会让远景霓虹全部死掉;0.3 左右能保留穿透力又不失层次。
                half3 c = lerp(input.color, MixFog(input.color, input.fogFactor), _EmissionFogAmount);
                return half4(c, 1);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
