using UnityEngine;

[RequireComponent(typeof(CharacterController))]
public class PlayerControl : MonoBehaviour
{
    // ---------------- 常量(集中放在类开头) ----------------
    // 鼠标水平/垂直灵敏度
    public const float MOUSE_SENSITIVITY = 2f;
    // 上下视角最大角度(度),左右旋转无此限制
    public const float MAX_VERTICAL_ANGLE = 30f;
    // 行走速度(米/秒)
    public const float MOVE_SPEED = 20f;
    // 重力加速度(米/秒^2)
    public const float GRAVITY = -9.81f;
    // 跳跃高度(米)
    public const float JUMP_HEIGHT = 1.5f;
    // 相机相对玩家头部的偏移
    public static readonly Vector3 CAMERA_HEAD_OFFSET = new Vector3(0f, 0.7f, -0.4f);
    // 开枪间隔下限(秒),即射速上限:每 0.2s 最多一次攻击
    public const float FIRE_INTERVAL = 0.2f;
    // 射线检测最大距离(米)
    public const float FIRE_RANGE = 200f;
    // 射线可命中的层级(默认所有层)
    public const int FIRE_MASK = ~0;
    // 玩家身体(含 AK 模型)旋转角度相对视角角度的系数 k:
    // k = 1 时身体与视角完全同步;k = 0.5 时视角转 90° 身体只转 45°
    public const float BODY_ROTATION_FACTOR = 1f;
    // 红点吸附命中点时沿命中面法线抬高的距离,防止红点陷进面里被遮挡/Z-fighting
    public const float TARGET_NORMAL_OFFSET = 0.02f;

    public const float CAMERA_PITCH_HEIGHT_PER_DEGREE = 0.15f / 10f;

    // ---------------- Inspector 字段 ----------------
    [Tooltip("跟随玩家的相机(不指定则自动获取 Camera.main)")]
    [SerializeField] private Camera playerCamera;

    [Tooltip("枪口位置 Transform(挂在枪模型下的空子物体,代表枪口出膛点)")]
    [SerializeField] private Transform muzzle;

    [Tooltip("枪口火花特效预制体(挂 MuzzleEffect 脚本的 GameObject)")]
    [SerializeField] private GameObject muzzleEffectPrefab;

    [Tooltip("子弹命中特效预制体(挂 BulletBase 脚本的 GameObject)")]
    [SerializeField] private GameObject[] bulletEffectPrefabs;  //子弹列表
    [SerializeField] private GameObject bulletEffectPrefab;     //当前子弹

    [Tooltip("瞄准红点")]
    [SerializeField] private Transform targetDot;

    // ---------------- 运行时引用 ----------------
    private CharacterController characterController;
    private Player player;
    private float verticalVelocity;
    // 上一次开枪的时间(用于射速限制)
    private float lastFireTime = float.NegativeInfinity;

    // ---------------- 生命周期 ----------------
    private void Awake()
    {
        characterController = GetComponent<CharacterController>();
        bulletEffectPrefab = bulletEffectPrefabs[0];
        if (playerCamera == null)
        {
            playerCamera = Camera.main;
        }
    }

    private void Start()
    {
        // 拿到中间层引用
        player = Player.Instance;
        bulletEffectPrefab = bulletEffectPrefabs[0];
        // 锁定鼠标到屏幕中心并隐藏,典型 FPS 操作体验
        Cursor.lockState = CursorLockMode.Locked;
        Cursor.visible = false;

        // 演示:通过中间层通知 UI(若 UI 还未注册,会被静默忽略)
        if (player != null)
        {
            player.NotifyShowHint("控制已激活:WASD 移动,鼠标视角,Space 跳跃。", 3f);
        }
    }

    private void Update()
    {
        HandleMouseLook();
        HandleMovement();
        HandleFireInput();
    }

    private void HandleFireInput()
    {
        if (Input.GetMouseButtonDown(0))
        {
            Fire();
        }
    }

