Shader "Custom/LanternCutout"
{
    Properties
    {
        [MainTexture] _BaseMap ("基础贴图 RGB", 2D) = "white" {}
        [MainColor]   _BaseColor ("基础色调", Color) = (1, 1, 1, 1)

        [Header(Normal And Mask)]
        // RGB = 切线空间法线;A = 镂空遮罩(AlphaTest 用)
        _NormalMap ("法线贴图(RGB=法线, A=裁剪遮罩)", 2D) = "bump" {}
        _NormalScale ("法线强度", Range(0, 2)) = 1

        [Header(Roughness)]
        // 红色通道 = 粗糙度,0 = 光滑(漆面/纸蜡),1 = 完全哑光(粗布/麻纸)
        _RoughnessMap ("粗糙度贴图(R)", 2D) = "white" {}
        _Roughness ("粗糙度缩放", Range(0, 1)) = 1

        [Header(Cutout)]
        _Cutoff ("裁剪阈值(遮罩小于此值的像素被丢弃)", Range(0, 1)) = 0.5
        [Enum(UnityEngine.Rendering.CullMode)] _Cull ("背面剔除(0=双面 1=正面 2=背面)", Float) = 2
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "TransparentCutout"
            "Queue" = "AlphaTest"
            "RenderPipeline" = "UniversalPipeline"
        }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        // 团结引擎 14.2 fork: LerpWhiteTo 定义在 CommonMaterial.hlsl,
        // Shadows.hlsl 依赖它,必须先于 Shadows.hlsl 包含
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

        TEXTURE2D(_BaseMap);      SAMPLER(sampler_BaseMap);
        TEXTURE2D(_NormalMap);    SAMPLER(sampler_NormalMap);
        TEXTURE2D(_RoughnessMap); SAMPLER(sampler_RoughnessMap);

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            half4  _BaseColor;

            float4 _NormalMap_ST;
            half   _NormalScale;

            float4 _RoughnessMap_ST;
            half   _Roughness;

            half   _Cutoff;
            half   _Cull;
        CBUFFER_END

        // 镂空遮罩:统一走这一个函数,保证三个 Pass 用同一张图、同一个阈值
        half SampleAlphaMask (float2 uv)
        {
            return SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, TRANSFORM_TEX(uv, _NormalMap)).a;
        }
        ENDHLSL

        // ========================= 主 Pass =========================
        Pass
        {
            Name "LanternCutoutForward"

            Tags { "LightMode" = "UniversalForward" }

            ZWrite On
            ZTest LEqual
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // 主光阴影(两个关键字互斥,必须都声明)
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            // 附加光
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            // 光照贴图 + 雾
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile_fog

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float2 uvLM       : TEXCOORD1;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
                float3 positionWS  : TEXCOORD1;
                float3 normalWS    : TEXCOORD2;
                float3 tangentWS   : TEXCOORD3;
                float3 bitangentWS : TEXCOORD4;
                float2 uvLM        : TEXCOORD5;
                float  fogFactor   : TEXCOORD6;
                #if defined(_MAIN_LIGHT_SHADOWS)
                    float4 shadowCoord : TEXCOORD7;
                #endif
            };

            Varyings vert (Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.positionWS  = TransformObjectToWorld(input.positionOS.xyz);

                float3 nWS = TransformObjectToWorldNormal(input.normalOS);
                output.normalWS    = nWS;
                output.tangentWS   = TransformObjectToWorldDir(input.tangentOS.xyz);
                output.bitangentWS = cross(nWS, output.tangentWS) * input.tangentOS.w;

                output.uv = input.uv;   // 各贴图在采样时各自 TRANSFORM_TEX,支持独立平铺

                #ifdef LIGHTMAP_ON
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
                // ---------------- 1. 裁剪:遮罩来自法线贴图 Alpha ----------------
                // 放在最前面:被裁掉的像素直接跳过后面所有光照计算(省 ALU)
                half alphaMask = SampleAlphaMask(i.uv);
                clip(alphaMask - _Cutoff);

                // ---------------- 2. 三张贴图 ----------------
                half4 baseCol = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, TRANSFORM_TEX(i.uv, _BaseMap)) * _BaseColor;

                half4 normalSample = SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, TRANSFORM_TEX(i.uv, _NormalMap));
                half3 normalTS = UnpackNormalScale(normalSample, _NormalScale);
                float3x3 TBN = float3x3(normalize(i.tangentWS), normalize(i.bitangentWS), normalize(i.normalWS));
                half3 normalWS = normalize(mul(normalTS, TBN));

                // 粗糙度贴图红色通道 → 粗糙;PBR 需要的是光滑度,取反
                half roughness  = saturate(SAMPLE_TEXTURE2D(_RoughnessMap, sampler_RoughnessMap, TRANSFORM_TEX(i.uv, _RoughnessMap)).r * _Roughness);
                half smoothness = 1.0 - roughness;

                half3 viewDirWS = normalize(GetWorldSpaceViewDir(i.positionWS));

                // ---------------- 3. BRDF(金属度固定 0:纸/布不导电) ----------------
                BRDFData brdfData;
                half alphaInOut = 1.0;   // fork 的签名是 inout half alpha,必须传左值
                InitializeBRDFData(baseCol.rgb, 0.0, half3(0, 0, 0), smoothness, alphaInOut, brdfData);

                // ---------------- 4. 间接光(GI):SH 或烘焙光照贴图 ----------------
                #ifdef LIGHTMAP_ON
                    half3 bakedGI = SampleLightmap(i.uvLM, normalWS);
                #else
                    half3 bakedGI = SampleSH(normalWS);
                #endif
                half3 color = GlobalIllumination(brdfData, bakedGI, 1.0, normalWS, viewDirWS);

                // ---------------- 5. 主光(带实时阴影) ----------------
                #if defined(_MAIN_LIGHT_SHADOWS)
                    Light mainLight = GetMainLight(i.shadowCoord);
                #else
                    Light mainLight = GetMainLight();
                #endif
                color += LightingPhysicallyBased(brdfData, mainLight, normalWS, viewDirWS);

                // ---------------- 6. 附加光:逐像素 ----------------
                #ifdef _ADDITIONAL_LIGHTS
                    uint lightCount = GetAdditionalLightsCount();
                    [loop]
                    for (uint k = 0u; k < lightCount; k++)
                    {
                        Light L = GetAdditionalLight(k, i.positionWS);
                        color += LightingPhysicallyBased(brdfData, L, normalWS, viewDirWS);
                    }
                #endif

                color = MixFog(color, i.fogFactor);

                // 不透明输出:Alpha 只用于裁剪,不参与混合
                return half4(color, 1.0);
            }
            ENDHLSL
        }

        // ======================= 深度(贴花/深度系统) =======================
        Pass
        {
            Name "DepthOnly"

            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull [_Cull]

            HLSLPROGRAM
            #pragma vertex DepthVert
            #pragma fragment DepthFrag

            struct DepthAttributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct DepthVaryings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;
            };

            DepthVaryings DepthVert (DepthAttributes input)
            {
                DepthVaryings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv          = input.uv;
                return output;
            }

            half4 DepthFrag (DepthVaryings i) : SV_Target
            {
                // 镂空处不写深度,否则贴花/SSAO 会把透明区域当实体
                clip(SampleAlphaMask(i.uv) - _Cutoff);
                return 0;
            }
            ENDHLSL
        }

        // ========================= 阴影投射 =========================
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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

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

                #if UNITY_REVERSED_Z
                    positionCS.z = min(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    positionCS.z = max(positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif

                output.positionHCS = positionCS;
                output.uv          = input.uv;
                return output;
            }

            half4 ShadowFrag (ShadowVaryings i) : SV_Target
            {
                // 镂空处不投影:影子会跟着裁剪图案走(纸窗格的效果)
                clip(SampleAlphaMask(i.uv) - _Cutoff);
                return 0;
            }
            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
