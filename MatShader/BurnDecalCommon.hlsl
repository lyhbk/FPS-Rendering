#ifndef BURN_DECAL_COMMON_INCLUDED
#define BURN_DECAL_COMMON_INCLUDED

// BurnDecal 两个 Pass(碳化乘法 / 余烬加法)共用的顶点、uniforms 与碳化评估逻辑
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

// ---------------- 屏幕 UV(关键:必须用【缩放后】的尺寸) ----------------
// RenderScale < 1 时,相机 RT 与 _CameraDepthTexture 的实际尺寸 = 屏幕尺寸 × RenderScale。
// 若拿 _ScreenParams(最终屏幕尺寸)去归一化,UV 只会覆盖到 0..renderScale 而不是 0..1,
// 于是采样到偏移后的深度 → 重建的世界坐标整体位移 → 贴花偏移。
//
// URP 官方贴花 ShaderPassDecal.hlsl 用的是 _ScreenSize.zw(缩放尺寸的倒数),
// 这里等价地用 _ScaledScreenParams —— RenderScale = 1 时两者相同,所以改动向下兼容。
//
// 注意:不要改用 GetNormalizedScreenSpaceUV(),它会额外翻转 Y;
// 而 ComputeWorldSpacePosition 内部(ComputeClipSpacePosition)已经处理过翻转,
// 再翻一次会导致上下颠倒。
float2 BurnDecalScreenUV(float2 positionHCS)
{
    return positionHCS.xy / _ScaledScreenParams.xy;
}

// ---------------- 实例化数据(由 DecalRenderFeature 每帧打包上传) ----------------
// 与 DecalRenderFeature.DecalPass.DecalData 结构逐字段对应,共 160 字节
struct DecalData
{
    float4x4 worldToBox;   // 世界 -> 贴花盒局部矩阵
    float4x4 boxToWorld;   // 贴花盒局部 -> 世界(顶点阶段投影包围盒要用)
    float4   boxSize;      // xyz = 盒子尺寸
    float4   fadeAge;      // x = 整体淡化(0~1), y = 归一化年龄(0=炽热 1=冷却)
};

StructuredBuffer<DecalData> _DecalData;

struct BurnDecalAttributes
{
    uint id : SV_VertexID;
};

struct BurnDecalVaryings
{
    float4 positionHCS : SV_POSITION;
    float2 uv          : TEXCOORD0;
    nointerpolation uint instanceID : TEXCOORD1;
};

TEXTURE2D(_BurnTex); SAMPLER(sampler_BurnTex);

CBUFFER_START(UnityPerMaterial)
    float4 _BurnTex_ST;
    float4 _TintColor;
    float4 _CharColor;
    float4 _EmberColor;
    float  _CharRadius;
    float  _CharSoftness;
    float  _EdgeRoughness;
    float  _CoreDarken;
    float  _BurnIntensity;
    float  _EmberWidth;
    float  _NoiseScale;
CBUFFER_END

// ---------------- 质量降级:噪声层数由 CPU 每帧下发 ----------------
// 本 Pass 的开销 = 贴花数 N × 全屏像素数(每个贴花一个全屏三角,与它在屏幕上占多大无关),
// 所以 N 是最直接的开销杠杆。N 超过阈值时 CPU 侧把 _DecalFbmOct 调小,直接省 ALU。
// 取值 1~4,<=0 视为未下发,按最高画质 4 层处理(保证 SceneView/未初始化时不为 0)。
float _DecalFbmOct;