    public bool Fire()
    {
        // 射速限制:距离上一次开枪不足 FIRE_INTERVAL,本次不开枪
        if (Time.time - lastFireTime < FIRE_INTERVAL)
        {
            return false;
        }
        lastFireTime = Time.time;

        // 从屏幕中心(准星位置)发出射线
        if (playerCamera == null)
        {
            playerCamera = Camera.main;
        }
        if (playerCamera == null)
        {
            return false;
        }

        // 命中判定与红点吸附共用同一条准星射线
        bool hitSomething = TryGetAimHit(out RaycastHit hitInfo);

        // 开枪日志反馈:命中 / 未命中
        if (hitSomething)
        {
            Debug.Log($"[Fire] 命中!目标: {hitInfo.collider.name},距离: {hitInfo.distance:F2}m");

            // ===== 诊断 dump:命中层的几何 / 材质 / 数据 =====
            // 只在开火时打印(放在 TryGetAimHit 里会每帧刷屏)
            DecalDiag.LogHit(hitInfo, FIRE_MASK);

            // 演示:命中时通过中间层通知 UI(若 UI 未注册则被静默忽略)
            if (player != null)
            {
                player.NotifyShowHint($"命中: {hitInfo.collider.name}", 1f);
            }

            // 在命中点播放一次子弹命中特效
            SpawnBulletHitEffect(hitInfo.point, hitInfo.normal);
        }
        else
        {
            Debug.Log("[Fire] 未命中。");
        }

        // 无论命中与否,开火就播放一次枪口火花特效
        SpawnMuzzleFlash();

        return hitSomething;
    }

    private void SpawnMuzzleFlash()
    {
        if (muzzleEffectPrefab == null)
        {
            Debug.LogWarning("[Muzzle] muzzleEffectPrefab 未配置,跳过枪口特效。");
            return;
        }
        if (muzzle == null)
        {
            Debug.LogWarning("[Muzzle] muzzle Transform 未配置,跳过枪口特效。");
            return;
        }

        // 用枪口位置/朝向从对象池取实例,父级设为 muzzle,这样枪动时火花跟着移动
        GameObject go = GameObjectPool.Get(muzzleEffectPrefab, muzzle.position, muzzle.rotation, muzzle);
        if (go == null) return;

        // 调试日志:打出父级 + 最终世界位置/旋转,排查"位置不对"
        var t = go.transform;
        Debug.Log($"[Muzzle] 实例化: {go.name}\n" +
                  $"          parent  = {t.parent?.name ?? "<无>"}\n" +
                  $"          worldPos= {t.position}\n" +
                  $"          worldRot= {t.eulerAngles}\n" +
                  $"          muzzlePos= {muzzle.position}\n" +
                  $"          muzzleRot= {muzzle.eulerAngles}");

        // 给根节点加一点随机小角度,避免连发时火光位置完全一致
        go.transform.localRotation = Quaternion.Euler(
            Random.Range(-10f, 10f),
            Random.Range(-20f, 20f),
            Random.Range(-5f, 5f)
        );

        MuzzleEffect effect = go.GetComponent<MuzzleEffect>();
        if (effect == null)
        {
            Debug.LogWarning($"[Muzzle] 预制体 {go.name} 上找不到 MuzzleEffect 组件,归还到池。");
            GameObjectPool.Release(muzzleEffectPrefab, go);
            return;
        }

        // 订阅"播完"事件:特效结束自动归还到池(实例方法,可解绑)
        effect.Finished += OnMuzzleFinished;
        effect.Fire();
    }

    private void OnMuzzleFinished(MuzzleEffect effect)
    {
        if (effect == null) return;
        effect.Finished -= OnMuzzleFinished;     // 先解绑,防止池复用时重复触发
        //Debug.Log($"[Muzzle] {effect.name} 播放完成,归还对象池。");
        GameObjectPool.Release(muzzleEffectPrefab, effect.gameObject);
    }

    /// <summary>
    /// 在射线命中点实例化一次子弹命中特效,交给 BulletBase.PlayAt 摆位 + 播粒子,
    /// 播完后由 PlayerControl 协程归还到对象池。
    /// </summary>
    private void SpawnBulletHitEffect(Vector3 position, Vector3 normal)
    {
        if (bulletEffectPrefab == null)
        {
            Debug.LogWarning("[Bullet] bulletEffectPrefab 未配置,跳过命中特效。");
            return;
        }

        // 让 +Z 对着命中面外法线(贴面朝外),与 BulletBase.PlayAt 内部保持一致
        // normal 可能为零向量(命中特效面片背面 / 从碰撞体内部命中),
        // 用相机朝向兜底,避免 Quaternion.LookRotation 抛 "viewing vector is zero"
        Vector3 fallback = playerCamera != null ? playerCamera.transform.forward : Vector3.forward;
        Quaternion rotation = BulletBase.SafeLookRotation(-normal, fallback);
        GameObject go = GameObjectPool.Get(bulletEffectPrefab, position, rotation);
        if (go == null) return;

        BulletBase bullet = go.GetComponent<BulletBase>();
        if (bullet == null)
        {
            Debug.LogWarning($"[Bullet] 预制体 {go.name} 上找不到 BulletBase 组件,归还到池。");
            GameObjectPool.Release(bulletEffectPrefab, go);
            return;
        }

        // 记下来源预制体:FireBullet 容量上限驱逐时需要按此归还到正确池
        bullet.SourcePrefab = bulletEffectPrefab;

        bullet.PlayAt(position, normal);

        // 用 prefab 上声明的 HitEffectDuration 决定归还时机
        float duration = bullet.HitEffectDuration;
        StartCoroutine(ReleaseBulletEffectAfter(bulletEffectPrefab, go, duration));
    }

