using UnityEngine;

/// <summary>
/// UI 层需要实现的契约。
/// 任何想要响应玩家状态变化的 UI 组件都可以实现该接口,
/// 然后通过 Player 中间层注册自己,UI 暂时不主动调用 PlayerControl。
/// </summary>
public interface PlayerQuestUI
{
    /// <summary>
    /// 注册时由 Player 中间层调用,可用于初始化。
    /// </summary>

    /// <summary>
    /// 显示一段提示文本(任务提示、交互提示等)。
    /// </summary>
    /// <param name="message">要显示的提示内容</param>
    /// <param name="duration">显示时长(秒),<=0 表示不自动隐藏</param>
    void ShowHint(string message, float duration = 2f);

    /// <summary>
    /// 隐藏当前提示文本。
    /// </summary>
    void HideHint();

    /// <summary>
    /// 更新血量显示。
    /// </summary>
    /// <param name="current">当前血量</param>
    /// <param name="max">最大血量</param>
    void UpdateHealth(int current, int max);
}