using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

/// <summary>
/// L1:为霓虹物体自动生成【烘焙点光】,让路灯/霓虹牌下方出现光池。
///
/// 【菜单】
///   Tools → 赛博朋克光照 → ① 检查烘焙前置条件    ← 先跑这个
///   Tools → 赛博朋克光照 → ② 为霓虹生成烘焙点光  ← 再跑这个
///   Tools → 赛博朋克光照 → ③ 删除生成的点光      ← 想重来时用
///
/// 【原理】
///   自发光(Emission)只会让自己变亮,【不会照亮周围】—— 所以霓虹牌下面永远是黑的。
///   要让它照亮地面/墙面,必须在同位置放一盏真实的灯,并烘焙进光照贴图。
///   本脚本扫描场景里的自发光材质,读出颜色和亮度,按大小和亮度生成对应的点光。
///
/// 【烘焙 vs 实时】
///   这里生成的是 Baked(烘焙)模式:零运行时开销,效果最好,但【必须烘焙后才可见】,
///   且物体不能移动。想要实时效果就把 lightmapBakeType 改 Realtime(数量多会很贵)。
/// </summary>
public static class NeonBakeLights
{
    // ===================== 可调参数 =====================
    private const string RootName = "NeonBakeLights";

    private const float LightIntensityScale = 1.6f;   // 亮度 → 光强
    private const float MinIntensity = 0.8f;
    private const float MaxIntensity = 18f;

    private const float RangeScale = 4.5f;            // 物体尺寸 → 照射半径
    private const float MinRange = 2f;
    private const float MaxRange = 16f;

    private const float MaxObjectSize = 8f;           // 超过这个尺寸的物体不当霓虹(排除地面/大楼)

    // 自发光颜色属性名:按优先级尝试,命中的第一个有效
    private static readonly string[] EmissionProps =
    {
        "_EmissionColor",        // DecoEmissive / Fire
        "_EdgeEmissionColor",    // Cyber / Test
        "_GridColor",            // Plane(霓虹网格)
        "_BaseColor",
        "_Color"
    };

    // ===================== ① 前置检查 =====================
    [MenuItem("Tools/赛博朋克光照/① 检查烘焙前置条件")]
    public static void CheckPrerequisites()
    {
        Scene scene = SceneManager.GetActiveScene();
        if (!scene.IsValid())
        {
            Debug.LogError("[霓虹点光] 请先打开 Main.unity 场景。");
            return;
        }

        int total = 0, contributeGI = 0;
        foreach (MeshRenderer mr in Object.FindObjectsOfType<MeshRenderer>())
        {
            total++;
            StaticEditorFlags flags = GameObjectUtility.GetStaticEditorFlags(mr.gameObject);
            if ((flags & StaticEditorFlags.ContributeGI) != 0) contributeGI++;
        }

        LightProbeGroup[] probes = Object.FindObjectsOfType<LightProbeGroup>();
        Light[] bakedLights = GetGeneratedLights();

        string report =
            "===== 烘焙前置检查 =====\n" +
            $"场景:{scene.name}\n" +
            $"MeshRenderer 总数:{total}\n" +
            $"已勾 Contribute GI(会被烘焙光照影响):{contributeGI}\n" +
            $"Light Probe Group(动态物体用):{probes.Length}\n" +
            $"已生成的霓虹点光:{bakedLights.Length}\n";

        if (contributeGI == 0)
        {
            report += "\n[严重] 没有任何物体勾 Contribute GI → 烘焙后地面依然全黑。\n" +
                      "       解决:选中地面/建筑 → Inspector 右上角 Static 下拉 → 勾 Contribute GI。";
        }
        else if (contributeGI < total / 2)
        {
            report += $"\n[提示] 只有 {contributeGI}/{total} 个物体参与烘焙,确认地面和建筑都勾上了。";
        }
        else
        {
            report += "\n[OK] 接收烘焙光的物体数量正常。";
        }

        if (probes.Length == 0)
        {
            report += "\n[提示] 没有 Light Probe Group → 玩家/枪这类动态物体不受烘焙光影响(会显得和场景脱节)。\n" +
                      "       解决:GameObject → Light → Light Probe Group,铺在场景里。";
        }

        if (bakedLights.Length == 0)
        {
            report += "\n[下一步] 还没有点光,先跑菜单 ②。";
        }
        else
        {
            report += "\n[下一步] 点光已就绪,去 Window → Rendering → Lighting → Generate Lighting 烘焙。";
        }

        Debug.Log(report);
    }