// ---------------- 程序化噪声 ----------------
float bdHash12(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float bdVNoise(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = bdHash12(i);
    float b = bdHash12(i + float2(1.0, 0.0));
    float c = bdHash12(i + float2(0.0, 1.0));
    float d = bdHash12(i + float2(1.0, 1.0));
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

float bdFbm(float2 p)
{
    // 层数由 _DecalFbmOct 动态控制(降级时变 2 / 1 层,视觉上只是边缘噪点略平滑)
    int oct = _DecalFbmOct > 0.5 ? (int)(_DecalFbmOct + 0.5) : 4;
    oct = clamp(oct, 1, 4);

    float v = 0.0;
    float a = 0.5;
    [loop]
    for (int i = 0; i < oct; i++)
    {
        v += a * bdVNoise(p);
        p = p * 2.03 + 17.17;
        a *= 0.5;
    }
    return v;
}

// ---------------- 顶点:按【屏幕投影包围盒】生成矩形(多贴花合批) ----------------
// 一次 DrawProcedural 画 6×N 个顶点(N=贴花数):
//   id / 6 = 实例(贴花)索引,id % 6 = 矩形的 6 个角(2 个三角)
//
// 【为什么不用全屏三角】全屏三角的片元着色器要跑遍【整个屏幕】再由 boxMask
//   clip 掉盒子外的像素,成本 = N × 全屏像素 × 2(CHAR+EMBER 两个 Pass),
//   与贴花在屏幕上占多大【完全无关】—— 这是填充率瓶颈的最大来源。
//   改成投影包围盒后成本 = N × 实际投影面积,小贴花能省 90% 以上。
//
// 【顺带修复】全屏三角若写成 uv*2.0-1.0,三个角是 (-1,-1)(1,-1)(-1,1),
//   只覆盖 x+y<=0 的左下角半屏,右上半屏贴花根本不会被光栅化。
//   现在矩形精确覆盖包围盒,该问题一并消失。

// 把贴花盒 8 个角投到裁剪空间,取 NDC 包围盒。返回 xy=min, zw=max(已夹进视口)
float4 BurnDecalClipBounds(uint instanceID)
{
    DecalData dd = _DecalData[instanceID];
    float3 h = dd.boxSize.xyz * 0.5;

    // 先合成 MVP,循环里就只剩 1 次矩阵乘向量
    float4x4 mvp = mul(UNITY_MATRIX_VP, dd.boxToWorld);

    float2 ndcMin = float2( 1e9,  1e9);
    float2 ndcMax = float2(-1e9, -1e9);
    bool anyBehind = false;

    // 8 个角 (±h.x, ±h.y, ±h.z)
    // 与片元里 abs(boxLocal) <= halfSize 的【居中盒】保持一致
    [unroll]
    for (int i = 0; i < 8; i++)
    {
        float3 local = float3(
            (i & 1) ? h.x : -h.x,
            (i & 2) ? h.y : -h.y,
            (i & 4) ? h.z : -h.z);

        float4 clip = mul(mvp, float4(local, 1.0));

        // w <= 0 表示这个角在相机后方。只要有角在后方,投影会翻转导致包围盒算错,
        // 这里保守退回全屏(贴花贴到相机近平面时才会发生,极少见但必须正确处理)。
        if (clip.w > 1e-5)
        {
            float2 ndc = clip.xy / clip.w;
            ndcMin = min(ndcMin, ndc);
            ndcMax = max(ndcMax, ndc);
        }
        else
        {
            anyBehind = true;
        }
    }

    if (anyBehind) return float4(-1.0, -1.0, 1.0, 1.0);

    // 留几像素余量,防止光栅化时把恰好落在边缘上的像素裁掉
    float2 margin = 4.0 / _ScaledScreenParams.xy;
    ndcMin -= margin;
    ndcMax += margin;

    return float4(clamp(ndcMin, -1.0, 1.0), clamp(ndcMax, -1.0, 1.0));
}

// ---------------- 深度重建 + 无深度回退 ----------------
// 输入:屏幕 UV、实例数据;输出:【贴花盒局部坐标】。
//
// 背景(为什么要回退):
//   本贴花靠 _CameraDepthTexture 逐像素重建世界坐标。若命中面【不写深度】——
//   纯碰撞体、透明材质、自发光装饰等——该像素深度恒为远平面,重建点会落到
//   几百米外,被盒体裁剪丢掉,贴花整片消失。
//
//   以前靠在命中点再放一个"看不见的代理盒"补深度,但代理与真实墙面共面会
//   抢深度缓冲,产生 Z-fighting 闪烁。
//
//   现在:深度无效时,直接用【视线与贴花盒求交】得到表面点。盒子的位置、
//   朝向、尺寸本来就记录着命中信息,这个点就是目标表面 —— 不需要任何额外
//   几何体,自然也就没有共面问题。
//
// 三种情况:
//   ① 深度重建点在盒内(或盒前) → 原样返回(与改动前行为完全一致)
//   ② 深度采到的是贴花平面【之后】的东西,或根本没有几何 → 平面求交回退(新增)
//   ③ 视线几乎平行于贴花平面 / 平面在相机后方 → 返回盒外坐标,被 boxMask 裁掉
float3 BurnDecalResolveBoxLocal(float2 uvScreen, DecalData dd)
{
    float3 halfSize = dd.boxSize.xyz * 0.5;

    float rawDepth   = SampleSceneDepth(uvScreen);
    float eyeDepth   = LinearEyeDepth(rawDepth, _ZBufferParams);
    bool  depthValid = eyeDepth < _ProjectionParams.z * 0.999;

    if (depthValid)
    {
        float3 worldPos = ComputeWorldSpacePosition(uvScreen, rawDepth, UNITY_MATRIX_I_VP);
        float3 p = mul(dd.worldToBox, float4(worldPos, 1.0)).xyz;

        // 点在盒内 → 就是真实表面,原样返回(绝大多数情况走这里,行为不变)
        // 点在盒前(z <= 0,即比贴花更靠近相机)→ 交给外层 boxMask 裁掉,
        //   保证前景物体能正常遮挡贴花(同样保持原行为)
        if (all(abs(p) <= halfSize) || p.z <= 0.0) return p;

        // 其余:深度采到的是【贴花平面之后】的物体 —— 说明这片表面自己不写深度
        // (透明材质 / 纯碰撞体 / 自发光装饰),不是要贴的面 → 走回退
    }

    // ---- 回退:视线与盒中心平面(z = 0)求交 ----
    // 贴花创建时 position = 命中点、+Z 对齐 -法线,所以命中面就是盒的 z=0 平面。
    // 【不能用"盒体进入点"】—— 进入点落在盒边界上,boxMask 在那里恰好为 0,
    // 会让整片贴花被裁掉。用中心平面交点,z 恒为 0,boxMask.z 恒为 1。
    //
    // 用远平面点减相机位置得到视线方向,后面只取比例,无需归一化。
    float3 farPos  = ComputeWorldSpacePosition(uvScreen, UNITY_RAW_FAR_CLIP_VALUE, UNITY_MATRIX_I_VP);
    float3 rayDirW = farPos - _WorldSpaceCameraPos;

    float3 ro = mul(dd.worldToBox, float4(_WorldSpaceCameraPos, 1.0)).xyz;
    float3 rd = mul((float3x3)dd.worldToBox, rayDirW);

    // 视线几乎平行于贴花平面:交点跑到无穷远,判为不命中
    if (abs(rd.z) < 1e-5) return float3(1e6, 1e6, 1e6);

    float t = -ro.z / rd.z;
    if (t <= 0.0) return float3(1e6, 1e6, 1e6);   // 平面在相机后方

    return ro + rd * t;
}

BurnDecalVaryings BurnDecalVert(BurnDecalAttributes input)
{
    BurnDecalVaryings o;
    o.instanceID = input.id / 6u;

    // 6 个顶点 = 2 个三角拼成的矩形
    //   vid: 0      1      2    |  3      4      5
    //   uv : (0,0)  (1,0)  (0,1)|  (1,0)  (1,1)  (0,1)
    // 用比较而不是查表:部分编译器对 static const 数组的动态索引支持不一致
    uint vid = input.id % 6u;
    float2 uv = float2(
        (vid == 1u || vid == 3u || vid == 4u) ? 1.0 : 0.0,
        (vid == 2u || vid == 4u || vid == 5u) ? 1.0 : 0.0);

    // 把 uv 映射到包围盒 [min, max] 内
    float4 b = BurnDecalClipBounds(o.instanceID);
    o.positionHCS = float4(lerp(b.xy, b.zw, uv), 0.0, 1.0);
    o.uv = uv;
    return o;
}

// ---------------- 碳化评估(核心逻辑,两 Pass 共用) ----------------
// uvRaw: 盒内平面 uv(0..1);uvTex: 经 _BurnTex ST 变换后的采样 uv;age: 归一化年龄
void BurnDecalEval(float2 uvRaw, float2 uvTex, float age,
                   out float charAlpha, out float coreMask, out float emberRing)
{
    float t = _Time.y;

    // 1) 痕迹噪声:决定边缘的粗糙不规则形状
    float n = bdFbm(uvRaw * _NoiseScale);
    float rough = (n - 0.5) * 2.0 * _EdgeRoughness * 0.4;

    // 2) 碳化半径随时间扩散:命中后前 20% 生长期内从 55% 涨满
    float grow = lerp(0.55, 1.0, saturate(age * 5.0));
    float charEdge = saturate(_CharRadius * grow + rough);

    // 3) 径向距离
    float2 p = (uvRaw - 0.5) * 2.0;
    float d = length(p);

    // 4) 碳化遮罩:软边缘过渡
    charAlpha = 1.0 - smoothstep(charEdge - _CharSoftness, charEdge + _CharSoftness, d);

    // 5) 核心加深:越靠中心越黑
    coreMask = 1.0 - smoothstep(0.0, charEdge * 0.55, d);

    // 6) 余烬环:贴着碳化边缘的炽热带,随 Age 冷却熄灭 + 噪声闪烁
    float emberFade = 1.0 - saturate(age / 0.6);
    float band = smoothstep(charEdge + _EmberWidth, charEdge, d)
               * smoothstep(charEdge - _EmberWidth, charEdge, d);
    float flicker = 0.75 + 0.25 * sin(t * 9.0 + n * 40.0);
    emberRing = band * emberFade * flicker;

    // 7) 融合外部贴图(白色默认=纯程序化;生成贴图后增强细节)
    //    R=碳化强度 G=噪声(余烬调制) A=整体遮罩
    half4 burn = SAMPLE_TEXTURE2D(_BurnTex, sampler_BurnTex, uvTex);
    charAlpha *= burn.a * lerp(1.0, burn.r, 0.7);
    emberRing *= lerp(0.4, 1.0, burn.g);

    // 8) 生命末期整体消退(0.85 -> 1.0 彻底消失)
    charAlpha *= 1.0 - smoothstep(0.85, 1.0, age);
}

#endif // BURN_DECAL_COMMON_INCLUDED