    private System.Collections.IEnumerator ReleaseBulletEffectAfter(GameObject prefab, GameObject instance, float delay)
    {
        if (delay > 0f) yield return new WaitForSeconds(delay);
        if (instance == null) yield break;       // 已被外部销毁
        GameObjectPool.Release(prefab, instance);
    }

    private bool TryGetAimHit(out RaycastHit hitInfo)
    {
        hitInfo = default;

        if (playerCamera == null)
        {
            playerCamera = Camera.main;
        }
        if (playerCamera == null)
        {
            return false;
        }

        Ray ray = playerCamera.ViewportPointToRay(new Vector3(0.5f, 0.5f, 0f));

        // 使用 RaycastAll 获取射线路径上的所有命中,
        // 避免 Physics.Raycast 只返回首个命中导致对薄物体/密集物体的误判
        RaycastHit[] hits = Physics.RaycastAll(ray, FIRE_RANGE, FIRE_MASK);

        // 按距离从近到远排序,取最近的一次"有效命中"
        System.Array.Sort(hits, (a, b) => a.distance.CompareTo(b.distance));

        foreach (RaycastHit hit in hits)
        {
            if (!IsValidHit(hit))
            {
                continue;
            }

            hitInfo = hit;
            return true; // 只取最近的有效命中
        }

        return false;
    }

    /// <summary>
    /// 每帧把瞄准红点吸附到准星射线的命中点;未命中任何物体时,
    /// 红点停在射线最大距离处(准星方向的远处)。
    /// </summary>
    private void UpdateAimTarget()
    {
        if (targetDot == null) return;

        if (TryGetAimHit(out RaycastHit hitInfo))
        {
            // 沿命中面法线抬高一点,防止红点陷进表面被遮挡
            targetDot.position = hitInfo.point + hitInfo.normal * TARGET_NORMAL_OFFSET;
            // 让红点的 forward 朝外(贴着命中面),quad 类红点这样才正对观察方向
            targetDot.rotation = Quaternion.LookRotation(-hitInfo.normal);
        }
        else
        {
            // 没打到东西:红点悬在射线上离玩家 FIRE_RANGE 远处
            if (playerCamera != null)
            {
                Ray ray = playerCamera.ViewportPointToRay(new Vector3(0.5f, 0.5f, 0f));
                targetDot.position = ray.origin + ray.direction * FIRE_RANGE;
                targetDot.rotation = Quaternion.LookRotation(ray.direction);
            }
        }
    }

    private bool IsValidHit(RaycastHit hit)
    {
        // 碰撞体必须存在且启用,Trigger 只是事件区域,不算实体命中
        if (hit.collider == null || !hit.collider.enabled || hit.collider.isTrigger)
        {
            DecalDiag.Log("P5", "R5",
                "命中被过滤:碰撞体为空 / 未启用 / 是 Trigger 触发区",
                $"collider={(hit.collider ? hit.collider.name : "<null>")}, " +
                $"enabled={(hit.collider ? hit.collider.enabled.ToString() : "n/a")}, " +
                $"isTrigger={(hit.collider ? hit.collider.isTrigger.ToString() : "n/a")}");
            return false;
        }

        // 排除玩家自身的碰撞体,防止射线从头顶出发时误打到自己
        if (hit.collider.transform.root == transform.root)
        {
            DecalDiag.Log("P5", "R5",
                "命中被过滤:命中了玩家自身的碰撞体",
                $"collider={hit.collider.name}, root={hit.collider.transform.root.name}");
            return false;
        }

        // 排除特效/贴花/粒子自身。
        // 原因:命中特效预制体(Fire.prefab)里有一个 Plane + MeshCollider,开火后它停在命中点,
        // 之后朝同一位置射击会先打到这个面片而不是墙面 →
        //   ① 特效与贴花在原位无限堆叠
        //   ② hit.normal 取自特效面片(可能是背面 / 零向量)→ 贴花朝向异常甚至报错
        if (IsEffectObject(hit.collider))
        {
            DecalDiag.Log("P5", "R5",
                "命中被过滤:命中了特效/贴花/粒子物体本身(不是真实表面)",
                $"collider={hit.collider.name}, root={hit.collider.transform.root.name}");
            return false;
        }

        // 走到这里说明命中了一个启用的实体碰撞体(带碰撞体,或其父级挂有刚体),视为有效
        return true;
    }