    // ===================== ② 生成点光 =====================
    [MenuItem("Tools/赛博朋克光照/② 为霓虹生成烘焙点光")]
    public static void Generate()
    {
        Scene scene = SceneManager.GetActiveScene();
        if (!scene.IsValid())
        {
            Debug.LogError("[霓虹点光] 请先打开 Main.unity 场景。");
            return;
        }

        // 清掉上一批,避免重复叠加
        Clear();

        GameObject root = new GameObject(RootName);
        Undo.RegisterCreatedObjectUndo(root, "生成霓虹点光");

        int created = 0, skipped = 0;
        List<string> missing = new List<string>();

        foreach (MeshRenderer mr in Object.FindObjectsOfType<MeshRenderer>())
        {
            if (mr == null || !mr.gameObject.activeInHierarchy) continue;
            if (mr.transform.IsChildOf(root.transform)) continue;

            // 尺寸过滤:排除地面、大楼这类大件
            Vector3 size = mr.bounds.size;
            if (Mathf.Max(size.x, size.y, size.z) > MaxObjectSize)
            {
                skipped++;
                continue;
            }

            // 读自发光颜色:所有材质里取最亮的那个
            Color emission = Color.black;
            float brightness = 0f;
            bool found = false;

            foreach (Material mat in mr.sharedMaterials)
            {
                if (mat == null) continue;
                foreach (string prop in EmissionProps)
                {
                    if (!mat.HasProperty(prop)) continue;
                    Color c = mat.GetColor(prop);
                    float b = Mathf.Max(c.r, c.g, c.b);
                    if (b > brightness)
                    {
                        brightness = b;
                        emission = c;
                        found = true;
                    }
                    break;   // 一个材质取到就用它
                }
            }

            if (!found || brightness < 0.05f)
            {
                missing.Add(mr.name);
                continue;
            }

            // 颜色归一化:保留色相,去掉 HDR 的超高亮度(那部分交给 intensity)
            float peak = Mathf.Max(emission.r, emission.g, emission.b, 1f);
            Color lightColor = new Color(emission.r / peak, emission.g / peak, emission.b / peak, 1f);

            float intensity = Mathf.Clamp(brightness * LightIntensityScale, MinIntensity, MaxIntensity);
            float range = Mathf.Clamp(Mathf.Max(size.x, size.y, size.z) * RangeScale, MinRange, MaxRange);

            GameObject lightGo = new GameObject("Neon_" + mr.name);
            lightGo.transform.SetParent(root.transform);
            lightGo.transform.position = mr.bounds.center;

            Light light = lightGo.AddComponent<Light>();
            light.type = LightType.Point;
            light.color = lightColor;
            light.intensity = intensity;
            light.range = range;
            light.shadows = LightShadows.None;          // 霓虹不投影:省烘焙时间,避免自遮挡黑斑
            light.lightmapBakeType = LightmapBakeType.Baked;   // ← 关键:烘焙模式

            created++;
        }

        EditorSceneManager.MarkSceneDirty(scene);

        string msg = $"[霓虹点光] 生成完成:新建 {created} 盏烘焙点光(跳过 {skipped} 个超大物体)。\n" +
                     "接下来:\n" +
                     "  1) Window → Rendering → Lighting → Generate Lighting\n" +
                     "  2) 等烘焙结束(右下角进度条)\n" +
                     "  3) 看路灯/霓虹下方有没有出现光池\n" +
                     "想重来:菜单 ③ 删除,再跑 ②。";

        if (missing.Count > 0)
        {
            msg += $"\n\n未识别出自发光颜色的物体 {missing.Count} 个(前 8 个):" +
                   string.Join(", ", missing.GetRange(0, Mathf.Min(8, missing.Count)));
        }

        Debug.Log(msg);
    }

    // ===================== ③ 删除 =====================
    [MenuItem("Tools/赛博朋克光照/③ 删除生成的点光")]
    public static void Clear()
    {
        int n = 0;
        // 可能有多批,循环删干净
        while (true)
        {
            GameObject root = GameObject.Find(RootName);
            if (root == null) break;
            Undo.DestroyObjectImmediate(root);
            n++;
        }

        if (n > 0)
        {
            EditorSceneManager.MarkSceneDirty(SceneManager.GetActiveScene());
            Debug.Log($"[霓虹点光] 已删除 {n} 批生成的点光。");
        }
    }

    // ===================== 工具 =====================
    private static Light[] GetGeneratedLights()
    {
        List<Light> result = new List<Light>();
        GameObject root = GameObject.Find(RootName);
        if (root == null) return result.ToArray();

        result.AddRange(root.GetComponentsInChildren<Light>(true));
        return result.ToArray();
    }
}
