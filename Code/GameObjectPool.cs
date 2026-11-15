using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Pool;

public static class GameObjectPool
{

    private static readonly Dictionary<int, ObjectPool<GameObject>> s_pools = new();

    public const int DEFAULT_CAPACITY = 8;
    public const int DEFAULT_MAX_SIZE  = 32;

    public static GameObject Get(
        GameObject prefab,
        Vector3 worldPosition,
        Quaternion worldRotation,
        Transform parent = null,
        int capacity = DEFAULT_CAPACITY,
        int maxSize = DEFAULT_MAX_SIZE)
    {
        if (prefab == null)
        {
            Debug.LogWarning("[GameObjectPool] prefab 为 null,Get 返回 null");
            return null;
        }

        ObjectPool<GameObject> pool = GetOrCreatePool(prefab, capacity, maxSize);
        GameObject go = pool.Get();
        Transform t = go.transform;
        t.SetParent(parent, worldPositionStays: true);
        t.SetPositionAndRotation(worldPosition, worldRotation);

        // 池里取出的可能是 inactive,强制激活
        if (!go.activeSelf) go.SetActive(true);
        return go;
    }

    public static void Release(GameObject prefab, GameObject instance)
    {
        if (instance == null) return;
        if (prefab == null)
        {
            Object.Destroy(instance);
            return;
        }

        int key = prefab.GetInstanceID();
        if (s_pools.TryGetValue(key, out ObjectPool<GameObject> pool))
        {
            pool.Release(instance);
        }
        else
        {
            Debug.LogWarning($"[GameObjectPool] prefab {prefab.name} 没注册过池,直接 Destroy 实例 {instance.name}");
            Object.Destroy(instance);
        }
    }

    public static void Clear(GameObject prefab = null)
    {
        if (prefab != null)
        {
            int key = prefab.GetInstanceID();
            if (s_pools.TryGetValue(key, out ObjectPool<GameObject> pool))
            {
                pool.Clear();
                s_pools.Remove(key);
            }
        }
        else
        {
            foreach (ObjectPool<GameObject> pool in s_pools.Values) pool.Clear();
            s_pools.Clear();
        }
    }

    private static ObjectPool<GameObject> GetOrCreatePool(GameObject prefab, int capacity, int maxSize)
    {
        int key = prefab.GetInstanceID();
        if (!s_pools.TryGetValue(key, out ObjectPool<GameObject> pool))
        {
            pool = new ObjectPool<GameObject>(
                createFunc: () => Object.Instantiate(prefab),
                actionOnGet: null,
                actionOnRelease: go =>
                {
                    if (go == null) return;
                    go.SetActive(false);
                    // 从父级脱钩,避免在层级里残留(Muzzle 作为父级时尤其重要)
                    go.transform.SetParent(null, worldPositionStays: false);
                },
                actionOnDestroy: go => { if (go != null) Object.Destroy(go); },
                collectionCheck: false,        // 关掉重复 release 检测,提升性能
                defaultCapacity: capacity,
                maxSize: maxSize);
            s_pools[key] = pool;
        }
        return pool;
    }
}
