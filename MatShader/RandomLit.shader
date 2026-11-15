Shader "Custom/FlickerSimpleLit"
{
    // =====================================================================
    //  SimpleLit 变体:无贴图 + 灯光颜色/强度/曝光可调 + 灯光亮度随时间随机闪烁
    //
    //  光照路径完全仿照 URP SimpleLit:
    //      BRDFData 初始化(默认高光工作流 _SPECULAR_SETUP)
    //      → GlobalIllumination 间接光
    //      → 每盏灯经 LightingPhysicallyBased 求值(Lambert 漫反射 + Blinn-Phong 高光)
    //      唯一区别:每盏灯的亮度先经过
    //          灯色 × _LightColor(基调) × _LightIntensity(强度) → FlickerFactor(随机闪烁)
    //
    //  曝光:最终颜色 × exp2(_Exposure),与 Post Exposure 同一公式,便于和后处理对表
    //
    //  闪烁模型:时间轴切成 _FlickerInterval 秒一格,每格哈希出随机亮度,
    //  在 [1-_FlickerStrength, 1] 区间抖动(深度=1 时最暗到完全熄灭);
    //  _SMOOTH_CYCLE 开 = 平滑过渡,关 = 到点硬跳(霓虹频闪感)
    // =====================================================================

    Properties
    {
        _BaseColor ("基础色(无贴图)", Color) = (1, 1, 1, 1)

        // Header 内容只能是标识符,不能有 --- 等符号(会报 unexpected $undefined)
        [Header(Surface SimpleLit)]
        // SimpleLit 默认高光工作流;关掉则走金属度
        [Toggle(_SPECULAR_SETUP)] _SpecSetup ("高光工作流(关=金属度)", Float) = 1
        _SpecColor ("高光颜色", Color) = (0.5, 0.5, 0.5, 1)
        _Metallic ("Metallic(金属度工作流用)", Range(0, 1)) = 0
        _Smoothness ("Smoothness", Range(0, 1)) = 0.5

        [Header(Light Control)]
        // 基调色乘到【每一盏灯】上,再进随机变换
        _LightColor ("灯光颜色基调", Color) = (1, 1, 1, 1)
        _LightIntensity ("灯光强度倍增", Range(0, 8)) = 1
        // 每档 = 翻倍/减半,与后处理 Post Exposure 一致
        _Exposure ("曝光(档)", Float) = 0

        [Header(Flicker)]
        // 不同材质给不同种子,否则全场景同步闪烁
        _Seed ("随机种子", Float) = 0
        // 闪烁节奏:每个时间格哈希一次亮度;0.1~0.2 ≈ 霓虹频闪
        _FlickerInterval ("闪烁节奏(秒/格)", Range(0.02, 5)) = 0.15
        // 0 = 不闪;1 = 最暗到完全熄灭
        _FlickerStrength ("闪烁深度", Range(0, 1)) = 0.8
        // 1 = 亮度均匀随机;>1 更常灭;<1 更常亮
        _FlickerPower ("熄灭偏向", Range(0.2, 8)) = 1.5

        [Header(Switches)]
        [Toggle(_SMOOTH_CYCLE)] _SmoothCycle ("平滑闪烁(关=硬跳)", Float) = 0
        [Toggle(_PER_OBJECT_VARIATION)] _PerObjectVariation ("按物体随机(多实例)", Float) = 1
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
            "RenderPipeline" = "UniversalPipeline"
        }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        // 团结引擎 14.2 fork: LerpWhiteTo 在 CommonMaterial.hlsl,
        // Shadows.hlsl 要用,必须先于 Shadows.hlsl 包含
        #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"

        CBUFFER_START(UnityPerMaterial)
            half4  _BaseColor;
            half4  _SpecColor;
            half   _Metallic;
            half   _Smoothness;
            half4  _LightColor;
            half   _LightIntensity;
            float  _Exposure;
            float  _Seed;
            float  _FlickerInterval;
            float  _FlickerStrength;
            float  _FlickerPower;
            float  _SmoothCycle;
            float  _PerObjectVariation;
        CBUFFER_END

        // ---------------- 随机工具 ----------------
        float Hash11 (float p)
        {
            return frac(sin(p * 127.1) * 43758.5453123);
        }

        // 核心:按(时间格 + 种子)随机闪烁强度,颜色本身不变
        float FlickerFactor (float seed)
        {
            float interval = max(_FlickerInterval, 0.02);
            float slotF    = _Time.y / interval;
            float slot0    = floor(slotF);

            float r0 = Hash11(slot0 * 1.618034 + seed * 7.717);
            float r1 = Hash11((slot0 + 1.0) * 1.618034 + seed * 7.717);

            float f = frac(slotF);
            #ifdef _SMOOTH_CYCLE
                float blend = smoothstep(0.6, 1.0, f);   // 末尾 40% 平滑过渡
            #else
                float blend = 0.0;                        // 硬跳:霓虹频闪感
            #endif

            // 熄灭偏向:指数 <1 偏亮(偶尔暗),>1 偏暗(偶尔亮)
            float target = pow(lerp(r0, r1, blend), _FlickerPower);

            // 亮度在 [1-深度, 1] 区间抖动
            return lerp(1.0 - _FlickerStrength, 1.0, target);
        }

        // 核心:按(时间格 + 种子)随机变换灯色
        // 灯色管线:场景灯色 × 基调 × 强度 × 闪烁
        half3 ProcessLightColor (half3 sceneLightColor, float seed)
        {
            return sceneLightColor * _LightColor.rgb * _LightIntensity * FlickerFactor(seed);
        }
        ENDHLSL

        // ============================ 主 Pass ============================
        Pass
        {
            Name "RandomSimpleLitForward"

            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // 与 SimpleLit 相同的关键字集(按本项目资产实际使用的维度保留)
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile_fog

            #pragma shader_feature_local _ _SPECULAR_SETUP
            #pragma shader_feature_local _ _SMOOTH_CYCLE
            #pragma shader_feature_local _ _PER_OBJECT_VARIATION

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uvLM       : TEXCOORD1;      // 烘焙光照贴图 UV
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float3 normalWS    : TEXCOORD0;
                float3 positionWS  : TEXCOORD1;
                float  fogFactor   : TEXCOORD2;
                float2 uvLM        : TEXCOORD3;
                #if defined(_MAIN_LIGHT_SHADOWS)
                    float4 shadowCoord : TEXCOORD4; // 顶点阶段算好,片元省矩阵乘
                #endif
            };

            Varyings vert (Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.positionWS  = TransformObjectToWorld(input.positionOS.xyz);
                output.normalWS    = TransformObjectToWorldNormal(input.normalOS);

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
                // ---------------- 表面(SimpleLit 字段,无贴图) ----------------
                half3 albedo = _BaseColor.rgb;
                half  alpha  = 1.0;

                // 无法线贴图 → 不需要 TBN
                half3 normalWS  = normalize(i.normalWS);
                half3 viewDirWS = normalize(GetWorldSpaceViewDir(i.positionWS));

                // ---------------- 每物体随机偏移 ----------------
                float seed = _Seed;
                #ifdef _PER_OBJECT_VARIATION
                    // 用物体世界原点哈希:同材质的每个实例错开闪烁相位
                    float3 pivotWS = mul(unity_ObjectToWorld, float4(0, 0, 0, 1)).xyz;
                    seed += frac(sin(dot(pivotWS.xz, float2(12.9898, 78.233))) * 43758.5453) * 100.0;
                #endif

                // =====================================================
                // 仿 SimpleLit(UniversalFragmentBlinnPhong)流程:
                // ① BRDFData(默认高光工作流;specColor = _SpecColor)
                // ② GlobalIllumination 间接光
                // ③/④ 每盏灯经 ProcessLightColor(基调×强度→随机) 再求值
                // =====================================================

                // ① BRDF —— fork 的 alpha 参数是 inout,必须传左值
                BRDFData brdfData;
                half alphaInOut = alpha;
                InitializeBRDFData(albedo, _Metallic, _SpecColor.rgb, _Smoothness, alphaInOut, brdfData);

                // ② 间接光:不随机,保持世界本色
                #ifdef LIGHTMAP_ON
                    half3 bakedGI = SampleLightmap(i.uvLM, normalWS);
                #else
                    half3 bakedGI = SampleSH(normalWS);
                #endif
                half3 color = GlobalIllumination(brdfData, bakedGI, 1.0, normalWS, viewDirWS);

                // ③ 主光
                #if defined(_MAIN_LIGHT_SHADOWS)
                    Light mainLight = GetMainLight(i.shadowCoord);
                #else
                    Light mainLight = GetMainLight();
                #endif
                mainLight.color = ProcessLightColor(mainLight.color, seed);
                color += LightingPhysicallyBased(brdfData, mainLight, normalWS, viewDirWS);

                // ④ 附加光:每盏灯独立随机(种子 + 灯序号 → 互不同步)
                #ifdef _ADDITIONAL_LIGHTS
                    uint lightCount = GetAdditionalLightsCount();
                    [loop]
                    for (uint k = 0u; k < lightCount; k++)
                    {
                        Light L = GetAdditionalLight(k, i.positionWS);
                        L.color = ProcessLightColor(L.color, seed + k * 7.31);
                        color += LightingPhysicallyBased(brdfData, L, normalWS, viewDirWS);
                    }
                #endif

                // ⑤ 曝光:与后处理 Post Exposure 同一公式
                color *= exp2(_Exposure);

                color = MixFog(color, i.fogFactor);
                return half4(color, alpha);
            }
            ENDHLSL
        }

        // ======================= 阴影投射 =======================
        Pass
        {
            Name "ShadowCaster"

            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0

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
            };

            struct ShadowVaryings
            {
                float4 positionHCS : SV_POSITION;
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
                return output;
            }

            half4 ShadowFrag (ShadowVaryings i) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }

        // ========================= 深度 =========================
        Pass
        {
            Name "DepthOnly"

            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ZTest LEqual
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex DepthOnlyVert
            #pragma fragment DepthOnlyFrag

            struct DepthOnlyAttributes
            {
                float4 positionOS : POSITION;
            };

            struct DepthOnlyVaryings
            {
                float4 positionHCS : SV_POSITION;
            };

            DepthOnlyVaryings DepthOnlyVert (DepthOnlyAttributes input)
            {
                DepthOnlyVaryings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 DepthOnlyFrag (DepthOnlyVaryings i) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }
    }

    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
