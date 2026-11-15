using System;
using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;


public static class CyberpunkGrade
{
    private const string ProfilePath = "Assets/URP/Bloom.asset";

    // ============================================================
    //  应用
    // ============================================================
    [MenuItem("Tools/赛博朋克调色/应用第一档(后处理全套)")]
    public static void ApplyTier1()
    {
        VolumeProfile profile = GetTargetProfile();
        if (profile == null) return;

        // 先清一次脏数据(迁移残留),否则 Add 的判重会被占位条目干扰
        SanitizeProfile(profile);

        // Global Volume 的 weight 决定所有效果的强度。0.7 意味着上面所有数值
        // 都只按 70% 生效 —— 这是"调了半天看不出变化"的常见元凶,这里一并拉满。
        SetVolumeWeight(1f);

        // ---------- T1 Tonemapping:ACES ----------
        Tonemapping tm = Ensure<Tonemapping>(profile);
        tm.active = true;
        tm.mode.overrideState = true;
        tm.mode.value = TonemappingMode.ACES;

        // ---------- T2~T6 Bloom ----------
        Bloom bloom = Ensure<Bloom>(profile);
        bloom.active = true;
        bloom.threshold.overrideState = true;
        bloom.threshold.value = 0.85f;              // 原 1.0 → 让更多霓虹发光
        bloom.intensity.overrideState = true;
        bloom.intensity.value = 1.2f;               // 原 0.6
        bloom.scatter.overrideState = true;
        bloom.scatter.value = 0.78f;                // 原 0.68,光晕散得更开
        bloom.tint.overrideState = true;
        bloom.tint.value = Color.white;             // 原粉色 → 白,让霓虹各发各的色
        bloom.highQualityFiltering.overrideState = true;
        bloom.highQualityFiltering.value = true;    // 光晕更柔更"湿"

        // ---------- T7 ColorAdjustments ----------
        ColorAdjustments color = Ensure<ColorAdjustments>(profile);
        color.active = true;
        color.postExposure.overrideState = true;
        color.postExposure.value = 0.15f;           // 轻微提亮(EV)
        color.contrast.overrideState = true;
        color.contrast.value = 10f;
        color.saturation.overrideState = true;
        color.saturation.value = 30f;               // 夜景配色更浓

        // ---------- T8 Shadows/Midtones/Highlights ----------
        ApplyShadowsMidtonesHighlights(profile);

        // ---------- T9 ChromaticAberration ----------
        ChromaticAberration chroma = Ensure<ChromaticAberration>(profile);
        chroma.active = true;
        chroma.intensity.overrideState = true;
        chroma.intensity.value = 0.12f;             // 边缘紫/青色边

        // ---------- T10 Vignette ----------
        Vignette vignette = Ensure<Vignette>(profile);
        vignette.active = true;
        vignette.intensity.overrideState = true;
        vignette.intensity.value = 0.35f;           // 原来未 override(≈0.05,看不见)
        vignette.smoothness.overrideState = true;
        vignette.smoothness.value = 0.5f;
        vignette.color.overrideState = true;
        vignette.color.value = new Color(0.05f, 0.02f, 0.08f, 1f);  // 偏紫的暗角

        // ---------- T11 FilmGrain ----------
        FilmGrain grain = Ensure<FilmGrain>(profile);
        grain.active = true;
        grain.intensity.overrideState = true;
        grain.intensity.value = 0.06f;
        grain.response.overrideState = true;
        grain.response.value = 0.8f;

        EditorUtility.SetDirty(profile);
        AssetDatabase.SaveAssets();

        Debug.Log("[赛博朋克调色] 第一档已应用:\n" +
                  "  T1 Tonemapping = ACES\n" +
                  "  T2 Bloom tint = 白(原粉)\n" +
                  "  T3 threshold 1.0 → 0.85\n" +
                  "  T4 intensity 0.6 → 1.2\n" +
                  "  T5 高质量过滤 = 开\n" +
                  "  T6 scatter 0.68 → 0.78\n" +
                  "  T7 饱和度 +30 / 对比度 +10\n" +
                  "  T8 阴影染蓝 / 高光染青\n" +
                  "  T9 色差 0.12\n" +
                  "  T10 暗角 0.35\n" +
                  "  T11 颗粒 0.06\n" +
                  "想回退:Tools → 赛博朋克调色 → 还原(关闭第一档)");
    }

