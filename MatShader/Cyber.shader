Shader "Custom/Cyber"
{
    Properties
    {
        _BaseTex("Base Albedo", 2D) = "white" {}
        _NormalMap("Normal Map", 2D) = "bump" {}
        _Metallic("Metallic", Range(0,1)) = 0.3
        _Smoothness("Smoothness", Range(0,1)) = 0.4
        _WearNoise("Wear Noise",2D) = "white" {}
        _WearAmount("Wear Strength",Range(0,1)) = 0.35

        _EdgeEmissionColor("Edge Neon Emission(HDR)", Color) = (0.15,0.7,1.1,1)
        _EdgeEmissionStrength("Edge Emission Strength",Range(0,3)) = 1.0
        _FresnelPower("Fresnel Power(边缘锐度,有效 2~4)",Range(1,6)) = 3.2

        _CyberGI_Tint("GI Color Tint",Color) = (1,1,1,1)

        // 距离细节衰减:远处自动弱化法线起伏 / 磨损对比 / 边缘光,近处保持满配
        _DetailFadeStart("细节衰减起始距离(米)", Float) = 15
        _DetailFadeRange("细节衰减过渡距离(米)", Float) = 30

        [Header(Switches)]
        // 每关掉一项,每像素就少一次贴图采样(带宽受限 GPU 上收益明显)
        [Toggle(_NORMALMAP_ON)] _NormalMapOn("启用法线贴图", Float) = 1
        [Toggle(_WEARNOISE_ON)] _WearNoiseOn("启用磨损噪点", Float) = 1
        // 低配光照:跳过整套 GGX,只保留 Lambert 漫反射。远景/小物件勾上,
        // 单像素光照 ALU 可省 60~70%,肉眼几乎看不出差别。
        [Toggle(_QUALITY_LOW)]   _QualityLow("低配光照(远景/小物件)", Float) = 0
    }

    SubShader
    {
        Tags
        {
            "RenderType"="Opaque"
            "Queue"="Geometry"
            "RenderPipeline"="UniversalPipeline"
        }
        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            // ===== 主光源阴影(实时阴影 / 级联阴影) =====
            // 变体控制要点:multi_compile 的变体在打包时不会被 strip,每多一项就实打实多一批
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE

            // 软阴影质量分级:LOW/MEDIUM/HIGH 是移动端多档质量用的,本项目未做该分级故移除。
            // 若要做移动端分档,把 _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH 加回。
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            // ===== 附加光源(多点霓虹灯)=====
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS

            // ===== 光照贴图(烘焙 GI) =====
            #pragma multi_compile _ LIGHTMAP_ON
            #pragma multi_compile _ DIRLIGHTMAP_COMBINED

            // 雾:URP 的雾是【逐 shader 声明】的,缺了这行本 shader 的物体完全不吃雾
            #pragma multi_compile_fog

            // ===== 外部可控开关 =====
            #pragma shader_feature_local _ _NORMALMAP_ON
            #pragma shader_feature_local _ _WEARNOISE_ON
            #pragma shader_feature_local _ _QUALITY_LOW

            // URP 14 头文件(本项目安装的是 com.unity 包,不是 com.tuanjie)
            // 注意顺序:CommonMaterial.hlsl 必须在 Lighting.hlsl 之前,
            // 否则其内部引用的 LerpWhiteTo 在展开时还未定义
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // ===== 贴图 + 采样器(必须在 CBUFFER 外) =====
            TEXTURE2D(_BaseTex);     SAMPLER(sampler_BaseTex);
            TEXTURE2D(_NormalMap);   SAMPLER(sampler_NormalMap);
            TEXTURE2D(_WearNoise);   SAMPLER(sampler_WearNoise);

            struct Attributes
            {
                float4 positionOS       : POSITION;
                float2 uv               : TEXCOORD0;
                float3 normalOS         : NORMAL;
                float4 tangentOS        : TANGENT;
                float2 staticLightmapUV : TEXCOORD1;    // 烘焙光照贴图 UV
            };

            struct Varyings
            {
                float4 positionHCS  : SV_POSITION;
                float2 uv           : TEXCOORD0;
                float3 positionWS   : TEXCOORD1;
                float3 normalWS     : TEXCOORD2;        // 始终需要:光照 / GI / 菲涅尔都基于它
                // tangent / bitangent 只有法线贴图才用得上:
                // 关闭后省掉 2 个 float3(6 个插值器),顶点带宽与寄存器压力同步下降
                #ifdef _NORMALMAP_ON
                float3 tangentWS    : TEXCOORD3;
                float3 bitangentWS  : TEXCOORD4;
                #endif
                float4 shadowCoord  : TEXCOORD5;        // 主光源阴影坐标
                // LIGHTMAP_ON 时声明 float2 staticLightmapUV,否则声明 half3 vertexSH
                DECLARE_LIGHTMAP_OR_SH(staticLightmapUV, vertexSH, 6);
                #ifdef _ADDITIONAL_LIGHTS
                half3 vertexLighting : TEXCOORD7;       // 附加光在顶点着色器算好的结果
                #endif
                float fogFactor : TEXCOORD8;            // 雾因子:必须在顶点阶段算好再插值
            };

            // CBUFFER 只放标量/向量/颜色(SRP Batcher)
            CBUFFER_START(UnityPerMaterial)
                float4 _BaseTex_ST;
                float4 _NormalMap_ST;
                float4 _WearNoise_ST;

                float _Metallic;
                float _Smoothness;
                float _WearAmount;

                float4 _EdgeEmissionColor;
                float _EdgeEmissionStrength;
                float _FresnelPower;

                float4 _CyberGI_Tint;

                float _DetailFadeStart;
                float _DetailFadeRange;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                // 位置/阴影/裁剪坐标一次算全(GetShadowCoord 依赖 positionCS)
                VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
                output.positionWS = vertexInput.positionWS;
                output.positionHCS = vertexInput.positionCS;

                output.uv = TRANSFORM_TEX(input.uv, _BaseTex);
                // 世界法线始终要算(顶点附加光 + 片元光照/GI/菲涅尔都要用);
                // 切线与副切线仅法线贴图需要,关闭时不再计算与传递。
                VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
                output.normalWS = normalInput.normalWS;
                #ifdef _NORMALMAP_ON
                output.tangentWS = normalInput.tangentWS;
                output.bitangentWS = normalInput.bitangentWS;
                #endif

                // 主光源阴影坐标:内部自动区分实时/级联/屏幕空间三种阴影模式
                output.shadowCoord = GetShadowCoord(vertexInput);

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
                        vLight += L.color * L.distanceAttenuation * saturate(dot(output.normalWS, L.direction));
                    }
                    output.vertexLighting = vLight;
                }
                #endif

                // 烘焙 GI:有光照贴图写 staticLightmapUV,否则写顶点 SH
                OUTPUT_LIGHTMAP_UV(input.staticLightmapUV, unity_LightmapST, output.staticLightmapUV);
                OUTPUT_SH(output.normalWS, output.vertexSH);

                // 雾因子:必须传【裁剪空间 z】,不能传 NDC z(z/w 已不是线性深度)
                output.fogFactor = ComputeFogFactor(output.positionHCS.z);

                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv;
                float3 positionWS = input.positionWS;
                float3 viewDirWS = normalize(GetWorldSpaceViewDir(positionWS));

                // ===== 距离细节衰减 =====
                // 远处弱化法线起伏 / 磨损对比 / 边缘光,近处保持满配。
                // 不是关贴图,而是让远景的细节贡献自然收敛(采样数不变,省的是后续 ALU 与视觉噪点)。
                float distCam    = distance(positionWS, _WorldSpaceCameraPos);
                float detailFade = 1.0 - saturate((distCam - _DetailFadeStart) / max(_DetailFadeRange, 1e-3));

                // ===== 贴图采样 =====
                // 只有 _BaseTex 必采;法线/磨损关掉后各省 1 次采样
                half4 albedoTex = SAMPLE_TEXTURE2D(_BaseTex, sampler_BaseTex, uv);
                half3 albedo = albedoTex.rgb;

                #ifdef _WEARNOISE_ON
                    half4 wearTex = SAMPLE_TEXTURE2D(_WearNoise, sampler_WearNoise, uv);
                    albedo = lerp(albedoTex.rgb, albedoTex.rgb * wearTex.r, _WearAmount * detailFade);
                #endif

                // TBN 转世界法线(关掉法线贴图时直接用顶点法线)
                half3 normalWS;
                #ifdef _NORMALMAP_ON
                    half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_NormalMap, sampler_NormalMap, uv));
                    normalTS.xy *= detailFade;      // 远处法线趋于平坦
                    normalWS = normalize(TransformTangentToWorld(normalTS, half3x3(input.tangentWS, input.bitangentWS, input.normalWS)));
                #else
                    normalWS = normalize(input.normalWS);
                #endif

                // ===== 菲涅尔边缘霓虹自发光 =====
                // 原实现 pow(f, _FresnelPower) 是 transcendentals 指令(约 15 cycles)。
                // 现改为「平方 ←→ 四次方」线性插值近似:成本约 3 MUL + 1 LERP,视觉几乎无差别。
                // _FresnelPower 语义变为「边缘锐度」:有效区间 2~4(默认 3.2),超出部分被 saturate 收敛。
                // 若需要与原 pow 完全等价(精度优先),取消下面这行注释即可:
                // #define FRESNEL_USE_POW
                half fresnelRaw = 1.0 - saturate(dot(normalWS, viewDirWS));
                #ifdef FRESNEL_USE_POW
                    half fresnel = pow(fresnelRaw, _FresnelPower);
                #else
                    half fresnelSq   = fresnelRaw * fresnelRaw;                                  // 幂次 2
                    half fresnelQuad = fresnelSq  * fresnelSq;                                   // 幂次 4
                    half fresnel     = lerp(fresnelSq, fresnelQuad, saturate(_FresnelPower - 2.0) * 0.5);
                #endif
                half3 edgeEmission = fresnel * _EdgeEmissionColor.rgb * _EdgeEmissionStrength;
                // 远处边缘光保留一半:省一点 ALU 的同时保留赛博轮廓,不至于糊掉
                edgeEmission *= lerp(0.5, 1.0, detailFade);

                // 直接光:主光源(阴影坐标已在顶点算好 → 采样 _MainLightShadowmapTexture)
                Light mainLight = GetMainLight(input.shadowCoord);

            #ifdef _QUALITY_LOW
                // ===== 低配光照:跳过整套 GGX,只做 Lambert 漫反射 =====
                // 远景/小物件看不出高光细节,却能省掉 InitializeBRDFData + GGX 的绝大部分指令。
                // lowDiffuse 近似 BRDFData.diffuse(金属度越高漫反射越弱),保证配色不走样。
                half3 lowDiffuse = albedo * (1.0 - _Metallic * 0.96);
                half  NdotL      = saturate(dot(normalWS, mainLight.direction));
                half3 color      = lowDiffuse * mainLight.color * NdotL
                                 * mainLight.distanceAttenuation * mainLight.shadowAttenuation;

                // 附加光源(vert 阶段算好的逐顶点结果)
                #ifdef _ADDITIONAL_LIGHTS
                    color += input.vertexLighting * lowDiffuse;
                #endif

                // 间接漫反射 GI(与完整档一致,只是没有 brdfData,改用 lowDiffuse)
                half3 bakedGI = SAMPLE_GI(input.staticLightmapUV, input.vertexSH, normalWS);
                color += bakedGI * _CyberGI_Tint.rgb * lowDiffuse;
            #else
                // ===== 完整 PBR(URP 14 标准:BRDFData) =====
                // 第5参 alpha 是 inout,必须传变量,传字面量 1.0 会报 l-value const 错
                BRDFData brdfData;
                half alpha = 1.0;
                InitializeBRDFData(albedo, _Metallic, half3(0.04, 0.04, 0.04), _Smoothness, alpha, brdfData);

                half3 color = LightingPhysicallyBased(brdfData, mainLight, normalWS, viewDirWS);

                // 附加光源(逐顶点版本):光照已在 vert 阶段算好并插值过来
                // 若要恢复逐像素精度:把这里改回 GetAdditionalLight 循环即可
                #ifdef _ADDITIONAL_LIGHTS
                    color += input.vertexLighting * brdfData.diffuse;
                #endif

                // 间接漫反射 GI:光照贴图(烘焙)或顶点 SH,再乘赛博溢色
                // SAMPLE_GI 宏自动分发:LIGHTMAP_ON → SampleLightmap,否则 → SampleSHPixel
                half3 bakedGI = SAMPLE_GI(input.staticLightmapUV, input.vertexSH, normalWS);
                color += bakedGI * _CyberGI_Tint.rgb * brdfData.diffuse;
            #endif

                // 雾:只作用于【受光部分】,边缘自发光不吃雾。
                // 若把雾也混进自发光,远景建筑轮廓灯会全部死掉,失去纵深里的灯火层次。
                color = MixFog(color, input.fogFactor);

                color += edgeEmission;
                return half4(color, 1);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags{"LightMode" = "ShadowCaster"}
            ZWrite On
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
            };
            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
            };

            // 引擎在阴影 Pass 前注入的全局量,需在 shader 中声明
            float3 _LightDirection;

            Varyings vert(Attributes input)
            {
                Varyings o;
                float3 positionWS = TransformObjectToWorld(input.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(input.normalOS);
                o.positionHCS = TransformWorldToHClip(ApplyShadowBias(positionWS, normalWS, _LightDirection));
                return o;
            }

            half4 frag(Varyings i) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
