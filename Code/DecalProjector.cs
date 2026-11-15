using UnityEngine;

/// <summary>
/// 简易自定义Decal投射器，配合DecalRenderFeature工作
/// 物体Z轴指向命中面；盒体沿着Z轴投射贴花
/// 生命周期：OnEnable 自动注册 → Update 自行 Tick → 到期反注册并归还对象池
/// </summary>
public class DecalProjector : MonoBehaviour
{
    [Header("投射盒尺寸")]
    public Vector3 size = new Vector3(0.6f, 0.6f, 0.3f);
    [Header("贴花存活总时长")]
    public float lifeTime = 8.0f;
    [Header("淡化开始时间：剩余小于该值开始淡出")]
    public float fadeTime = 2f;

    /// <summary>来源预制体引用，到期归还对象池用；由生成方(FireBullet)赋值</summary>
    [HideInInspector] public GameObject sourcePrefab;

    /// <summary>归一化年龄：0=刚命中(炽热) 1=完全冷却。RenderFeature 写入 _DecalAge 驱动生长/余烬/末期消退</summary>
    public float Age01 => lifeTime > 0f ? Mathf.Clamp01(1f - remainLife / lifeTime) : 1f;

    /// <summary>整体淡化系数：1=完全可见 0=完全透明</summary>
    public float Fade01 { get; private set; } = 1f;

    private float remainLife;

    private void OnEnable()
    {
        // 对象池取出/复用/场景手动摆放都走这里；ResetDecal 随后会覆盖精确状态
        remainLife = lifeTime;
        Fade01 = 1f;
        DecalRenderFeature.Register(this);

        // ===== 诊断 P1(R1):确认该贴花确实进入了待绘制队列 =====
        // 未注册 → shader 里 _DecalData[instanceID] 读到脏数据,fade≈0 → clip 全裁 → 看不见
        bool inQueue = DecalRenderFeature.ActiveDecals.Contains(this);
        DecalDiag.Log("P1", "R1",
            "贴花投射器激活:检查是否成功注册进贴花队列(未注册则 GPU 读不到数据,贴花全裁)",
            $"name={name}, inActiveDecals={inQueue}, queueCount={DecalRenderFeature.ActiveDecals.Count}, " +
            $"Fade01={Fade01:F3}, Age01={Age01:F3}");

        // ===== 诊断 P4(R4):确认贴花自身变换没被父级缩放扭曲 =====
        var ls = transform.lossyScale;
        float det = transform.worldToLocalMatrix.determinant;
        bool degenerate = Mathf.Abs(det) < 1e-6f;
        DecalDiag.Log("P4", "R4",
            "贴花变换检查:确认 lossyScale 正常且 worldToBox 矩阵非退化",
            $"name={name}, parent={transform.parent?.name ?? "<无>"}, localScale={transform.localScale}, " +
            $"lossyScale={ls}, worldToLocal.determinant={det:E2}, degenerate={degenerate}, size={size}");
        if (degenerate)
            DecalDiag.LogError("P4", "R4",
                "贴花 worldToBox 矩阵退化:shader 内 boxMask 恒为 0,贴花必然不可见",
                $"name={name}, lossyScale={ls}, 请检查父级 scale 是否为 0 或含非均匀缩放");
    }

    private void OnDisable()
    {
        // 归还池(SetActive(false))或被销毁时反注册，防止 ActiveDecals 列表残留
        DecalRenderFeature.UnRegister(this);
    }

    /// <summary>
    /// 重置贴花状态，从对象池取出后由生成方调用
    /// </summary>
    public void ResetDecal(Vector3 pos, Quaternion rot)
    {
        transform.SetPositionAndRotation(pos, rot);
        remainLife = lifeTime;
        Fade01 = 1f;

        // ===== 诊断 P1(R1):打印该贴花最终会写进 _DecalData 的三项关键数据 =====
        // fadeAge.x = Fade01(整体淡化), fadeAge.y = Age01(归一化年龄)
        // 若 Fade01≈0 → clip(alpha-0.001) 直接裁掉全部像素
        var m = transform.worldToLocalMatrix;
        DecalDiag.Log("P1", "R1",
            "贴花数据打包前状态:核对 Fade01 与 Age01 是否为预期值",
            $"name={name}, pos={pos:F3}, rot={rot.eulerAngles:F1}, size={size}, " +
            $"Fade01={Fade01:F3}(应≈1.0), Age01={Age01:F3}(0=炽热 1=冷却), " +
            $"worldToLocal.determinant={m.determinant:E2}(不能为0)");
    }

    /// <summary>
    /// 更新生命周期，返回 true 代表已到期，由调用方(DecalManager)负责反注册与归还池。
    /// 注意：本类不再自行 Update 计时，场景中必须存在 DecalManager 驱动。
    /// </summary>
    public bool Tick(float deltaTime)
    {
        remainLife -= deltaTime;
        Fade01 = remainLife < fadeTime ? Mathf.Max(remainLife / fadeTime, 0f) : 1f;
        return remainLife <= 0f;
    }

    // Gizmos编辑器绘制投射盒
    private void OnDrawGizmosSelected()
    {
        Gizmos.matrix = transform.localToWorldMatrix;
        Gizmos.color = Color.magenta;
        Gizmos.DrawWireCube(Vector3.forward * size.z * 0.5f, size);
    }
}
