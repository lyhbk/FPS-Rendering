Shader "Custom/Sharp"
{
    Properties
    {
        [MainTexture] _BaseMap("基础色 Albedo", 2D) = "white" {}
        [MainColor] _BaseColor("基础色调", Color) = (1,1,1,1)

        [Toggle(_NORMALMAP_ON)]      _NormalMapOn("启用法线贴图", Float) = 1
        [Toggle(_SEPARATE_MAPS_ON)]  _SeparateMapsOn("启用金属度/粗糙度贴图", Float) = 0
        [Toggle(_IBL_ON)]            _IBLOn("启用 IBL 环境光照", Float) = 0
        [Toggle(_EMISSION_ON)]       _EmissionOn("启用自发光", Float) = 0
        [Header(Emission)]
        // 自发光颜色 = 该像素自身的 albedo(基础贴图 × 基础色);
        // 强度在 [最小, 最大] 区间逐像素随机(世界坐标格子哈希,稳定不闪动)
        _EmissionIntensityMin("自发光强度下限", Range(0, 10)) = 0.5
        _EmissionIntensityMax("自发光强度上限", Range(0, 50)) = 2.5
        // 随机颗粒尺寸(米):值越小颗粒越细碎,越大越成块
        _EmissionNoiseScale("随机颗粒尺寸", Range(0.5, 50)) = 2.0
        // 闪烁:强度在 [下限, 上限] 区间随时间跳动,整件武器统一明暗
        _EmissionFlickerInterval("闪烁节奏(秒/格)", Range(0.02, 5)) = 0.15
        [Toggle(_EMISSION_FLICKER_SMOOTH)] _EmissionFlickerSmooth("平滑闪烁(关=硬跳)", Float) = 0
        [Header(Normal)]
        _NormalMap("法线贴图 Normal", 2D) = "bump" {}
        _NormalScale("法线强度", Range(0,2)) = 1.0

        [Header(Metallic Roughness)]
        _MetallicMap("金属度贴图 Metallic", 2D) = "white" {}
        _Metallic("金属度强度", Range(0,1)) = 0.5

        _RoughnessMap("粗糙度贴图 Roughness", 2D) = "white" {}
        _Roughness("粗糙度强度", Range(0,1)) = 0.5

        [Header(IBL)]
        _IBLIntensity("IBL整体强度", Range(0, 2)) = 1.0
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 200
        Cull Back
        ZWrite On
        ZTest LEqual

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // 主光阴影相关
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            // 软阴影只影响片元阶段,用 _fragment 版本避免顶点阶段也编译一份变体
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            // 附加光源
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS

            // 雾
            #pragma multi_compile_fog

            // 外部可控功能开关
            #pragma shader_feature_local _ _NORMALMAP_ON
            #pragma shader_feature_local _ _SEPARATE_MAPS_ON
            #pragma shader_feature_local _ _IBL_ON
            #pragma shader_feature_local _ _EMISSION_ON

            // 外部全局宏:脚本用 Shader.EnableKeyword("_GLOBAL_EMISSION_FLICKER") 统一开关闪烁
            // (用 multi_compile 保证变体始终存在,全局关键字才切得动)
            #pragma multi_compile_fragment _ _GLOBAL_EMISSION_FLICKER
            // 闪烁形态:材质内开关
            #pragma shader_feature_local _ _EMISSION_FLICKER_SMOOTH

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            TEXTURE2D(_NormalMap);
            SAMPLER(sampler_NormalMap);
            TEXTURE2D(_MetallicMap);
            SAMPLER(sampler_MetallicMap);
            TEXTURE2D(_RoughnessMap);
            SAMPLER(sampler_RoughnessMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseMap_ST;
                float4 _BaseColor;

                float4 _NormalMap_ST;
                float _NormalScale;

                float4 _MetallicMap_ST;
                float _Metallic;

                float4 _RoughnessMap_ST;
                float _Roughness;

                float _IBLIntensity;

                float _EmissionIntensityMin;
                float _EmissionIntensityMax;
                float _EmissionNoiseScale;
                float _EmissionFlickerInterval;
                float _EmissionFlickerSmooth;
            CBUFFER_END

            // 标量哈希:自发光强度随机用
            float Hash11(float p)
            {
                return frac(sin(p * 127.1) * 43758.5453123);
            }

            struct Attributes
            {
                float4 positionOS   : POSITION;
                float2 uv           : TEXCOORD0;
                float3 normalOS     : NORMAL;
                float4 tangentOS    : TANGENT;
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float3 positionWS   : TEXCOORD1;
                float3 normalWS     : TEXCOORD2;
                #ifdef _NORMALMAP_ON
                float3 tangentWS    : TEXCOORD3;
                float3 bitangentWS  : TEXCOORD4;
                #endif

                #if defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                float4 shadowCoord  : TEXCOORD6;
                #endif
                #ifdef _ADDITIONAL_LIGHTS
                half3 vertexLighting : TEXCOORD7;   
                #endif
                float fogFactor : TEXCOORD8;       
            };

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.positionWS = TransformObjectToWorld(input.positionOS.xyz);

                output.normalWS = TransformObjectToWorldNormal(input.normalOS);
                #ifdef _NORMALMAP_ON
                    output.tangentWS = TransformObjectToWorldDir(input.tangentOS.xyz);
                    output.bitangentWS = cross(output.normalWS, output.tangentWS) * input.tangentOS.w;
                #endif

                output.uv = TRANSFORM_TEX(input.uv, _BaseMap);

                // 阴影坐标:顶点阶段算好插值过去。
                // 原来在 frag 里每像素做一次世界→阴影空间的矩阵变换。
                #if defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                    output.shadowCoord = TransformWorldToShadowCoord(output.positionWS);
                #endif

                // ===== 附加光源:在顶点着色器累加,插值后给片元用 =====
                // 原来这段在 frag 里 → 每个屏幕像素都要跑 N 次完整 Cook-Torrance PBR。
                // 上移到 vert 后:顶点数(~5k) 远少于像素数(~2M),开销降约 2 个数量级。
                // 代价:光斑精度依赖网格密度,低模/大平面上会失真。
                #ifdef _ADDITIONAL_LIGHTS
                {
                    half3 vLight = 0;
                    uint c = (uint)GetAdditionalLightsCount();
                    for (uint k = 0u; k < c; k++)
                    {
                        Light L = GetAdditionalLight(k, output.positionWS);
                        // 顶点光照只用 Lambert 漫反射,不做 GGX 高光(省指令)
                        vLight += L.color * L.distanceAttenuation * saturate(dot(output.normalWS, L.direction));
                    }
                    output.vertexLighting = vLight;
                }
                #endif

                // 雾因子:必须传【裁剪空间 z】,不能传 NDC z(z/w 已不是线性深度)
                output.fogFactor = ComputeFogFactor(output.positionHCS.z);

                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;

                // 1. 基础色(唯一必采的贴图)
                half4 baseTex = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, uv) * _BaseColor;
                half3 albedo = baseTex.rgb;

                // 2. 金属度 / 粗糙度:由 _SEPARATE_MAPS_ON 统一控制
                //    开启 → 两张贴图各采 1 次(共 2 次);关闭 → 纯标量,0 次采样。
                //    (AO 与 MRA 打包图均已移除)
                //    若当前材质这两张贴图为空,关掉开关结果完全一致且省 2 次采样。
                half metallic, roughness;
                #ifdef _SEPARATE_MAPS_ON
                    metallic  = SAMPLE_TEXTURE2D(_MetallicMap,  sampler_MetallicMap,  TRANSFORM_TEX(uv, _MetallicMap)).r  * _Metallic;
                    roughness = SAMPLE_TEXTURE2D(_RoughnessMap, sampler_RoughnessMap, TRANSFORM_TEX(uv, _RoughnessMap)).r * _Roughness;
                #else
                    metallic  = _Metallic;
                    roughness = _Roughness;
                #endif

                // 3. 法线:_NORMALMAP_ON 关闭时直接用切线空间默认法线(省 1 次采样 + TBN 乘法)
                half3 normalWS;
                #ifdef _NORMALMAP_ON
                    half3 normalTS = UnpackNormalScale(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, TRANSFORM_TEX(uv, _NormalMap)), _NormalScale);
                    float3x3 TBN = float3x3(normalize(input.tangentWS), normalize(input.bitangentWS), normalize(input.normalWS));
                    normalWS = normalize(mul(normalTS, TBN));
                #else
                    normalWS = normalize(input.normalWS);
                #endif

                // 4. 视线 + 主光(带实时阴影)
                half3 viewDirWS = normalize(GetWorldSpaceViewDir(input.positionWS));
                // 阴影坐标已在顶点算好插值过来,这里零矩阵运算
                #if defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                    Light mainLight = GetMainLight(input.shadowCoord);
                #else
                    Light mainLight = GetMainLight();
                #endif

                // 5. PBR(URP 14 标准:BRDFData + InitializeBRDFData)
                BRDFData brdfData;
                half alpha = baseTex.a;
                InitializeBRDFData(albedo, metallic, half3(0, 0, 0), 1.0 - roughness, alpha, brdfData);

                half3 finalColor = LightingPhysicallyBased(brdfData, mainLight, normalWS, viewDirWS);

                // ===== 附加光源(逐顶点版本) =====
                // 光照已在 vert 阶段算好并插值过来,这里只做一次乘加。
                // 若要恢复逐像素精度:把这里改回 GetAdditionalLight 循环即可。
                #ifdef _ADDITIONAL_LIGHTS
                    finalColor += input.vertexLighting * brdfData.diffuse;
                #endif

                // ===== IBL 环境光照(可选,默认关闭) =====
                #ifdef _IBL_ON
                    half3 reflectVector  = reflect(-viewDirWS, normalWS);
                    half3 iblDiffuse     = SampleSH(normalWS) * brdfData.diffuse;
                    half3 iblSpecular    = GlossyEnvironmentReflection(reflectVector, brdfData.perceptualRoughness, 1.0);
                    iblSpecular         *= brdfData.specular;   // F0,金属表面反射带金属色
                    finalColor += (iblDiffuse + iblSpecular) * _IBLIntensity;
                #endif

                // ===== 自发光(可选) =====
                // 发光颜色 = 该像素自身的 albedo("发光的地方与这个像素的颜色相同")
                // 强度取值:
                //   默认          → 世界坐标格子哈希,稳定的逐格亮斑(不随时间变)
                //   外部宏开启    → 时间驱动的闪烁,整件武器统一明暗,节奏由脚本全局控制
                // 强度始终在 [_EmissionIntensityMin, _EmissionIntensityMax] 区间内
                #ifdef _EMISSION_ON
                    float emitHash;
                    #ifdef _GLOBAL_EMISSION_FLICKER
                        // 每物体独立相位:同一时刻场上多把武器闪烁不同步
                        float3 pivotWS = mul(unity_ObjectToWorld, float4(0, 0, 0, 1)).xyz;
                        float seed = frac(sin(dot(pivotWS.xz, float2(12.9898, 78.233))) * 43758.5453) * 100.0;

                        float interval = max(_EmissionFlickerInterval, 0.02);
                        float slotF    = _Time.y / interval;
                        float slot0    = floor(slotF);

                        float r0 = Hash11(slot0 * 1.618034 + seed * 7.717);
                        float r1 = Hash11((slot0 + 1.0) * 1.618034 + seed * 7.717);

                        float f = frac(slotF);
                        #ifdef _EMISSION_FLICKER_SMOOTH
                            float blend = smoothstep(0.6, 1.0, f);   // 末尾 40% 平滑过渡
                        #else
                            float blend = 0.0;                        // 硬跳:霓虹频闪感
                        #endif

                        emitHash = lerp(r0, r1, blend);
                    #else
                        float3 emitCell = floor(input.positionWS * _EmissionNoiseScale);
                        emitHash = Hash11(dot(emitCell, float3(127.1, 311.7, 74.7)));
                    #endif

                    half emitIntensity = lerp(_EmissionIntensityMin, _EmissionIntensityMax, emitHash);
                    finalColor += albedo * emitIntensity;
                #endif

                // 雾:武器在近距离,fogFactor ≈ 1,实际几乎无影响
                finalColor = MixFog(finalColor, input.fogFactor);

                return half4(finalColor, baseTex.a);
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

        // =============== 阴影投射 Pass ===============
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
            // include 顺序很重要:CommonMaterial.hlsl 用到 real 类型,
            // 而 real 是 Core.hlsl(级联 Common.hlsl)里定义的,必须在 Core 之后 include;
            // 同时 Shadows.hlsl 用到 LerpWhiteTo(定义在 CommonMaterial.hlsl),必须在它之后。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS  : NORMAL;
            };
            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            Varyings vert(Attributes input)
            {
                Varyings output;

                // ApplyShadowBias 签名:(positionWS, normalWS, lightDirectionWS)
                // 全部要求世界空间;旧版传 object space 是错的。
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS   = TransformObjectToWorldNormal(input.normalOS);

                // 平行光:_MainLightPosition.w == 0,xyz 即指向光源的方向
                float3 lightDirectionWS = _MainLightPosition.xyz;

                float3 biasedWS = ApplyShadowBias(positionWS, normalWS, lightDirectionWS);
                output.positionCS = TransformWorldToHClip(biasedWS);

                // 平台深度范围对齐,防止阴影被近平面裁掉(必须放在 bias 之后)
                #if UNITY_REVERSED_Z
                    output.positionCS.z = min(output.positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    output.positionCS.z = max(output.positionCS.z, UNITY_NEAR_CLIP_VALUE);
                #endif

                return output;
            }

            half4 frag(Varyings input) : SV_Target { return 0; }
            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