    // ============================================================
    //  还原:把上面加的组件全部停用(不删除,方便对比)
    // ============================================================
    [MenuItem("Tools/赛博朋克调色/还原(关闭第一档)")]
    public static void RevertTier1()
    {
        VolumeProfile profile = GetTargetProfile();
        if (profile == null) return;

        SetVolumeWeight(0.7f);   // 还原成改之前的权重

        int n = 0;
        foreach (VolumeComponent c in profile.components)
        {
            if (c is Tonemapping || c is ColorAdjustments ||
                c is ChromaticAberration || c is FilmGrain ||
                c.GetType().Name == "ShadowsMidtonesHighlights")
            {
                c.active = false;
                n++;
            }
        }

        // Vignette / Bloom 本来就在用,还原成原来的弱值而不是关掉
        Vignette vignette = Find<Vignette>(profile);
        if (vignette != null)
        {
            vignette.intensity.overrideState = false;
            vignette.color.overrideState = false;
            vignette.smoothness.overrideState = false;
        }

        Bloom bloom = Find<Bloom>(profile);
        if (bloom != null)
        {
            bloom.threshold.value = 1f;
            bloom.intensity.value = 0.6f;
            bloom.scatter.value = 0.68f;
            bloom.tint.value = new Color(1f, 0.61320746f, 0.9283949f, 1f);
            bloom.highQualityFiltering.value = false;
        }

        EditorUtility.SetDirty(profile);
        AssetDatabase.SaveAssets();
        Debug.Log($"[赛博朋克调色] 已还原(停用 {n} 个组件,Bloom/Vignette 回到原值)");
    }

    // ============================================================
    //  内部工具
    // ============================================================

    /// <summary>
    /// 找到真正生效的那个 Volume Profile。
    /// 优先取【当前打开场景里 Global Volume 实际引用】的,拿不到再退回已知路径 ——
    /// 这样不用依赖 GUID 匹配(本工程做过引擎迁移,GUID 格式不统一,按 GUID 找不可靠)。
    /// </summary>
    private static VolumeProfile GetTargetProfile()
    {
        foreach (Volume v in UnityEngine.Object.FindObjectsOfType<Volume>())
        {
            if (v != null && v.sharedProfile != null)
            {
                Debug.Log($"[赛博朋克调色] 目标 Profile = {AssetDatabase.GetAssetPath(v.sharedProfile)} " +
                          $"(来自场景物体 \"{v.name}\")");
                return v.sharedProfile;
            }
        }

        VolumeProfile fallback = AssetDatabase.LoadAssetAtPath<VolumeProfile>(ProfilePath);
        if (fallback != null)
        {
            Debug.Log($"[赛博朋克调色] 场景里没找到 Volume,改用指定路径:{ProfilePath}");
            return fallback;
        }

        Debug.LogError("[赛博朋克调色] 找不到任何 Volume Profile。\n" +
                       "请先打开 Main.unity 场景,或把脚本顶部的 ProfilePath 改成正确的路径。");
        return null;
    }

    /// <summary>设置场景里所有 Volume 的权重,并标记场景为已修改(可 Ctrl+Z 撤销)</summary>
    private static void SetVolumeWeight(float weight)
    {
        foreach (Volume v in UnityEngine.Object.FindObjectsOfType<Volume>())
        {
            if (v == null) continue;
            if (Mathf.Approximately(v.weight, weight)) continue;

            Undo.RecordObject(v, "赛博朋克调色:调整 Volume 权重");
            v.weight = weight;
            EditorUtility.SetDirty(v);
        }
        EditorSceneManager.MarkSceneDirty(UnityEngine.SceneManagement.SceneManager.GetActiveScene());
    }

    /// <summary>取已有组件,没有就用 Unity API 添加(自动写进 .asset)</summary>
    private static T Ensure<T>(VolumeProfile profile) where T : VolumeComponent
    {
        T existing = Find<T>(profile);
        if (existing != null) return existing;

        try
        {
            return profile.Add<T>(true);
        }
        catch (InvalidOperationException)
        {
            // 走到这里:脚本判定"没有"(c is T 全为 false),但 Add 内部 Has(type) 判定"已存在"。
            // 典型原因:引擎迁移后组件脚本引用失效,条目被反序列化降级成基类占位,
            // 既匹配不了 T、又把 Add 的判重挡住 → "Component already exists in the volume"。
            // 处理:移除占位条目后重试一次。
            if (RemovePlaceholders(profile, typeof(T)) > 0)
                return profile.Add<T>(true);

            // 还不行:打印全部组件类型,便于人工定位
            var names = new System.Text.StringBuilder();
            foreach (VolumeComponent c in profile.components)
                names.AppendLine("  - " + (c == null ? "<空引用>" : c.GetType().FullName));
            throw new InvalidOperationException(
                "[赛博朋克调色] 无法添加 " + typeof(T).Name + ":Profile 组件列表疑似脏数据。\n当前组件:\n" + names);
        }
    }

