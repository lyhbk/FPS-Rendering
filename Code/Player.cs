using UnityEngine;

/// <summary>
/// 玩家中间层,作为 PlayerControl 与 UI 之间的解耦中介。
///
/// 职责:
/// 1. 作为单例,PlayerControl 与 UI 都可以方便地拿到它;
/// 2. 持有 PlayerQuestUI 接口,所有 UI 调用都通过中间层转发;
/// 3. 维护与玩家相关的共享状态/方法(摄像机旋转、角色朝向等),
///    供 PlayerControl 写入,供其他系统读取。
///
/// UI 暂时不调用 PlayerControl,所有 UI 触发都只调用 Player 中间层。
/// </summary>
public class Player : MonoBehaviour
{

    public const float DEFAULT_MOUSE_SENSITIVITY = 2f;

    public const float DEFAULT_MAX_VERTICAL_ANGLE = 80f;

    public const float DEFAULT_MOVE_SPEED = 5f;

    public const float DEFAULT_JUMP_HEIGHT = 1.5f;

    public const float GRAVITY = -9.81f;

    public static readonly Vector3 CAMERA_HEAD_OFFSET = new Vector3(0f, 1.7f, 0f);

    public static Player Instance { get; private set; }


    public PlayerQuestUI QuestUI { get; private set; }

    public float RotationY { get; set; }

    public float RotationX { get; set; }

    public float MaxVerticalAngle { get; private set; } = DEFAULT_MAX_VERTICAL_ANGLE;

    public float MouseSensitivity { get; private set; } = DEFAULT_MOUSE_SENSITIVITY;

    public float MoveSpeed { get; private set; } = DEFAULT_MOVE_SPEED;

    public bool IsGrounded { get; set; }

    public Vector3 Position
    {
        get { return transform.position; }
    }

    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    private void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    public void RegisterQuestUI(PlayerQuestUI ui)
    {
        if (ui == null)
        {
            Debug.LogWarning("[Player] 注册的 PlayerQuestUI 为 null,已忽略。");
            return;
        }
        QuestUI = ui;
    }

    /// <summary>
    /// 取消注册。
    /// </summary>
    public void UnregisterQuestUI(PlayerQuestUI ui)
    {
        if (QuestUI == ui)
        {
            QuestUI = null;
        }
    }

    public void NotifyShowHint(string message, float duration = 2f)
    {
        if (QuestUI == null) return;
        QuestUI.ShowHint(message, duration);
    }

    public void NotifyHideHint()
    {
        if (QuestUI == null) return;
        QuestUI.HideHint();
    }

    public void NotifyUpdateHealth(int current, int max)
    {
        if (QuestUI == null) return;
        QuestUI.UpdateHealth(current, max);
    }
}