Shader "Custom/Lantern"
{
    Properties
    {
        _BaseTex ("基础贴图(RGBA,A=透明度)", 2D) = "white" {}
        _BaseColor ("基础色(乘到贴图)", Color) = (1, 1, 1, 1)

        [Header(Normal)]
        _NormalMap ("法线贴图", 2D) = "bump" {}
        _NormalScale ("法线强度", Range(0, 2)) = 1

        [Header(Surface)]
        _Smoothness ("纸面高光(纸=低)", Range(0, 1)) = 0.25

        [Header(Ambient)]
        // 环境光(球谐/烘焙 GI)的强度倍增:灯笼纸很薄,环境光可适当调高
        _AmbientIntensity ("环境光强度", Range(0, 4)) = 1

        [Header(Translucency)]
        _TransColor ("透光颜色(HDR)", Color) = (1.0, 0.55, 0.2, 1)
        _TransStrength ("透光强度", Range(0, 4)) = 1
        _TransPower ("透光锐度(视角)", Range(0.5, 8)) = 2

        [Header(Emission)]
        [Toggle(_EMISSION_ON)] _EmissionOn ("自发光(灯笼本体发光)", Float) = 0
        _EmissionColor ("自发光颜色(HDR)", Color) = (2.5, 1.2, 0.4, 1)
        _EmissionStrength ("自发光强度", Range(0, 5)) = 1

        [Header(Edge Glow)]
        _RimPower ("边缘光锐度", Range(1, 8)) = 3
        _RimStrength ("边缘光强度", Range(0, 3)) = 0.5

        [Header(Options)]
        [Toggle(_ALPHACLIP_ON)] _AlphaClipOn ("启用 Alpha 裁剪(镂空图案)", Float) = 0
        _Cutoff ("Alpha 裁剪阈值", Range(0, 1)) = 0.5
        [Enum(UnityEngine.Rendering.CullMode)] _Cull ("背面剔除(0=双面 1=正面 2=背面)", Float) = 0
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Transparent"
            "Queue" = "Transparent"
            "RenderPipeline" = "UniversalPipeline"
        }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

        TEXTURE2D(_BaseTex);   SAMPLER(sampler_BaseTex);
        TEXTURE2D(_NormalMap); SAMPLER(sampler_NormalMap);

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseTex_ST;
            half4  _BaseColor;
            half   _NormalScale;
            half   _Smoothness;
            half   _AmbientIntensity;
            half4  _TransColor;
            half   _TransStrength;
            half   _TransPower;
            half4  _EmissionColor;
            half   _EmissionStrength;
            half   _RimPower;
            half   _RimStrength;
            half   _Cutoff;
            float  _EmissionOn;
            float  _AlphaClipOn;
        CBUFFER_END
        ENDHLSL

        Pass
        {
            Name "LanternForward"

            Tags { "LightMode" = "UniversalForward" }

            Blend SrcAlpha OneMinusSrcAlpha     
            ZWrite Off                         
            ZTest LEqual
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // 主光阴影:两个关键字互斥,都声明才不会在改级联数后静默失效
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile_fog

            // 本体开关
            #pragma shader_feature_local _ _EMISSION_ON
            #pragma shader_feature_local _ _ALPHACLIP_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uv         : TEXCOORD0;
                float2 uvLM       : TEXCOORD1;     // 烘焙光照贴图 UV
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
                float3 normalWS    : TEXCOORD1;
                float3 tangentWS   : TEXCOORD2;
                float3 bitangentWS : TEXCOORD3;
                float3 positionWS  : TEXCOORD4;
                float  fogFactor   : TEXCOORD5;
                float2 uvLM        : TEXCOORD6;
                #if defined(_MAIN_LIGHT_SHADOWS)
                    float4 shadowCoord : TEXCOORD7;   // 顶点阶段算好,片元省矩阵乘
                #endif
            };

            Varyings vert (Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.positionWS  = TransformObjectToWorld(input.positionOS.xyz);

                // 完整 TBN:法线贴图采样用
                float3 nWS = TransformObjectToWorldNormal(input.normalOS);
                output.normalWS    = nWS;
                output.tangentWS   = TransformObjectToWorldDir(input.tangentOS.xyz);
                output.bitangentWS = cross(nWS, output.tangentWS) * input.tangentOS.w;

                output.uv = TRANSFORM_TEX(input.uv, _BaseTex);

                #if defined(LIGHTMAP_ON)
                    output.uvLM = input.uvLM;
                #endif

                #if defined(_MAIN_LIGHT_SHADOWS)
                    output.shadowCoord = TransformWorldToShadowCoord(output.positionWS);
                #endif

                output.fogFactor = ComputeFogFactor(output.positionHCS.z);
                return output;
            }

            half4 frag (Varyings i) : SV_Target
            {
                // ---------------- 贴图与 Alpha ----------------
                half4 baseCol = SAMPLE_TEXTURE2D(_BaseTex, sampler_BaseTex, i.uv) * _BaseColor;
                half  alpha   = baseCol.a;

                #ifdef _ALPHACLIP_ON
                    clip(alpha - _Cutoff);          // 镂空图案(纸窗/破洞)
                #endif

                // ---------------- 法线 ----------------
                half3 normalWS = UnpackNormalScale(
                    SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, i.uv), _NormalScale);

                half3 viewDirWS = normalize(GetWorldSpaceViewDir(i.positionWS));

                // ---------------- 主光 + 透光 ----------------
                #if defined(_MAIN_LIGHT_SHADOWS)
                    Light mainLight = GetMainLight(i.shadowCoord);
                #else
                    Light mainLight = GetMainLight();
                #endif

                half  ndl      = saturate(dot(normalWS, mainLight.direction));
                half3 diffuse  = mainLight.color
                               * mainLight.distanceAttenuation
                               * mainLight.shadowAttenuation
                               * ndl;

                // 假次表面:光从背面来时把纸面"点透"
                // back       > 0  → 光在背面
                // viewAlign  → 1  → 视线与光线几乎正对(薄壳透射最强的角度)
                half  back      = saturate(-dot(normalWS, mainLight.direction));
                half  viewAlign = pow(saturate(dot(viewDirWS, mainLight.direction)), _TransPower);
                half3 transmit  = _TransColor.rgb
                                * Luminance(mainLight.color)
                                * back * viewAlign * _TransStrength;

                // 高光:纸面很弱,指数由 Smoothness 驱动,不引入 BRDF 结构省 ALU
                half3 halfDir   = normalize(mainLight.direction + viewDirWS);
                half  spec      = pow(saturate(dot(normalWS, halfDir)),
                                      exp2(_Smoothness * 10 + 1)) * _Smoothness;
                half3 specular  = mainLight.color
                                * mainLight.shadowAttenuation
                                * mainLight.distanceAttenuation
                                * spec;

                // ---------------- 附加光(点光/聚光) ----------------
                // 灯笼周围通常有点光,这里逐像素 Lambert + 一半透光,保证被点光"点亮"
                half3 additional = 0;
                #ifdef _ADDITIONAL_LIGHTS
                    uint lightCount = GetAdditionalLightsCount();
                    [loop]
                    for (uint k = 0u; k < lightCount; k++)
                    {
                        Light L = GetAdditionalLight(k, i.positionWS);
                        half  ndlL = saturate(dot(normalWS, L.direction));
                        half  bL   = saturate(-dot(normalWS, L.direction));

                        additional += L.color * L.distanceAttenuation * L.shadowAttenuation * ndlL;
                        additional += L.color * L.distanceAttenuation
                                    * Luminance(_TransColor.rgb) * bL * _TransStrength * 0.5;
                    }
                #endif

                // ---------------- 环境光(间接 GI) ----------------
                // SH = 场景环境光;LIGHTMAP_ON = 静态物体吃烘焙光照贴图
                #ifdef LIGHTMAP_ON
                    half3 bakedGI = SampleLightmap(i.uvLM, normalWS);
                #else
                    half3 bakedGI = SampleSH(normalWS);
                #endif
                half3 ambient = bakedGI * _AmbientIntensity;

                // ---------------- 自发光 + 边缘光 ----------------
                half3 emission = 0;
                #ifdef _EMISSION_ON
                    // 贴图当发光源:图案(龙纹/窗格)会跟着亮起来
                    emission += baseCol.rgb * _EmissionColor.rgb * _EmissionStrength;
                #endif

                // 边缘光复用自发光色,保证跟灯的色温一致;复用 _TransColor 也行
                half  rim   = pow(1.0 - saturate(dot(normalWS, viewDirWS)), _RimPower);
                emission   += rim * _EmissionColor.rgb * _RimStrength;

                // ---------------- 合成 ----------------
                // 直接光与附加光乘 albedo(纸的颜色),透光/自发光/边缘光保持原色
                half3 color = (diffuse + additional + specular) * baseCol.rgb
                            + transmit
                            + ambient * baseCol.rgb
                            + emission;

                color = MixFog(color, i.fogFactor);

                return half4(color, alpha);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"

            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex ShadowVert
            #pragma fragment ShadowFrag

            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            #pragma shader_feature_local _ _ALPHACLIP_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            // 引擎在阴影 Pass 前注入的全局量
            float3 _LightDirection;
            float3 _LightPosition;

            struct ShadowAttributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv         : TEXCOORD0;
            };

            struct ShadowVaryings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
            };

            ShadowVaryings ShadowVert (ShadowAttributes input)
            {
                ShadowVaryings output;
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS   = TransformObjectToWorldNormal(input.normalOS);

                #ifdef _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDirectionWS = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDirectionWS = _LightDirection;
                #endif

                float4 positionCS = TransformWorldToHClip(
                    ApplyShadowBias(positionWS, normalWS, lightDirectionWS));

                // 近平面压扁,防止投影到近平面后面的几何造成翻转
                #if UNITY_REVERSED_Z
                    positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif

                output.positionHCS = positionCS;
                output.uv = TRANSFORM_TEX(input.uv, _BaseTex);
                return output;
            }

            half4 ShadowFrag (ShadowVaryings i) : SV_Target
            {
                #ifdef _ALPHACLIP_ON
                    half alpha = SAMPLE_TEXTURE2D(_BaseTex, sampler_BaseTex, i.uv).a * _BaseColor.a;
                    clip(alpha - _Cutoff);
                #endif
                return 0;
            }
            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
