using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEditor;

/// <summary>
/// Bloom 性能参数修复工具。
///
/// 背景:当前 URP 14.2.0-t1 的 Bloom 源码里有 maxIterations(默认 6)与 downscale
/// 两个性能关键参数,但部分编辑器会话的 Inspector 不显示(编译缓存未刷新)。
/// 本工具直接改 VolumeProfile 资产,绕过 UI 限制。
///
/// 用法:菜单 Tools → Bloom 性能参数修复(MaxIterations=3)
/// </summary>
public static class FixBloomParams
{
    [MenuItem("Tools/Bloom 性能参数修复(MaxIterations=3)")]
    public static void Run()
    {
        string[] guids = AssetDatabase.FindAssets("t:VolumeProfile");
        int changed = 0;

        foreach (string guid in guids)
        {
            string path = AssetDatabase.GUIDToAssetPath(guid);
            VolumeProfile profile = AssetDatabase.LoadAssetAtPath<VolumeProfile>(path);
            if (profile == null) continue;
            if (!profile.TryGet<Bloom>(out Bloom bloom)) continue;

            // 层数 6 → 3:降采样金字塔砍半,Bloom 耗时约降一半
            bloom.maxIterations.overrideState = true;
            bloom.maxIterations.value = 3;

            // 限制单像素亮度贡献,防止个别超亮像素撑出巨大光斑(顺手提质)
            bloom.clamp.overrideState = true;
            bloom.clamp.value = 20f;

            EditorUtility.SetDirty(profile);
            changed++;
            Debug.Log($"[FixBloom] {path}: MaxIterations=3, Clamp=20");
        }

        AssetDatabase.SaveAssets();

        if (changed == 0)
            Debug.LogWarning("[FixBloom] 没找到包含 Bloom 的 VolumeProfile。请确认 Global Volume 的 Profile 资产在 Assets 目录下。");
        else
            Debug.Log($"[FixBloom] 完成 —— 已修改 {changed} 个 Profile。若脚本编译报错找不到 maxIterations,请重启 Unity 刷新包编译缓存。");
    }
}
