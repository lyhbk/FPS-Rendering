Shader "Custom/Plane"
{
    Properties
    {
        [MainTexture]_BaseTex ("地面基础贴图(RGBA)", 2D) = "gray" {}
        [MainColor]_BaseColor ("基础底色", Color) = (0.08,0.09,0.12,1)

        _NormalMap ("法线贴图", 2D) = "bump" {}
        _NormalStrength ("法线强度", Range(0,2)) = 0.4

        _Metallic ("金属度", Range(0,1)) = 0.15
        _Smoothness ("光滑度", Range(0,1)) = 0.3

        // 赛博霓虹网格线(程序化生成,已不再需要 _GridTex 贴图:
        // 用屏幕空间导数 fwidth 做自适应抗锯齿,零贴图采样且远处不会摩尔纹)
        _GridColor ("网格自发光HDR", Color) = (0,0.6,1.2,1)
        _GridTiling ("网格平铺", Vector) = (5,5,0,0)
        _GridWidth ("网格线宽", Range(0.5,8)) = 2.0
        _GridFadeStart ("网格淡出起始距离(米)", Float) = 15
        _GridFadeRange ("网格淡出过渡距离(米)", Float) = 30

        // 复用你项目的磨损噪点 _WearNoise
        _WearNoise ("磨损灰度遮罩", 2D) = "white" {}
        _WearAmount ("磨损强度", Range(0,1)) = 0.3
        _WearDarken ("磨损压暗程度", Range(0,1)) = 0.55

        // 自发光整体强度
        _EmissionStrength ("自发光强度", Range(0,10)) = 1.8

        // 雾对自发光的侵蚀程度:0 = 霓虹完全穿透雾(最亮),1 = 霓虹和表面一样被雾吃掉
        _EmissionFogAmount ("自发光受雾影响", Range(0,1)) = 0.3

        [Header(Switches)]
        // 法线 / 磨损:关掉各少一次贴图采样(带宽受限 GPU 收益明显)
        // 网格:程序化生成,关掉只省 ALU(不再占采样带宽)
        [Toggle(_NORMALMAP_ON)] _NormalMapOn("启用法线贴图", Float) = 1
        [Toggle(_WEARNOISE_ON)] _WearNoiseOn("启用磨损噪点", Float) = 1
        [Toggle(_GRIDTEX_ON)]   _GridTexOn("启用霓虹网格(程序化)", Float) = 1
    }

    SubShader
    {
        Tags
        {
            "RenderType"="Opaque"
            "Queue"="Geometry"
            "RenderPipeline"="UniversalPipeline"
        }
        LOD 200

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // URP关键字，支持光照贴图、实时光照
            #pragma multi_compile _ LIGHTMAP_ON
            // 主光阴影:URP 只在【Cascade Count = 1】时给 _MAIN_LIGHT_SHADOWS,
            // 在【≥ 2】时只给 _MAIN_LIGHT_SHADOWS_CASCADE —— 两个是互斥的。
            // 只声明前者的话,资产里级联数一调大,地面会彻底没有阴影且不报任何错。
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            // 软阴影变体:缺了它 SampleShadowmap 退化为【单抽头硬采样】,
            // 阴影边缘呈阶梯状锯齿,远看就是摩尔纹。
            // 资产里 Soft Shadows 打开时,必须编译这些变体才能吃到 PCF 滤波。
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS

            // 雾:URP 的雾是【逐 shader 声明】的,引擎不会自动加。
            // 缺了这一行 → 就算场景开了雾,本 shader 渲染的物体也完全不受影响。
            #pragma multi_compile_fog

            // ===== 外部可控开关(关掉即省一次贴图采样) =====
            #pragma shader_feature_local _ _NORMALMAP_ON
            #pragma shader_feature_local _ _WEARNOISE_ON
            #pragma shader_feature_local _ _GRIDTEX_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            // CommonMaterial.hlsl 提供 LerpWhiteTo(被 Shadows.hlsl 引用),必须在 Lighting 之前
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // ===== 贴图 + 采样器必须在 CBUFFER 外(URP 14) =====
            TEXTURE2D(_BaseTex);     SAMPLER(sampler_BaseTex);
            TEXTURE2D(_NormalMap);   SAMPLER(sampler_NormalMap);
            TEXTURE2D(_WearNoise);   SAMPLER(sampler_WearNoise);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseTex_ST;
                float4 _BaseColor;

                float4 _NormalMap_ST;
                float _NormalStrength;

                float _Metallic;
                float _Smoothness;

                float4 _GridColor;
                float2 _GridTiling;
                float _GridWidth;
                float _GridFadeStart;
                float _GridFadeRange;

                float4 _WearNoise_ST;
                float _WearAmount;
                float _WearDarken;

                float _EmissionStrength;
                float _EmissionFogAmount;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
                #ifdef LIGHTMAP_ON
                float2 uvLM : TEXCOORD1;
                #endif
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                #ifdef LIGHTMAP_ON
                float2 uvLM : TEXCOORD1;
                #endif
                float3 positionWS : TEXCOORD2;
                // TBN 只在启用法线贴图时才传递:关闭时 frag 直接用世界 up 常量,
                // 省掉 3 个 float3(9 个插值器),顶点带宽显著下降
                #ifdef _NORMALMAP_ON
                float3 normalWS : TEXCOORD3;
                float3 tangentWS : TEXCOORD4;
                float3 bitangentWS : TEXCOORD5;
                #endif
                // 阴影坐标在顶点算好插值过来(原来在 frag 里每像素做一次矩阵变换)
                #if defined(_MAIN_LIGHT_SHADOWS)
                float4 shadowCoord : TEXCOORD6;
                #endif
                #ifdef _ADDITIONAL_LIGHTS
                half3 vertexLighting : TEXCOORD7;      // 附加光在顶点着色器算好的结果
                #endif
                float fogFactor : TEXCOORD8;           // 雾因子:必须在顶点阶段算好再插值
            };

            Varyings vert (Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.positionWS = TransformObjectToWorld(input.positionOS.xyz);

                // ===== 法线 / TBN =====
                // 本 shader 语义为水平地面:法线恒为世界 up。
                // 只有启用法线贴图时才需要完整 TBN 并插值到片元;
                // 关闭时改用局部常量 nWS 参与顶点附加光,不占用任何插值器。
                #ifdef _NORMALMAP_ON
                    float3 nWS = TransformObjectToWorldNormal(float3(0,1,0));
                    output.normalWS    = nWS;
                    output.tangentWS   = TransformObjectToWorldDir(float3(1,0,0));
                    output.bitangentWS = cross(nWS, output.tangentWS);
                #else
                    float3 nWS = float3(0,1,0);
                #endif

                output.uv = TRANSFORM_TEX(input.uv, _BaseTex);
                #ifdef LIGHTMAP_ON
                output.uvLM = input.uvLM;
                #endif

                // 阴影坐标:顶点阶段算好插值过去。
                // 原来在 frag 里每像素做一次世界→阴影空间矩阵变换,地面屏幕占比大时浪费严重。
                #if defined(_MAIN_LIGHT_SHADOWS)
                    output.shadowCoord = TransformWorldToShadowCoord(output.positionWS);
                #endif

                // ===== 附加光源:在顶点着色器累加,插值后给片元用 =====
                // 原来这段在 frag 里 → 每个屏幕像素都要跑 N 次完整 PBR(GGX 高光很贵)。
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
                        vLight += L.color * L.distanceAttenuation * saturate(dot(nWS, L.direction));
                    }
                    output.vertexLighting = vLight;
                }
                #endif

                // 雾因子:必须传【裁剪空间 z】(output.positionHCS.z),
                // 不能传 NDC z(片元里 SV_POSITION.z 是 z/w,透视除法后已不是线性深度)。
                output.fogFactor = ComputeFogFactor(output.positionHCS.z);

                return output;
            }

            half4 frag(Varyings i) : SV_Target
            {
                // 基础颜色(唯一必采的贴图)
                half3 albedo = SAMPLE_TEXTURE2D(_BaseTex, sampler_BaseTex, i.uv).rgb * _BaseColor.rgb;

                // 磨损遮罩(可关闭)
                #ifdef _WEARNOISE_ON
                {
                    half wearMask = SAMPLE_TEXTURE2D(_WearNoise, sampler_WearNoise, TRANSFORM_TEX(i.uv, _WearNoise)).r;
                    wearMask = lerp(0, wearMask, _WearAmount);
                    albedo = lerp(albedo, albedo * (1 - _WearDarken), wearMask);
                }
                #endif

                // 法线(可关闭):关闭时法线不再通过插值器传递,直接用世界 up 常量
                half3 normalWS;
                #ifdef _NORMALMAP_ON
                {
                    half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, TRANSFORM_TEX(i.uv, _NormalMap)));
                    normalTS.xy *= _NormalStrength;
                    normalTS.z = sqrt(1 - saturate(dot(normalTS.xy, normalTS.xy)));
                    normalWS = TransformTangentToWorld(normalTS, half3x3(i.tangentWS, i.bitangentWS, i.normalWS));
                }
                #else
                    normalWS = half3(0, 1, 0);   // 水平地面:法线恒为世界上方向
                #endif

                // 主光(带实时阴影):阴影坐标已在顶点算好,这里零矩阵运算
                #if defined(_MAIN_LIGHT_SHADOWS)
                    Light mainLight = GetMainLight(i.shadowCoord);
                #else
                    Light mainLight = GetMainLight();
                #endif

                // PBR(URP 14 标准:BRDFData + InitializeBRDFData)
                // 第5参 alpha 是 inout,必须传变量
                half3 viewDirWS = normalize(GetWorldSpaceViewDir(i.positionWS));
                BRDFData brdfData;
                half alpha = 1.0;
                InitializeBRDFData(albedo, _Metallic, half3(0.04, 0.04, 0.04), _Smoothness, alpha, brdfData);
                half3 finalColor = LightingPhysicallyBased(brdfData, mainLight, normalWS, viewDirWS);

                // ===== 附加光源(逐顶点版本) =====
                // 光照已在 vert 阶段算好并插值过来,这里只做一次乘加。
                // 若要恢复逐像素精度:把这里改回 GetAdditionalLight 循环即可。
                #ifdef _ADDITIONAL_LIGHTS
                    finalColor += i.vertexLighting * brdfData.diffuse;
                #endif

                // ===== 间接漫反射 GI =====
                // 原写法把结果存进局部变量 lighting 后再没用过(死代码),
                // 导致烘焙光照贴图与环境光(SH)完全没生效。
                #ifdef LIGHTMAP_ON
                    half3 bakedGI = SampleLightmap(i.uvLM, normalWS);   // 静态:烘焙光照贴图
                #else
                    half3 bakedGI = SampleSH(normalWS);                 // 动态:球谐环境光
                #endif
                finalColor += bakedGI * brdfData.diffuse;

                // ===== 雾:只作用在【受光部分】,自发光单独处理 =====
                // URP 内置 Lit 是把雾混在【最终颜色】上,自发光会被一起吃暗 ——
                // 夜景里这会让霓虹全部死掉。这里拆开处理:
                //   受光部分:正常混雾 → 远处表面 fade 进天空色,产生纵深
                //   自发光  :按 _EmissionFogAmount 决定吃多少雾(默认 0.3,保持霓虹穿透力)
                finalColor = MixFog(finalColor, i.fogFactor);

                // 霓虹网格自发光(可关闭)
                // 程序化生成:零贴图采样,用屏幕空间导数 fwidth 做自适应抗锯齿,
                // 线宽在任何距离都保持恒定像素宽度,彻底消除远处摩尔纹与闪烁。
                #ifdef _GRIDTEX_ON
                {
                    float2 gridUV = i.uv * _GridTiling;
                    float2 gridDeriv = fwidth(gridUV);                 // UV 的屏幕空间变化率
                    float2 gridDist  = abs(frac(gridUV - 0.5) - 0.5) / max(gridDeriv, 1e-5);
                    float  lineMask  = 1.0 - saturate(min(gridDist.x, gridDist.y) * _GridWidth);

                    // 距离淡出:远处地面不再发光,省 ALU 同时避免噪点/摩尔纹
                    float distCam  = distance(i.positionWS, _WorldSpaceCameraPos);
                    float gridFade = 1.0 - saturate((distCam - _GridFadeStart) / max(_GridFadeRange, 1e-3));

                    // 自发光按 _EmissionFogAmount 决定吃多少雾(0=完全穿透,1=与表面一致)
                    half3 gridEmis = lineMask * gridFade * _GridColor.rgb * _EmissionStrength;
                    gridEmis = lerp(gridEmis, MixFog(gridEmis, i.fogFactor), _EmissionFogAmount);
                    finalColor += gridEmis;
                }
                #endif

                return half4(finalColor,1);
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

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
            };

            Varyings vertDepthOnly(Attributes input)
            {
                Varyings o;
                o.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                return o;
            }

            half4 fragDepthOnly(Varyings i) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }


        Pass
        {
            Name "ShadowCaster"
            Tags{"LightMode" = "ShadowCaster"}
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            // CommonMaterial.hlsl 必须在 Shadows 之前(顺序问题导致 LerpWhiteTo 未定义)
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            // 引擎在阴影 Pass 前注入的全局量,需在 shader 中声明
            float3 _LightDirection;

            struct Attributes { float4 posOS : POSITION; float2 uv : TEXCOORD0;};
            struct Varyings { float4 posHCS : SV_POSITION;};

            Varyings vert(Attributes input)
            {
                Varyings o;
                float3 posWS = TransformObjectToWorld(input.posOS.xyz);
                o.posHCS = TransformWorldToHClip(ApplyShadowBias(posWS, normalize(TransformObjectToWorldNormal(float3(0,1,0))), _LightDirection));
                return o;
            }
            half4 frag() : SV_Target { return 0; }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}

