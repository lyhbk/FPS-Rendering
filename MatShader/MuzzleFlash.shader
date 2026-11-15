Shader "Custom/MuzzleFlash"
{
    Properties
    {
        _MainTex ("闪光贴图", 2D) = "white" {}
        _Tint ("颜色", Color) = (1,0.7,0.3,1)
        _Intensity ("亮度", Range(0, 10)) = 3
        _SoftEdge ("边缘软化", Range(0.01, 1)) = 0.2
    }
    SubShader
    {
        Tags
        {
            "RenderType"="Transparent"
            "Queue"="Transparent"
            "RenderPipeline"="UniversalPipeline"
        }
        LOD 100
        ZWrite Off
        Blend SrcAlpha One // 加法混合！枪口闪光必须用加法，亮部叠加
        Cull Off

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv : TEXCOORD0;
            };
            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _Tint;
                float _Intensity;
                float _SoftEdge;
            CBUFFER_END

            Varyings vert (Attributes input)
            {
                Varyings output;
                output.positionHCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = TRANSFORM_TEX(input.uv, _MainTex);
                return output;
            }

            half4 frag(Varyings input) : SV_Target
            {
                half4 texCol = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv);
                half mask = smoothstep(_SoftEdge, 1, texCol.a);
                half3 finalCol = texCol.rgb * _Tint.rgb * _Intensity * mask;
                return half4(finalCol, mask);
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}

