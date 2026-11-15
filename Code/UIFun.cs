using System.Collections;
using UnityEngine;

/// <summary>
/// UI 层:实现 PlayerQuestUI 接口,
/// 通过 Player 中间层注册自身并响应 PlayerControl 的通知。
/// 当前阶段 UI 不调用 PlayerControl,只接收中间层转发过来的事件。
/// </summary>
public class UIFun : MonoBehaviour, PlayerQuestUI
{
    [SerializeField] private Camera playerCamera;
    [SerializeField] private GameObject player;

    // 当前提示与血量状态(占位实现,后续可替换为真正的 UI 控件)
    private string currentHint;
    private float hintRemain;
    private int currentHealth = 100;
    private int maxHealth = 100;

    private void Start()
    {
        // 把自身注册到 Player 中间层,之后 PlayerControl 就可以通过中间层调用本 UI
        if (Player.Instance != null)
        {
            Player.Instance.RegisterQuestUI(this);
        }
        else
        {
            // Player 还没初始化,延迟一帧再注册
            StartCoroutine(RegisterNextFrame());
        }
    }

    private IEnumerator RegisterNextFrame()
    {
        yield return null;
        if (Player.Instance != null)
        {
            Player.Instance.RegisterQuestUI(this);
        }
    }

    private void OnDestroy()
    {
        if (Player.Instance != null)
        {
            Player.Instance.UnregisterQuestUI(this);
        }
    }

    private void Update()
    {
        // 简单的提示自动隐藏倒计时
        if (hintRemain > 0f)
        {
            hintRemain -= Time.deltaTime;
            if (hintRemain <= 0f)
            {
                currentHint = null;
            }
        }
    }


    public void ShowHint(string message, float duration = 2f)
    {
        currentHint = message;
        hintRemain = duration;
    }

    public void HideHint()
    {
        currentHint = null;
        hintRemain = 0f;
    }

    public void UpdateHealth(int current, int max)
    {
        currentHealth = current;
        maxHealth = Mathf.Max(1, max);
    }
}