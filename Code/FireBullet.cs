using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// 火焰子弹。
/// - 命中表现:粒子 + 灼烧贴花,均通过 BulletBase.PlayAt + 预制体配置驱动。
/// - 数量上限:同屏同时存在的 FireBullet 实例最多 8 个,超出按入队顺序驱逐最旧的
///   并归还到对象池,避免频繁开火时火焰特效无限堆积。
/// </summary>
public class FireBullet : BulletBase
{
    /// <summary>FireBullet 同时存在的最大数量;超出时按入队顺序驱逐最旧的</summary>
    public const int MaxActive = 8;

    // 全局静态:当前所有激活的 FireBullet 实例队列(FIFO)
    private static Queue<FireBullet> s_active = new Queue<FireBullet>();

    public FireBullet() : base(0)
    {
    }

    /// <summary>
    /// 池取出/复用时触发入队:若已达上限,先 Dequeue 队首(最旧)并归还到它的对象池,再 Enqueue 自己。
    /// </summary>
    protected virtual void OnEnable()
    {
        // 池复用时可能被重复激活,已在队列中则跳过
        if (s_active.Contains(this)) return;

        if (s_active.Count >= MaxActive)
        {
            FireBullet evicted = s_active.Dequeue();
            if (evicted != null)
            {
                if (evicted.SourcePrefab != null)
                {
                    // 归还到正确的对象池(与自然释放路径走同一通道,不会产生重复入池)
                    GameObjectPool.Release(evicted.SourcePrefab, evicted.gameObject);
                    Debug.Log($"[FireBullet] 容量上限({MaxActive})已达,驱逐最旧实例 {evicted.name},归还到 {evicted.SourcePrefab.name} 池");
                }
                else
                {
                    // 理论不该出现(Spawner 必须写入 SourcePrefab),兜底只隐藏不销毁
                    evicted.gameObject.SetActive(false);
                    Debug.LogWarning($"[FireBullet] 驱逐时 SourcePrefab 为空,仅 SetActive(false) 兜底");
                }
            }
        }
        s_active.Enqueue(this);
    }

    /// <summary>
    /// 自然释放(SetActive(false) 或 Destroy)时触发反注册。
    /// Queue&lt;T&gt; 不支持按值移除,小容量下重建队列(O(N) 可接受)。
    /// </summary>
    protected virtual void OnDisable()
    {
        if (s_active.Count == 0 || !s_active.Contains(this)) return;

        var next = new Queue<FireBullet>(s_active.Count);
        foreach (var x in s_active)
        {
            if (!ReferenceEquals(x, this)) next.Enqueue(x);
        }
        s_active = next;
    }
}
