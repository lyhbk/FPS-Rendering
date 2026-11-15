using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 贴花"不可见"问题的诊断日志工具(仅开发/排查期使用)。
///
/// 统一输出格式:
///     [贴花诊断] 问题编号(原因编号) + 问题描述 + 需要排查的数据
///
/// 编号对照:
///     P1(R1) 贴花实例未成功注册进 GPU 缓冲(组件/tag/layer 过滤或查找失败)
///     P2(R2) 命中物体材质不写深度(Transparent), shader 采样不到表面
///     P3(R3) 碰撞体表面与渲染网格表面有偏移 / 法线取自碰撞体而非网格
///     P4(R4) 贴花继承父级非均匀缩放, worldToBox 矩阵退化
///     P5(R5) 射线层过滤未命中, 或贴花被容量上限驱逐
/// </summary>
public static class DecalDiag
{
    /// <summary>总开关;排查完毕或打包前设为 false 可一键静音所有诊断日志</summary>
    public static bool Enabled = false;

    /// <summary>节流间隔(秒);仅用于每帧调用的 LogThrottled,避免刷屏</summary>
    public static float DefaultThrottle = 1.0f;

    private static readonly Dictionary<string, float> s_lastLogTime = new Dictionary<string, float>();

    /// <summary>打印诊断日志(不节流,适用于命中/生成等事件驱动场景)</summary>
    public static void Log(string problemId, string causeId, string description, string dataToCheck)
    {
        if (!Enabled) return;
        Debug.Log($"[贴花诊断] {problemId}({causeId}) + {description} + {dataToCheck}");
    }

    /// <summary>打印诊断警告(疑似有问题,比 Log 更醒目)</summary>
    public static void LogWarning(string problemId, string causeId, string description, string dataToCheck)
    {
        if (!Enabled) return;
        Debug.LogWarning($"[贴花诊断] {problemId}({causeId}) + {description} + {dataToCheck}");
    }

    /// <summary>打印诊断错误(确定存在致命问题)</summary>
    public static void LogError(string problemId, string causeId, string description, string dataToCheck)
    {
        if (!Enabled) return;
        Debug.LogError($"[贴花诊断] {problemId}({causeId}) + {description} + {dataToCheck}");
    }

    /// <summary>
    /// 按编号节流打印:同一 problemId+causeId 在 interval 秒内只打印一次。
    /// 用于 Execute 这类每帧调用的入口。
    /// </summary>
    public static void LogThrottled(string problemId, string causeId, string description,
                                    string dataToCheck, float interval)
    {
        if (!Enabled) return;
        string key = problemId + causeId;
        float now = Time.realtimeSinceStartup;
        if (s_lastLogTime.TryGetValue(key, out float last) && now - last < interval)
            return;
        s_lastLogTime[key] = now;
        Log(problemId, causeId, description, dataToCheck);
    }