    /// <summary>
    /// 判断命中的碰撞体是否属于"特效类"物体:沿父级链向上查找
    /// BulletBase(命中特效) / DecalProjector(贴花) / ParticleSystem(粒子)。
    /// 这类物体不该被子弹射线命中,否则会造成特效堆叠与法线异常。
    /// </summary>
    private static bool IsEffectObject(Collider c)
    {
        Transform t = c != null ? c.transform : null;
        while (t != null)
        {
            if (t.GetComponent<BulletBase>() != null) return true;
            if (t.GetComponent<DecalProjector>() != null) return true;
            if (t.GetComponent<ParticleSystem>() != null) return true;
            t = t.parent;
        }
        return false;
    }

    private void LateUpdate()
    {
        if (playerCamera == null) return;
        if (player == null) return;

        // 相机位置 = 玩家位置 + 头部偏移(其中 Y 分量随视角俯仰联动)
        // 规则:以"向上看"为正方向,每向上旋转 10 度 → 偏移向量 Y 分量 +0.1 米;
        //       向下旋转为负方向,Y 分量等量减少。
        // 符号说明:RotationX 为负表示向上看(HandleRotation 中是 RotationX -= mouseY),
        //       所以先取反换算成"向上为正"的角度,再乘变化率。
        float pitchUpDegrees = -player.RotationX;
        float cameraOffsetY  = CAMERA_HEAD_OFFSET.y - pitchUpDegrees * CAMERA_PITCH_HEIGHT_PER_DEGREE;

        playerCamera.transform.position = player.Position + new Vector3(
            CAMERA_HEAD_OFFSET.x,
            cameraOffsetY,
            CAMERA_HEAD_OFFSET.z);

        // 相机旋转 = 上下旋转(X) + 左右旋转(Y)
        playerCamera.transform.rotation = Quaternion.Euler(player.RotationX, player.RotationY, 0f);

        // 玩家(含 AK 模型)跟随视角旋转,角度乘以系数 k(BODY_ROTATION_FACTOR)
        // 注意:bodyRotY 需要对 360° 取余,防止 k != 1 时长时间转向后角度无界增长
        float bodyRotX = player.RotationX * BODY_ROTATION_FACTOR;
        float bodyRotY = Mathf.Repeat(player.RotationY * BODY_ROTATION_FACTOR, 360f);
        transform.rotation = Quaternion.Euler(bodyRotX, bodyRotY, 0f);

        // 相机旋转确定之后,再把红点吸附到本帧准星射线的命中点
        UpdateAimTarget();
    }

    private void HandleMouseLook()
    {
        if (player == null) return;

        float mouseX = Input.GetAxis("Mouse X") * MOUSE_SENSITIVITY;
        float mouseY = Input.GetAxis("Mouse Y") * MOUSE_SENSITIVITY;

        // 左右旋转无限累加
        player.RotationY += mouseX;

        // 上下旋转:鼠标向上移动通常对应看向更高处,所以取反并限幅
        player.RotationX -= mouseY;
        player.RotationX = Mathf.Clamp(player.RotationX, -MAX_VERTICAL_ANGLE, MAX_VERTICAL_ANGLE);
    }

    private void HandleMovement()
    {
        if (player == null) return;

        Vector3 forward = Quaternion.Euler(0f, player.RotationY, 0f) * Vector3.forward;
        Vector3 right = Quaternion.Euler(0f, player.RotationY, 0f) * Vector3.right;

        float h = Input.GetAxisRaw("Horizontal"); // A/D
        float v = Input.GetAxisRaw("Vertical");   // W/S

        Vector3 horizontalMove = (forward * v + right * h);
        if (horizontalMove.sqrMagnitude > 1f)
        {
            horizontalMove.Normalize();
        }

        bool isGrounded = characterController.isGrounded;
        player.IsGrounded = isGrounded;
        if (isGrounded && verticalVelocity < 0f)
        {
            verticalVelocity = -0.5f;
        }

        if (isGrounded && Input.GetButtonDown("Jump"))
        {
            verticalVelocity = Mathf.Sqrt(JUMP_HEIGHT * -2f * GRAVITY);
        }
        else
        {
            verticalVelocity += GRAVITY * Time.deltaTime;
        }

        Vector3 finalMove = horizontalMove * MOVE_SPEED + Vector3.up * verticalVelocity;
        characterController.Move(finalMove * Time.deltaTime);
    }
}