using UnityEngine;

/// <summary>
/// Sharp.shader 自发光闪烁的外部开关（全局关键字 _GLOBAL_EMISSION_FLICKER）。
///
/// 为什么需要它：
///   全局关键字不会被材质保存，也不会自己生效 —— 必须在运行时用代码开启。
///   shader 侧声明的是 #pragma multi_compile_fragment _ _GLOBAL_EMISSION_FLICKER，
///   所以开关是【全场统一】的（所有用 Sharp 的材质一起闪/一起不闪）。
///
/// 用法：
///   EmissionFlickerControl.Enabled = true;    // 开启（画低档可关掉省 ALU）
///   EmissionFlickerControl.Enabled = false;
///   或把 EmissionFlickerToggler 挂到任意常驻物体上，在 Inspector 里勾选。
/// </summary>
public static class EmissionFlickerControl
{
    public const string Keyword = "_GLOBAL_EMISSION_FLICKER";

    /// <summary>是否已开启（读取的是 Shader 的全局关键字真实状态）</summary>
    public static bool Enabled
    {
        get => Shader.IsKeywordEnabled(Keyword);
        set
        {
            if (value) Shader.EnableKeyword(Keyword);
            else Shader.DisableKeyword(Keyword);
        }
    }

    // 进入 Play 模式自动开启；不需要时把这里注释掉即可完全交给外部控制
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
    private static void AutoEnableOnPlay()
    {
        Enabled = true;
    }

    /// <summary>诊断用：打印当前状态，确认 shader 是否真的切到了闪烁变体</summary>
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void LogState()
    {
        Debug.Log($"[EmissionFlicker] {Keyword} = {Enabled}（true 才会闪烁）");
    }
}

/// <summary>
/// 挂在任意常驻物体上即可在 Inspector 里开关闪烁；
/// OnValidate 让编辑器（非 Play 模式）也能即时生效，方便调参。
/// </summary>
[DisallowMultipleComponent]
public class EmissionFlickerToggler : MonoBehaviour
{
    [Tooltip("开启 Sharp 材质的自发光闪烁（全局生效）")]
    public bool enableFlicker = true;

    private void OnEnable() => Apply();
    private void OnValidate() => Apply();

    private void Apply()
    {
        if (!Application.isPlaying && !isActiveAndEnabled) return;
        EmissionFlickerControl.Enabled = enableFlicker;
    }
}
