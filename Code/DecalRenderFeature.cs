using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using System.Collections.Generic;

public class DecalRenderFeature : ScriptableRendererFeature
{
    // 单帧最多并存的贴花数
    public const int MaxDecals = 10;

    class DecalPass : ScriptableRenderPass
    {
        // Matrix4x4(64)×2 + Vector4(16)×2
        // boxToWorld 是新增的:顶点阶段要把盒子 8 个角投到裁剪空间算屏幕包围盒,
        // 必须用【局部→世界】矩阵(用 worldToBox 求逆在着色器里又贵又不可靠)。
        private const int DecalDataStride = 160;

        // 与 BurnDecalCommon.hlsl 的 DecalData 结构逐字段对应
        private struct DecalData
        {
            public Matrix4x4 worldToBox;
            public Matrix4x4 boxToWorld;   // 局部 -> 世界
            public Vector4 boxSize;   // xyz = 盒子尺寸
            public Vector4 fadeAge;   // x = 淡化系数, y = 归一化年龄
        }

        private ProfilingSampler _profilingSampler = new ProfilingSampler("CustomDecalPass");
        private Queue<DecalProjector> _decals = new Queue<DecalProjector>();
        private Material _decalMat;
        private DecalData[] _dataArray = new DecalData[MaxDecals];
        private ComputeBuffer _dataBuffer;

        public DecalPass(Material mat)
        {
            _decalMat = mat;
            renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
            ConfigureInput(ScriptableRenderPassInput.Depth);
        }

        public void SetDecals(Queue<DecalProjector> list)
        {
            _decals = list;
        }

        // 降级阈值由外层(Inspector 可配)每帧下发
        private int _emberAbove = 2, _noiseAbove = 2, _noiseMin = 4, _hardCap = 0;
        public void SetDegrade(int emberAbove, int noiseAbove, int noiseMin, int hardCap)
        {
            _emberAbove = emberAbove;
            _noiseAbove = noiseAbove;
            _noiseMin = noiseMin;
            _hardCap = hardCap;
        }

        public void Cleanup()
        {
            _dataBuffer?.Release();
            _dataBuffer = null;
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_decalMat == null || _decals == null || _decals.Count == 0) return;

            // 1) 打包本帧所有可见贴花到 CPU 数组(矩阵/尺寸/淡化/年龄)
            //    降级①:hardCap > 0 且超出时,直接跳过队首(最旧)的若干个,只画最新的
            int skip = (_hardCap > 0 && _decals.Count > _hardCap) ? _decals.Count - _hardCap : 0;

            int count = 0;
            int seen = 0;
            foreach (var decal in _decals)
            {
                if (decal == null || !decal.gameObject.activeSelf) continue;
                if (seen++ < skip) continue;            // 降级:最旧的贴花本帧不参与绘制
                if (count >= MaxDecals) break;

                _dataArray[count].worldToBox = decal.transform.worldToLocalMatrix;
                _dataArray[count].boxToWorld = decal.transform.localToWorldMatrix;
                _dataArray[count].boxSize = decal.size;
                _dataArray[count].fadeAge = new Vector4(decal.Fade01, decal.Age01, 0f, 0f);
                count++;
            }
            if (count == 0) return;

            // ===== 降级②:按数量决定噪声层数 / 是否画余烬 Pass =====
            int octaves = count > _noiseMin ? 1 : (count > _noiseAbove ? 2 : 4);
            bool drawEmber = count <= _emberAbove;
            CurrentOctaves = octaves;
            CurrentDrawEmber = drawEmber;

            // 2) 懒创建实例数据缓冲(容量固定,避免每帧分配 GPU 资源)
            if (_dataBuffer == null)
            {
                _dataBuffer = new ComputeBuffer(MaxDecals, DecalDataStride, ComputeBufferType.Structured);
            }
            _dataBuffer.SetData(_dataArray, 0, 0, count);


            CommandBuffer cmd = CommandBufferPool.Get();
            using (new ProfilingScope(cmd, _profilingSampler))
            {
                cmd.SetGlobalBuffer("_DecalData", _dataBuffer);

                // 降级②下发噪声层数(1 层最省,4 层最高画质)
                cmd.SetGlobalFloat(DecalFbmOctId, octaves);

                // 3) 所有贴花合为一次绘制:6×count 个顶点 = count 个【投影包围盒矩形】。
                //    DrawCall 数与贴花数量无关(始终 1~2 次),
                //    片元工作量 = 各贴花投影面积之和(不再是 count × 全屏)。
                int vertexCount = checked(6 * count);
                cmd.DrawProcedural(Matrix4x4.identity, _decalMat, 0, MeshTopology.Triangles, vertexCount, 1);

                // 降级③:数量超过 emberDegradeAbove 时跳过余烬 Pass(省掉一半全屏开销)
                if (drawEmber)
                    cmd.DrawProcedural(Matrix4x4.identity, _decalMat, 1, MeshTopology.Triangles, vertexCount, 1);
            }

