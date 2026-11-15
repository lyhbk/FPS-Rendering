Shader "Custom/UI/Target"
{
    Properties
    {
        [PerRendererData] _MainTex ("Sprite Texture", 2D) = "white" {}
        _Color ("Tint", Color) = (1,1,1,1)
        _BlackThreshold("∫⁄…´„–÷µ", Range(0,0.3)) = 0.15
        [Toggle] _UseClip("”≤≤√«–", Float) = 1
    }
    SubShader
    {
        Tags
        {
            "Queue"="Transparent"
            "RenderType"="Transparent"
            "IgnoreProjector"="True"
            "RenderPipeline"="UniversalPipeline"
            "PreviewType"="Plane"
            "CanUseSpriteAtlas"="True"
        }
        LOD 100
        ZWrite Off
        Blend SrcAlpha OneMinusSrcAlpha
        Cull Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"
            #include "UnityUI.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };
            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _Color;
            float _BlackThreshold;
            float _UseClip;

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                return o;
            }

            fixed4 frag (v2f i) : SV_Target
            {
                fixed4 col = tex2D(_MainTex, i.uv) * _Color;
                //º∆À„RGB¡¡∂»
                float lum = Luminance(col.rgb);
                //¡¡∂»µÕ”⁄„–÷µ£¨alpha÷√0
                if(lum < _BlackThreshold)
                {
                    col.a = 0;
                }
                //”≤≤√«–ƒ£ Ω£¨÷±Ω”∂™∆˙œÒÀÿ
                if(_UseClip > 0)
                {
                    clip(col.a - 0.01);
                }
                return col;
            }
            ENDCG
        }
    }
}

