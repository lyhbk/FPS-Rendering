using System.Collections.Generic;
using UnityEngine;

public class DecalManager : MonoBehaviour
{
    public static DecalManager Instance;
    private void Awake() {
        if (Instance == null)
            Instance = this;
        else
            Destroy(this);
    }


    private void Update()
    {
        // Tick 阶段只推进时间,不改动 ActiveDecals,避免迭代中修改集合
        List<DecalProjector> removeList = new List<DecalProjector>();
        foreach (var decal in DecalRenderFeature.ActiveDecals)
        {
            if (decal == null) { removeList.Add(decal); continue; }
            if (decal.Tick(Time.deltaTime)) removeList.Add(decal);
        }

        foreach (var d in removeList)
        {
            DecalRenderFeature.UnRegister(d);
            if (d == null) continue;

            if (d.sourcePrefab != null)
            {
                // 池化贴花:用来源预制体归还到正确的池
                GameObjectPool.Release(d.sourcePrefab, d.gameObject);
            }
            else
            {
                // 场景手动摆放(无来源池):不销毁场景物体,仅隐藏
                d.gameObject.SetActive(false);
            }
        }
    }
}

