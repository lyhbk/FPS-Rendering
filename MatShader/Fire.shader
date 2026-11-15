Shader "Custom/Fire"
{
    Properties
    {

        _BaseTex ("火焰噪声图(可选细节层,RGBA)", 2D) = "white" {}
        _BaseColor ("火焰底色", Color) = (1, 0.3, 0.05, 1)
        _EmissionColor ("自发光颜色(HDR)", Color) = (2.5, 0.6, 0.1, 1)

        _Life ("生命周期 1=刚命中 0=即将熄灭", Range(0,1)) = 1.0

        _EdgeNoise ("边缘噪声", 2D) = "white" {}
        _EdgePower ("边缘消融硬度", Range(1,8)) = 3.0

        _DistortStrength ("扰动强度", Range(0,0.15)) = 0.06
        _DistortSpeed ("扰动流动速度(Vector)", Vector) = (0.15, 0.25, 0, 0)

        _NoiseScale ("火焰噪声频率", Range(0.5, 8)) = 3.0
        _ScrollSpeed ("火焰上升速度", Range(0, 3)) = 0.9
        _WarpStrength ("域扭曲强度(火舌卷曲感)", Range(0, 4)) = 2.0
        _ShapeBottom ("底部渐入高度", Range(0, 0.5)) = 0.1
        _ShapeTop ("火苗最大高度(Life 会缩放)", Range(0.2, 1.2)) = 0.95

        _CoreColor ("核心白热色(HDR)", Color) = (6, 5, 4, 1)
        _MidColor ("中层亮黄色(HDR)", Color) = (4, 1.6, 0.3, 1)
        _RimColor ("边缘暗红色", Color) = (1.2, 0.2, 0.02, 1)
        _RampMidBias ("中层热度阈值", Range(0,1)) = 0.25
        _RampCoreBias ("核心热度阈值", Range(0,1)) = 0.55

        _SmokeColor ("烟色", Color) = (0.15, 0.13, 0.12, 1)
        _SmokeAmount ("烟雾量", Range(0,1)) = 0.55
        _SmokeStart ("烟雾起始高度(uv.y)", Range(0,1)) = 0.45

        _EmberColor ("火星颜色(HDR)", Color) = (8, 3, 0.5, 1)
        _EmberAmount ("火星密度", Range(0,1)) = 0.5
        _EmberScale ("火星频率", Range(1, 20)) = 9.0
        _EmberSpeed ("火星闪烁速度", Range(0, 8)) = 3.0

        _FlickerAmp ("整体亮度抖动幅度", Range(0, 1)) = 0.25
        _FlickerSpeed ("闪烁速度", Range(0, 10)) = 4.0

        [Toggle(_SOFT_PARTICLES_ON)] _SoftParticles ("开启深度软粒子(需URP开启Depth Texture)", Float) = 0
        _SoftDistance ("贴面软淡出距离(米)", Range(0.01, 2)) = 0.3
    }

    SubShader
    {
        Tags
        {
            "RenderType"="Transparent"
            "Queue"="Transparent"
            "IgnoreProjector"="True"
            "RenderPipeline"="UniversalPipeline"
        }
        Pass
        {
            ZWrite On
            Blend SrcAlpha OneMinusSrcAlpha
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma shader_feature_local _SOFT_PARTICLES_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
                float2 uv0          : TEXCOORD0;   // 原始 uv,程序化火焰用
                float2 uvBase       : TEXCOORD1;   // _BaseTex ST 变换后
                float2 uvNoise      : TEXCOORD2;   // 边缘噪声,随时间流动
                float4 screenPos    : TEXCOORD3;   // 软粒子用
            };

            TEXTURE2D(_BaseTex);   SAMPLER(sampler_BaseTex);
            TEXTURE2D(_EdgeNoise); SAMPLER(sampler_EdgeNoise);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseTex_ST;
                float4 _EdgeNoise_ST;
                float4 _BaseColor;
                float4 _EmissionColor;
                float4 _CoreColor;
                float4 _MidColor;
                float4 _RimColor;
                float4 _SmokeColor;
                float4 _EmberColor;
                float  _Life;
                float  _EdgePower;
                float  _DistortStrength;
                float2 _DistortSpeed;
                float  _NoiseScale;
                float  _ScrollSpeed;
                float  _WarpStrength;
                float  _ShapeBottom;
                float  _ShapeTop;
                float  _RampMidBias;
                float  _RampCoreBias;
                float  _SmokeAmount;
                float  _SmokeStart;
                float  _EmberAmount;
                float  _EmberScale;
                float  _EmberSpeed;
                float  _FlickerAmp;
                float  _FlickerSpeed;
                float  _SoftDistance;
            CBUFFER_END

            // ---------------- 程序化噪声:hash / value noise / fbm ----------------
            float hash12(float2 p)
            {
                return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
            }

            float vnoise(float2 p)
            {
                float2 i = floor(p);
                float2 f = frac(p);
                f = f * f * (3.0 - 2.0 * f);   // 平滑插值
                float a = hash12(i);
                float b = hash12(i + float2(1.0, 0.0));
                float c = hash12(i + float2(0.0, 1.0));
                float d = hash12(i + float2(1.0, 1.0));
                return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
            }

            float fbm(float2 p)
            {
                float v = 0.0;
                float a = 0.5;
                [unroll]
                for (int i = 0; i < 5; i++)
                {
                    v += a * vnoise(p);
                    p = p * 2.03 + 17.17;      // 每倍频错开,去相关
                    a *= 0.5;
                }
                return v;
            }

            Varyings vert (Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv0    = input.uv;
                output.uvBase = TRANSFORM_TEX(input.uv, _BaseTex);

                // 噪声UV随时间流动
                float time = _Time.y;
                output.uvNoise = TRANSFORM_TEX(input.uv, _EdgeNoise) + _DistortSpeed * time;

                // 软粒子所需的屏幕坐标(透视除法前的 NDC)
                float4 sp = output.positionHCS * 0.5;
                output.screenPos.xy = float2(sp.x, sp.y * _ProjectionParams.x) + sp.w;
                output.screenPos.zw = output.positionHCS.zw;
                return output;
            }

            half4 frag (Varyings input) : SV_Target
            {
                float time = _Time.y;
                float2 uv = input.uv0;

                // ============ 0) 亮度闪烁(双正弦叠加,不规则忽明忽暗) ============
                float fl = sin(time * _FlickerSpeed) * 0.5
                         + sin(time * _FlickerSpeed * 2.3 + 1.7) * 0.5;
                float flicker = 1.0 + fl * _FlickerAmp * 0.5;

                // ============ 1) 火焰外形遮罩 ============
                // 高度:随 Life 衰减,火苗从顶部向下熄灭
                float flameTop = _ShapeTop * (0.35 + 0.65 * _Life);
                float heightMask = smoothstep(0.0, _ShapeBottom, uv.y)
                                 * (1.0 - smoothstep(flameTop - 0.35, flameTop, uv.y));
                // 横向:越往上越窄,形成火苗的水滴轮廓
                float xN = abs(uv.x - 0.5) * 2.0;
                float widthMask = 1.0 - saturate(xN * (0.35 + uv.y * 1.4));
                float shape = heightMask * widthMask;

                // ============ 2) 域扭曲 FBM(火舌卷曲的核心) ============
                float2 p = uv * _NoiseScale;
                p.y -= time * _ScrollSpeed;    // 采样窗口向下移 => 火焰向上窜
                float2 q;
                q.x = fbm(p + time * _DistortSpeed.x * 0.3);
                q.y = fbm(p + float2(5.2, 1.3) - time * _DistortSpeed.y * 0.3);
                float f = fbm(p + _WarpStrength * q);

                // ============ 3) 旧版 UV 扰动 + 细节纹理层(保留原功能) ============
                float2 edgeRG = SAMPLE_TEXTURE2D(_EdgeNoise, sampler_EdgeNoise, input.uvNoise).rg;
                float2 fireUV = input.uvBase + edgeRG * _DistortStrength;
                half4 fireTex = SAMPLE_TEXTURE2D(_BaseTex, sampler_BaseTex, fireUV);

                // ============ 4) 热度场 ============
                float heat = f * shape;
                heat = saturate(heat * 2.2);              // 提对比,让火苗更"挺"
                heat *= lerp(1.0, fireTex.r, 0.5);        // 细节纹理参与一半,白图=1不影响

                // 边缘噪声消融(沿用原逻辑,加了 saturate 防 pow 负数)
                half edgeNoise = SAMPLE_TEXTURE2D(_EdgeNoise, sampler_EdgeNoise, input.uvNoise).r;
                half edgeMask = pow(saturate(edgeNoise * _Life), _EdgePower);

                // ============ 5) 四段热度渐变:暗红 -> 亮黄 -> 白热 ============
                half3 ramp = _RimColor.rgb;
                ramp = lerp(ramp, _MidColor.rgb,  smoothstep(_RampMidBias,  _RampMidBias  + 0.25, heat));
                ramp = lerp(ramp, _CoreColor.rgb, smoothstep(_RampCoreBias, _RampCoreBias + 0.25, heat));

                // ============ 6) 火星 / 余烬 ============
                float2 ep = uv * _EmberScale;
                ep.y -= time * _ScrollSpeed * 1.5;        // 火星升得比火焰快
                float en = vnoise(ep + q * 2.0);
                float ember = smoothstep(0.78, 0.95, en) * shape * _EmberAmount;
                float spark = 0.5 + 0.5 * sin(time * _EmberSpeed + en * 40.0); // 每颗星各自闪
                half3 emberCol = _EmberColor.rgb * ember * spark;

                // ============ 7) 顶部黑烟 ============
                float smokeZone = smoothstep(_SmokeStart, 1.0, uv.y);
                float smokeMask = smokeZone
                                * (1.0 - saturate(heat * 2.5))   // 火弱的地方烟才明显
                                * _SmokeAmount
                                * smoothstep(0.0, 0.15, _Life);

                // ============ 8) 合成 ============
                half3 fireCol = ramp * heat * flicker;
                half3 detail  = fireTex.rgb * _BaseColor.rgb * heat;   // 旧版细节层
                half3 col = fireCol + detail + fireCol * _EmissionColor.rgb;
                col += emberCol;
                col = lerp(col, _SmokeColor.rgb, smokeMask);           // 混入烟色

                float alpha = saturate(heat + ember * 0.8 + smokeMask * 0.5);
                alpha *= edgeMask;
                alpha *= smoothstep(0.0, 0.1, _Life);   // 生命末期彻底淡出

                // ============ 9) 软粒子:贴墙/贴地时边缘柔化 ============
                #if defined(_SOFT_PARTICLES_ON)
                    float2 screenUV = input.screenPos.xy / input.screenPos.w;
                    float rawDepth = SAMPLE_TEXTURE2D(_CameraDepthTexture, sampler_CameraDepthTexture, screenUV).r;
                    float sceneZ = LinearEyeDepth(rawDepth, _ZBufferParams);
                    float thisZ  = input.screenPos.w;   // 透视投影下 w 即视空间深度
                    float softFade = saturate((sceneZ - thisZ) / _SoftDistance);
                    alpha *= softFade;
                #endif

                half4 final;
                final.rgb = col;
                final.a = alpha;
                return final;
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