    /// <summary>
    /// 命中点诊断:一次性 dump 排查贴花不可见所需的几何 / 材质 / 层级数据。
    /// 覆盖 R2(深度写入)与 R3(碰撞体 vs 网格偏差 / 法线)。
    /// </summary>
    public static void LogHit(RaycastHit hit, LayerMask fireMask)
    {
        if (!Enabled) return;

        var col = hit.collider;
        var colT = col.transform;
        var colGo = colT.gameObject;

        // ---------- P5(R5):命中的层 ----------
        Debug.Log($"[贴花诊断] P5(R5) + 射线命中层检查:确认命中的是预期层(模型碰撞体常因挂在空子物体上导致层/tag 与预期不符) + " +
                  $"collider={colT.name}, layer={colGo.layer}(\"{LayerMask.LayerToName(colGo.layer)}\"), tag=\"{colT.tag}\", " +
                  $"fireMask.value={fireMask.value}");

        // ---------- P3(R3):碰撞体几何 ----------
        Debug.Log($"[贴花诊断] P3(R3) + 碰撞体表面数据:核对 hit.point/hit.normal 是否等于渲染网格表面 + " +
                  $"colliderType={col.GetType().Name}, colBounds.center={col.bounds.center:F3}, colBounds.size={col.bounds.size:F3}, " +
                  $"hit.point={hit.point:F3}, hit.normal={hit.normal:F3}, hit.distance={hit.distance:F3}");

        // ---------- P3(R3) + P2(R2):枚举整个根节点下所有 Renderer ----------
        // 关键:不能用 GetComponentInParent —— 它只向上找父级,找不到「子物体上的网格」。
        // 碰撞体常挂在空子物体上,可见网格往往在兄弟节点或子节点,必须全树扫描。
        var root = colT.root;
        var allRends = root.GetComponentsInChildren<Renderer>(true);

        Debug.Log($"[贴花诊断] P3(R3) + 根节点下 Renderer 枚举:检查可见网格分布 + " +
                  $"root={root.name}, rendererCount={allRends.Length}");

        if (allRends.Length == 0)
        {
            Debug.LogError($"[贴花诊断] P2(R2) + 根节点下完全没有 Renderer:深度纹理里没有该表面,贴花必然不可见 + " +
                           $"root={root.name}, 请确认碰撞体挂在了没有网格的空物体上");
            return;
        }

        // 逐个 Renderer 检查:是否启用 / 包围盒是否退化 / 是否包住命中点 / 材质是否写深度
        Renderer validRend = null;
        for (int i = 0; i < allRends.Length; i++)
        {
            var r = allRends[i];
            var b = r.bounds;
            bool degenerate = b.size.sqrMagnitude < 1e-12f;
            bool covers = b.SqrDistance(hit.point) < 1e-8f;   // 命中点是否落在该网格包围盒内

            string path = GetPath(r.transform);
            Debug.Log($"[贴花诊断] P3(R3) + Renderer[{i}]:核对每个网格的包围盒与启用状态 + " +
                      $"path={path}, type={r.GetType().Name}, enabled={r.enabled}, " +
                      $"gameObjectActive={r.gameObject.activeInHierarchy}, bounds.size={b.size:F3}, " +
                      $"boundsDegenerate={degenerate}, coversHitPoint={covers}");

            if (degenerate)
                Debug.LogWarning($"[贴花诊断] P2(R2) + Renderer[{i}] 包围盒退化为 0:该 Renderer 不渲染任何像素,不会写入深度 + " +
                                 $"path={path}, 若这是唯一网格,贴花必然不可见(检查 Mesh 是否丢失 / SkinnedMesh 骨骼未绑定)");

            if (covers && r.enabled && r.gameObject.activeInHierarchy)
                validRend = r;

            // ---- P2(R2):材质是否写深度 ----
            foreach (var m in r.sharedMaterials)
            {
                if (m == null) continue;
                int rq = m.renderQueue;
                bool isOpaque = rq < 2450;                       // URP: <2450 Opaque, >=2450 Transparent
                string surf = m.HasProperty("_Surface") ? $"_Surface={m.GetFloat("_Surface")}(0=Opaque 1=Transparent)" : "_Surface=无";
                string zw = m.HasProperty("_ZWrite") ? $"ZWrite={m.GetFloat("_ZWrite")}" : "ZWrite=无此属性";
                Debug.Log($"[贴花诊断] P2(R2) + 材质深度写入检查:Transparent 材质不进 _CameraDepthTexture,shader 采样不到表面 + " +
                          $"path={path}, mat={m.name}, renderQueue={rq}, isOpaque={isOpaque}, {zw}, {surf}");
                if (!isOpaque)
                    Debug.LogError($"[贴花诊断] P2(R2) + 材质为 Transparent:贴花必然不可见 + " +
                                   $"mat={m.name} (Queue={rq}), 请改 Surface Type=Opaque 并开 ZWrite");
            }
        }

        // ---------- 结论 ----------
        if (validRend != null)
        {
            Debug.Log($"[贴花诊断] P3(R3) + 结论:命中点处存在可见且会写入深度的网格 + " +
                      $"renderer={GetPath(validRend.transform)}, 若贴花仍不可见,请查 RenderFeature 注入点/深度纹理开关");
        }
        else
        {
            Debug.LogError($"[贴花诊断] P2(R2) + 结论:命中点处【没有任何可见网格】(全部被禁用/包围盒退化/不覆盖命中点) → " +
                           $"SampleSceneDepth 采到的是背景深度,重建出的世界坐标远离贴花盒子 → boxMask=0 → clip 全裁 + " +
                           $"hit.point={hit.point:F3}, 请检查碰撞体是否与可见网格对齐");
        }
    }

    /// <summary>取 transform 的完整层级路径,便于在 Hierarchy 里定位</summary>
    private static string GetPath(Transform t)
    {
        string p = t.name;
        while (t.parent != null)
        {
            t = t.parent;
            p = t.name + "/" + p;
        }
        return p;
    }
}