            DecalDiag.LogThrottled("P7", "R7",
                "贴花降级状态:核对数量与生效的画质档位",
                $"packed={count}, skippedOldest={skip}, fbmOctaves={octaves}, drawEmber={drawEmber}", 1.0f);
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
            // 注意:这里绝不能 Cleanup() 释放 _dataBuffer
        }
    }

    [Header("灼烧贴花材质")]
    public Material decalMaterial;

    // ================= 贴花降级(LOD)=================
    // 开销模型:每个贴花一个【全屏三角】,片元着色器跑遍全屏再由 boxMask clip 掉。
    // 所以本 Pass 的成本 = 贴花数 N × 全屏像素数,和贴花在屏幕上实际占多大【无关】。
    // 这意味着 N 是最直接、最线性的开销杠杆 —— 超过阈值时对全体贴花降质即可。
    [Header("降级:活跃贴花数超过阈值时自动降质")]
    [Tooltip("超过该数量 → 跳过 EMBER(余烬)Pass。两个 Pass 各画一遍,砍一个直接省 ~50%")]
    public int emberDegradeAbove = 2;
    [Tooltip("超过该数量 → 程序化噪声 FBM 降到 2 层(省 ALU,边缘噪点略平滑)")]
    public int noiseDegradeAbove = 2;
    [Tooltip("超过该数量 → 噪声 FBM 降到 1 层(最省)")]
    public int noiseMinAbove = 4;
    [Tooltip("硬上限:超过则本帧只画最新的 N 个,最旧的直接不参与绘制(0=不限制)")]
    public int hardCap = 0;

    /// <summary>当前生效的噪声层数,供外部诊断/其他系统查询</summary>
    public static int CurrentOctaves { get; private set; } = 4;
    /// <summary>当前是否绘制余烬 Pass</summary>
    public static bool CurrentDrawEmber { get; private set; } = true;

    private static readonly int DecalFbmOctId = Shader.PropertyToID("_DecalFbmOct");

    private DecalPass _pass;

    // 全局静态:所有激活的贴花队列(FIFO,容量上限 MaxDecals)
    public static Queue<DecalProjector> ActiveDecals { get; private set; } = new Queue<DecalProjector>();

    public override void Create()
    {
        _pass = new DecalPass(decalMaterial);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // 只在游戏视图与场景视图执行。跳过 Reflection / Preview / MainCamera 之外的中间相机,
        // 避免同一帧对同一批贴花重复做全屏绘制(省 GPU,也避免反射相机里出现幽灵贴花)。
        CameraType camType = renderingData.cameraData.cameraType;
        if (camType != CameraType.Game && camType != CameraType.SceneView)
            return;

        _pass.SetDecals(ActiveDecals);
        _pass.SetDegrade(emberDegradeAbove, noiseDegradeAbove, noiseMinAbove, hardCap);
        renderer.EnqueuePass(_pass);
    }

    protected override void Dispose(bool disposing)
    {
        _pass?.Cleanup();
    }

    /// <summary>
    /// 注册贴花。队列已满则先驱逐队首(最旧)、将其归还对象池,再把新贴花加入队尾。
    /// Queue&lt;T&gt; 的 Contains/Dequeue/Enqueue 在小容量(≤8)下开销可忽略。
    /// </summary>
    public static void Register(DecalProjector d)
    {
        if (ActiveDecals.Contains(d)) return;

        if (ActiveDecals.Count >= MaxDecals)
        {
            // 容量已满:驱逐最旧的,顺手归还到它的对象池,避免它成为孤儿
            DecalProjector evicted = ActiveDecals.Dequeue();
            if (evicted != null)
            {
                if (evicted.sourcePrefab != null)
                    GameObjectPool.Release(evicted.sourcePrefab, evicted.gameObject);
                else
                    evicted.gameObject.SetActive(false); // 场景手动摆放:只隐藏不销毁
            }
        }
        ActiveDecals.Enqueue(d);
    }

    /// <summary>
    /// 反注册贴花。Queue&lt;T&gt; 不支持按值移除,容量极小(≤8)时直接重建队列,O(N) 可接受。
    /// </summary>
    public static void UnRegister(DecalProjector d)
    {
        if (ActiveDecals.Count == 0) return;
        if (!ActiveDecals.Contains(d)) return;

        var next = new Queue<DecalProjector>(ActiveDecals.Count);
        foreach (var x in ActiveDecals)
        {
            if (!ReferenceEquals(x, d)) next.Enqueue(x);
        }
        ActiveDecals = next;
    }
}
