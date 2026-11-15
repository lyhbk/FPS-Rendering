Shader "Custom/BurnDecal"
{
    Properties
    {
        [Header(Charring)]
        _BurnTex ("灼烧贴图(白色=纯程序化,可拖入生成图)", 2D) = "white" {}
        // 加法模式下颜色应为 HDR 烧痕色调(>1 才能穿透亮场景的 bloom/HDR tonemap)
        _TintColor ("灼烧染色(加法模式用 HDR 色)", Color) = (1.4, 0.5, 0.15, 1)
        _CharColor ("碳化核心色(加法模式下应为深红/暗橙)", Color) = (0.5, 0.1, 0.05, 1)
        _CharRadius ("碳化半径", Range(0.3, 1)) = 0.62
        _CharSoftness ("碳化软边宽度", Range(0.01, 0.5)) = 0.18
        _CoreDarken ("核心加深(到 _CharColor 的程度)", Range(0, 1)) = 0.85
        _BurnIntensity ("加法着色强度(亮场景中调高)", Range(0, 3)) = 1.5
        _EdgeRoughness ("边缘粗糙度", Range(0, 1)) = 0.5
        _NoiseScale ("痕迹噪声频率", Range(1, 12)) = 6

        [Header(Ember)]
        _EmberColor ("余烬颜色(HDR)", Color) = (3, 0.8, 0.15, 1)
        _EmberWidth ("余烬环宽度", Range(0.01, 0.4)) = 0.1
    }
    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "Queue" = "Geometry+1"
            "RenderPipeline"="UniversalPipeline"
        }

        // ================= Pass 1: 碳化痕迹 =================
        // 方法 A2:从 Multiply 改为 Additive,解决"亮场景 + Bloom + HDR tonemap 下被洗掉"的问题
        //   - 旧:Blend DstColor Zero → dst *= lerp(white, dark, alpha),HDR 高亮表面 multiply 0.02 ≈ 不可见
        //   - 新:Blend One One       → dst += charCol * alpha * intensity,HDR 颜色可直接穿透 bloom
        Pass
        {
            Name "CHAR"
            ZWrite Off
            ZTest Always    // 全屏三角 z=0 在 Reversed-Z 的 LEqual 下会裁掉远处场景
            Blend One One   // 加法,叠加 HDR 烧痕染色
            Cull Off

            HLSLPROGRAM
            #pragma target 4.5          // StructuredBuffer 逐像素读取需要 SM4.5
            #pragma vertex BurnDecalVertImpl
            #pragma fragment frag

            #include "Assets/MatShader/BurnDecalCommon.hlsl"

            BurnDecalVaryings BurnDecalVertImpl(BurnDecalAttributes input)
            {
                return BurnDecalVert(input);
            }

            half4 frag(BurnDecalVaryings i) : SV_Target
            {
                // 深度重建 → 盒局部坐标(团结引擎 API:SampleSceneDepth)
                // 用缩放后的 RT 尺寸,保证 RenderScale < 1 时 UV 仍然正确。
                // 命中面不写深度(纯碰撞体/透明材质)时自动回退到盒中心平面求交,
                // 见 BurnDecalResolveBoxLocal —— 不再需要额外的深度代理盒。
                float2 uvScreen = BurnDecalScreenUV(i.positionHCS.xy);
                DecalData dd = _DecalData[i.instanceID];
                float3 boxLocal = BurnDecalResolveBoxLocal(uvScreen, dd);
                float3 halfSize = dd.boxSize.xyz * 0.5;

                // 盒体裁剪,超出盒子直接 discard
                float3 axisMask = saturate((halfSize - abs(boxLocal)) / halfSize);
                float boxMask = axisMask.x * axisMask.y * axisMask.z;
                clip(boxMask - 0.001);

                // Z 轴为投射方向,把盒内 XY 映射到贴花 UV
                float2 decalUV = boxLocal.xy / (dd.boxSize.xy) + 0.5;
                float2 uvTex = TRANSFORM_TEX(decalUV, _BurnTex);

                float charAlpha, coreMask, emberRing;
                BurnDecalEval(decalUV, uvTex, dd.fadeAge.y, charAlpha, coreMask, emberRing);

                float alpha = charAlpha * boxMask * dd.fadeAge.x;
                clip(alpha - 0.001);

                // 碳化颜色:边缘用 _TintColor(亮橙),核心过渡到 _CharColor(深红)
                //   加法模式下,色值越亮 = 加得越多,中心自然形成"较暗的烧焦核心"效果
                half3 charCol = lerp(_TintColor.rgb, _CharColor.rgb, coreMask * _CoreDarken);

                // 加法混合(预乘):输出 charCol * alpha * intensity,加到 dst.rgb 上
                //   视觉上从"烧黑"变成"霓虹烧痕",亮场景也能看清
                half3 col = charCol * alpha * _BurnIntensity;
                return half4(col, alpha);
            }
            ENDHLSL
        }

        // ================= Pass 2: 余烬边缘(加法发光) =================
        Pass
        {
            Name "EMBER"
            ZWrite Off
            ZTest Always
            Blend One One       // 加法,余烬叠加在已烧黑的痕迹边缘
            Cull Off

            HLSLPROGRAM
            #pragma target 4.5
            #pragma vertex BurnDecalVertImpl
            #pragma fragment frag

            #include "Assets/MatShader/BurnDecalCommon.hlsl"

            BurnDecalVaryings BurnDecalVertImpl(BurnDecalAttributes input)
            {
                return BurnDecalVert(input);
            }

            half4 frag(BurnDecalVaryings i) : SV_Target
            {
                // 与 Pass1 相同的深度重建 + 无深度回退 + 实例数据 + 盒体裁剪
                float2 uvScreen = BurnDecalScreenUV(i.positionHCS.xy);
                DecalData dd = _DecalData[i.instanceID];
                float3 boxLocal = BurnDecalResolveBoxLocal(uvScreen, dd);
                float3 halfSize = dd.boxSize.xyz * 0.5;

                float3 axisMask = saturate((halfSize - abs(boxLocal)) / halfSize);
                float boxMask = axisMask.x * axisMask.y * axisMask.z;
                clip(boxMask - 0.001);

                float2 decalUV = boxLocal.xy / (dd.boxSize.xy) + 0.5;
                float2 uvTex = TRANSFORM_TEX(decalUV, _BurnTex);

                float charAlpha, coreMask, emberRing;
                BurnDecalEval(decalUV, uvTex, dd.fadeAge.y, charAlpha, coreMask, emberRing);

                float glow = emberRing * boxMask * dd.fadeAge.x;
                clip(glow - 0.001);

                // 加法混合:直接输出余烬颜色,叠加在烧痕边缘
                return half4(_EmberColor.rgb * glow, glow);
            }
            ENDHLSL
        }
    }
    FallBack "Hidden/Universal Render Pipeline/FallbackError"
}