    /// <summary>
    /// 清理 Profile 脏数据(引擎迁移残留):
    ///   - 空引用条目(脚本丢失后反序列化为 null / 已销毁对象)
    ///   - 重复类型条目(VolumeProfile 要求每种组件唯一)
    /// 这些条目会让 Add 内部的 Has(type) 判重与脚本侧查找结果不一致。
    /// </summary>
    private static void SanitizeProfile(VolumeProfile profile)
    {
        var seen = new HashSet<Type>();
        int removed = profile.components.RemoveAll(c => c == null || !seen.Add(c.GetType()));

        if (removed > 0)
        {
            EditorUtility.SetDirty(profile);
            AssetDatabase.SaveAssets();
            Debug.LogWarning("[赛博朋克调色] 清理了 " + removed + " 个空/重复的后处理组件(迁移残留)");
        }
    }

    /// <summary>
    /// 移除指定类型的"占位"条目:
    ///   c 的声明类型是 targetType 的【基类】(如降级成 VolumeComponent)但实例不是 targetType ——
    ///   这种条目就是挡住 Add 判重的元凶;顺带移除空引用。
    /// </summary>
    private static int RemovePlaceholders(VolumeProfile profile, Type targetType)
    {
        int removed = 0;
        for (int i = profile.components.Count - 1; i >= 0; i--)
        {
            VolumeComponent c = profile.components[i];
            bool placeholder = c == null
                            || (targetType.IsAssignableFrom(c.GetType()) && !targetType.IsInstanceOfType(c));
            if (placeholder)
            {
                Debug.LogWarning("[赛博朋克调色] 移除 " + targetType.Name + " 的占位/无效条目(索引 " + i + ")");
                profile.components.RemoveAt(i);
                removed++;
            }
        }
        if (removed > 0)
        {
            EditorUtility.SetDirty(profile);
            AssetDatabase.SaveAssets();
        }
        return removed;
    }

    private static T Find<T>(VolumeProfile profile) where T : VolumeComponent
    {
        foreach (VolumeComponent c in profile.components)
        {
            if (c is T typed) return typed;
        }
        return null;
    }

    /// <summary>
    /// Shadows/Midtones/Highlights 在部分 URP 版本里可能没有,
    /// 所以用反射按名字查找:找不到就跳过,不会导致编译错误。
    /// </summary>
    private static void ApplyShadowsMidtonesHighlights(VolumeProfile profile)
    {
        Type type = Type.GetType(
            "UnityEngine.Rendering.Universal.ShadowsMidtonesHighlights, Unity.RenderPipelines.Universal.Runtime");

        if (type == null)
        {
            Debug.LogWarning("[赛博朋克调色] 本版 URP 没有 ShadowsMidtonesHighlights,跳过 T8。" +
                             "可手动在 Volume 里加 ColorCurves 或 LiftGammaGain 代替。");
            return;
        }

        VolumeComponent comp = null;
        foreach (VolumeComponent c in profile.components)
        {
            if (c != null && c.GetType() == type) { comp = c; break; }
        }
        if (comp == null)
        {
            try
            {
                comp = profile.Add(type, true);
            }
            catch (InvalidOperationException)
            {
                // 与 Ensure 同样的脏数据兜底
                if (RemovePlaceholders(profile, type) > 0)
                    comp = profile.Add(type, true);
            }
        }
        if (comp == null)
        {
            Debug.LogWarning("[赛博朋克调色] ShadowsMidtonesHighlights 添加失败,跳过 T8。");
            return;
        }

        comp.active = true;
        // 值 = 颜色乘数(RGB),A 位不用
        SetVector4(comp, "shadows",    new Vector4(0.70f, 0.85f, 1.30f, 0f));  // 阴影偏蓝紫
        SetVector4(comp, "midtones",   new Vector4(1.00f, 0.97f, 1.05f, 0f));  // 中间调几乎中性
        SetVector4(comp, "highlights", new Vector4(0.80f, 1.10f, 1.20f, 0f));  // 高光偏青
    }

    /// <summary>反射设置 VolumeParameter&lt;Vector4&gt; 的值并打开 override</summary>
    private static void SetVector4(VolumeComponent comp, string fieldName, Vector4 value)
    {
        System.Reflection.FieldInfo field = comp.GetType().GetField(fieldName);
        if (field == null) return;

        object param = field.GetValue(comp);
        if (param == null) return;

        System.Reflection.FieldInfo valueField = param.GetType().GetField("value");
        if (valueField != null) valueField.SetValue(param, value);

        // overrideState 在不同版本里可能是属性也可能是字段,两种都试
        System.Reflection.PropertyInfo prop = param.GetType().GetProperty("overrideState");
        if (prop != null)
        {
            prop.SetValue(param, true);
        }
        else
        {
            System.Reflection.FieldInfo field2 = param.GetType().GetField("overrideState");
            if (field2 != null) field2.SetValue(param, true);
        }
    }
}
