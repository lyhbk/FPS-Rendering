using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class BulletBase : MonoBehaviour
{
    [Header("子弹名")]
    [SerializeField] protected int id;

    [Header("数值")]
    protected int hurt;

    [Header("特效")]
    [SerializeField] protected Transform muzzleEffect;
    [SerializeField] protected ParticleSystem[] muzzleParticles;

    /// <summary>
    /// 命中特效在命中点播放完后保持可见的时长(秒)。
    /// 由调用方用 WaitForSeconds(duration) 后归还对象池,这里只声明不做协程。
    /// </summary>
    [Header("命中特效")]
    [SerializeField] protected float hitEffectDuration = 5f;

    [Header("命中贴花投射器预制体(留空=不生成贴花)")]
    [SerializeField] protected GameObject decalProjectorPrefab;

    /// <summary>
    /// 运行时:由 Spawner(如 PlayerControl)写入,用于容量上限驱逐时把实例归还到正确的对象池。
    /// 标记 NonSerialized,避免预制体上的默认值污染。
    /// </summary>
    [System.NonSerialized] public GameObject SourcePrefab;

    public float HitEffectDuration => hitEffectDuration;

    public BulletBase(int id)
    {
        this.id = id;
    }

    // protected virtual:子类若定义自己的 Awake,必须 override 并调 base.Awake(),
    // 否则 C# 遮蔽基类方法,Unity 只调子类 Awake,粒子收集会被静默跳过。
    protected virtual void Awake()
    {
        muzzleEffect = this.transform;
        if (muzzleEffect == null)
        {
            Debug.LogWarning($"[BulletBase] {name} 的 muzzleEffect 未配置,无法自动收集 muzzleParticles。");
            return;
        }

        // 从 muzzleEffect 的子物体收集粒子系统:
        int childCount = muzzleEffect.childCount;

        var list = new List<ParticleSystem>(childCount - 1);
        for (int i = 1; i < childCount; i++)
        {
            Transform child = muzzleEffect.GetChild(i);
            ParticleSystem ps = child.GetComponent<ParticleSystem>();
            if (ps != null)
            {
                list.Add(ps);
            }
            else
            {
                Debug.LogWarning($"[BulletBase] {name} 的 muzzleEffect 第 {i + 1} 个子物体 {child.name} 上没有 ParticleSystem,已跳过。");
            }
        }
        muzzleParticles = list.ToArray();
    }


    /// <summary>
    /// 安全版 Quaternion.LookRotation。
    /// forward 为零向量时 Unity 会抛 "LookRotation viewing vector is zero"
    /// (射线命中特效面片背面 / 从碰撞体内部命中时 hit.normal 可能为 (0,0,0)),
    /// 这里用 fallback 兜底,保证特效与贴花不会因此中断。
    /// </summary>
    public static Quaternion SafeLookRotation(Vector3 forward, Vector3 fallback)
    {
        if (forward.sqrMagnitude < 1e-6f)
        {
            forward = fallback.sqrMagnitude > 1e-6f ? fallback : Vector3.forward;
        }
        return Quaternion.LookRotation(forward);
    }

    public virtual void PlayAt(Vector3 position, Vector3 normal)
    {
        // 调用链诊断:确认 PlayAt 已被调用及子弹实例身份
        Debug.Log($"[BulletBase] PlayAt 调用: {GetType().Name}({name}) @ {position:F2}");

        // 1) 摆位:把特效根移到命中点,并让 +Z 对着命中面外法线(贴面朝外)
        if (muzzleEffect != null)
        {
            muzzleEffect.gameObject.SetActive(true);
            muzzleEffect.position = position;
            muzzleEffect.rotation = SafeLookRotation(-normal, Vector3.forward);
        }
        else
        {
            // 没有指定特效根时,不强报错,只打一行警告避免淹没控制台
            Debug.LogWarning($"[BulletBase] {name} 的 muzzleEffect 未配置,PlayAt 只播粒子。");
        }

        // 2) 播粒子:withChildren=true 把子发射器一起 Reset 重播
        if (muzzleParticles != null)
        {
            for (int i = 0; i < muzzleParticles.Length; i++)
            {
                ParticleSystem ps = muzzleParticles[i];
                if (ps != null) ps.Play(true);
            }
        }

        // 3) 命中贴花:留空则跳过,任何子类按预制体配置即可,无需 override
        SpawnDecal(position, normal);
    }

    /// <summary>
    /// 在命中点生成贴花投射器(对象池 + 自动注册,到期由 DecalProjector.Update 归还池)。
    /// </summary>
    protected void SpawnDecal(Vector3 position, Vector3 normal)
    {
        if (decalProjectorPrefab == null)
        {
            Debug.LogWarning($"[BulletBase] {name} 的 decalProjectorPrefab 未配置,本次命中不生成贴花。");
            return;
        }

        Quaternion rotation = SafeLookRotation(-normal, Vector3.forward);
        GameObject decalGo = GameObjectPool.Get(decalProjectorPrefab, position, rotation);
        if (decalGo == null)
        {
            Debug.LogWarning($"[BulletBase] 对象池获取贴花实例失败(prefab={decalProjectorPrefab.name})。");
            return;
        }

        DecalProjector decal = decalGo.GetComponent<DecalProjector>();
        if (decal == null)
        {
            Debug.LogWarning($"[BulletBase] {decalGo.name} 上缺少 DecalProjector 组件,归还对象池。");
            GameObjectPool.Release(decalProjectorPrefab, decalGo);
            return;
        }

        // 记录来源预制体,到期自动归还池;注册/反注册由 OnEnable/OnDisable 自动完成
        decal.sourcePrefab = decalProjectorPrefab;
        decal.ResetDecal(position, rotation);

        Debug.Log($"[BulletBase] 生成贴花 {decalGo.name} @ {position:F2}, 法线方向 {(-normal).ToString("F2")}, " +
                  $"存活 {decal.lifeTime:F1}s(淡出 {decal.fadeTime:F1}s)");

        // ===== 诊断 P1(R1):确认贴花实例已真正进入绘制队列 =====
        // DecalProjector.OnEnable 里 Register 后这里再复核一次
        bool queued = DecalRenderFeature.ActiveDecals.Contains(decal);
        DecalDiag.Log("P1", "R1",
            "贴花实例化完成:复核是否已进入 ActiveDecals(未进入则 Execute 不会打包它)",
            $"instance={decalGo.name}, queued={queued}, queueCount={DecalRenderFeature.ActiveDecals.Count}, " +
            $"sourcePrefab={(decalProjectorPrefab ? decalProjectorPrefab.name : "<null>")}, " +
            $"Fade01={decal.Fade01:F3}, Age01={decal.Age01:F3}");
        if (!queued)
            DecalDiag.LogError("P1", "R1",
                "贴花实例化后仍未进入 ActiveDecals:GPU 端读不到它的 worldToBox/boxSize,贴花必然不可见",
                $"instance={decalGo.name}, 请检查 DecalRenderFeature.Register 是否被跳过(重复/队列满)");
    }
}
