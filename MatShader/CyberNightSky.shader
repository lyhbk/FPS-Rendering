Shader "Custom/CyberNightSky"
{
    Properties
    {
        [Header(Gradient)]
        _TopColor("天顶色", Color) = (0.01, 0.015, 0.05, 1)
        _HorizonColor("地平线色", Color) = (0.04, 0.025, 0.09, 1)
        _GradientPower("渐变过渡硬度", Range(0.5, 8)) = 2.5

        [Header(Neon Horizon Glow)]
        // 地平线一圈霓虹辉光(HDR 颜色,配合 Bloom 会微微晕开)
        _GlowColorA("辉光主色 HDR(粉紫)", Color) = (0.9, 0.15, 1.3, 1)
        _GlowColorB("辉光副色 HDR(青)", Color) = (0.1, 0.9, 1.2, 1)
        _GlowIntensity("辉光强度", Range(0, 3)) = 0.9
        _GlowHeight("辉光高度", Range(0.01, 0.5)) = 0.12

        [Header(Stars)]
        _StarDensity("星点密度", Range(10, 300)) = 90
        _StarBrightness("星点亮度", Range(0, 2)) = 0.8
        _StarThreshold("星点稀疏度", Range(0.9, 1.0)) = 0.996
        _TwinkleSpeed("闪烁速度", Range(0, 3)) = 1.0

        [Header(Tonemap)]
        _Exposure("曝光(压低保持夜感)", Range(0.01, 1)) = 0.18
    }

    SubShader
    {
        Tags
        {
            "Queue" = "Background"
            "RenderType" = "Background"
            "PreviewType" = "Skybox"
            "RenderPipeline" = "UniversalPipeline"
        }

        Pass
        {
            Name "SkyboxProg"
            Cull Off
            ZWrite Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half4 _TopColor;
                half4 _HorizonColor;
                float _GradientPower;
                half4 _GlowColorA;
                half4 _GlowColorB;
                float _GlowIntensity;
                float _GlowHeight;
                float _StarDensity;
                float _StarBrightness;
                float _StarThreshold;
                float _TwinkleSpeed;
                float _Exposure;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 dir        : TEXCOORD0;   // 天空盒方向(以相机为原点的本地坐标即方向)
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.dir = input.positionOS.xyz;
                return output;
            }

            // 3D 网格哈希:同格子内返回恒定伪随机数
            float Hash13(float3 p)
            {
                p = frac(p * 0.3183099 + 0.1);
                p *= 17.0;
                return frac(p.x * p.y * p.z * (p.x + p.y + p.z));
            }

            // 程序化星场:把方向空间切成 3D 网格,
            // 少数格子里放一个高斯小亮点,并按各自相位闪烁。零贴图采样。
            half StarLayer(float3 dir)
            {
                float3 p  = dir * _StarDensity;
                float3 id = floor(p);
                float3 f  = frac(p) - 0.5;

                float rnd     = Hash13(id);
                float present = step(_StarThreshold, rnd);       // 只有少数格子有星

                float d    = length(f);
                float star = present * smoothstep(0.35, 0.0, d); // 格子内高斯亮点

                // 各星独立频率/相位闪烁
                float twinkle = 0.55 + 0.45 * sin(_Time.y * _TwinkleSpeed * (1.0 + rnd * 4.0) + rnd * 6.2831);
                return star * twinkle * _StarBrightness;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float3 dir = normalize(input.dir);
                float  h   = dir.y;                              // 高度因子:1 天顶 0 地平线

                // ===== 天顶 → 地平线渐变 =====
                float t = pow(saturate(h), 1.0 / _GradientPower);
                half3 col = lerp(_HorizonColor.rgb, _TopColor.rgb, t);

                // 地平线以下快速压黑(通常被地面挡住,保险处理)
                col *= saturate(1.0 + h * 2.0);

                // ===== 地平线霓虹辉光 =====
                // 低空指数衰减的一圈光,颜色沿方位角在粉紫↔青之间过渡,
                // 呼应场景霓虹灯主色,避免"一圈死板同色"。
                float  glow    = exp(-max(h, 0.0) / _GlowHeight);
                float  az      = dir.x * 0.5 + 0.5;
                half3  glowCol = lerp(_GlowColorA.rgb, _GlowColorB.rgb, az);
                col += glow * glowCol * _GlowIntensity;

                // ===== 星点(仅天空区域) =====
                col += StarLayer(dir) * step(0.02, h);

                // ===== 低曝光:整幅压暗,保持深夜感 =====
                col *= _Exposure;

                return half4(col, 1);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
