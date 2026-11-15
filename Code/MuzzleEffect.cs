using System;
using System.Collections;
using UnityEngine;


[DisallowMultipleComponent]
public class MuzzleEffect : MonoBehaviour
{
    [Header("特效预制体(根)")]
    [Tooltip("特效根 Transform。下面挂有火花面片、点光源、粒子系统等子物体。")]
    [SerializeField] private Transform muzzleEffect;

    [Header("粒子集合")]
    [Tooltip("muzzleEffect 下的粒子系统数组。留空时 Awake 自动从 muzzleEffect 收集。")]
    [SerializeField] private ParticleSystem[] muzzleParticles;

    [Header("闪光持续时间(秒)")]
    [Tooltip("从 Fire() 到特效整体隐藏的延时。")]
    [Range(0.01f, 1f)] public float flashTime = 0.1f;

    [Header("可选:点光源(场景照明)")]
    [Tooltip("挂在 muzzleEffect 下的 Light 组件,用于火光一闪的环境照明。留空表示不联动。")]
    [SerializeField] private Light flashLight;
    [SerializeField] private float lightStartIntensity = 6f;

    private float _lightBase;            // Light 的初始亮度,OnDisable 复位用
    private Coroutine _hideCo;            // 当前挂起的隐藏协程(防止快速连发时重叠)
    private bool _initialized;            // Awake 收集是否完成


    public event Action<MuzzleEffect> Finished;

    private void Awake()
    {
        if (flashLight != null) _lightBase = flashLight.intensity;

        _initialized = true;
    }

    public void Fire()
    {
        if (!_initialized) Awake();

        if (!gameObject.activeSelf)
        {
            gameObject.SetActive(true);
        }


        if (muzzleEffect == null)
        {
            Debug.LogWarning($"[MuzzleEffect] {name} 上的 MuzzleEffect 字段未配置,无法播放。");
            return;
        }

        if ((muzzleParticles == null || muzzleParticles.Length == 0) && muzzleEffect != null)
        {
            muzzleParticles = muzzleEffect.GetComponentsInChildren<ParticleSystem>(true);
        }

        muzzleEffect.gameObject.SetActive(true);

        int playCount = 0;
        if (muzzleParticles != null)
        {
            for (int i = 0; i < muzzleParticles.Length; i++)
            {
                var ps = muzzleParticles[i];
                if (ps != null)
                {
                    ps.Play(true);
                    playCount++;
                }
            }
        }
        if (flashLight != null) flashLight.intensity = lightStartIntensity;

        if (_hideCo != null) StopCoroutine(_hideCo);
        _hideCo = StartCoroutine(HideAfterDelay());
    }

    private IEnumerator HideAfterDelay()
    {
        float t = 0f;
        while (t < flashTime)
        {
            t += Time.deltaTime;

            // 光源亮度随时间二次衰减(更接近真实火光)
            if (flashLight != null)
            {
                float k = Mathf.Clamp01(t / flashTime);
                flashLight.intensity = Mathf.Lerp(lightStartIntensity, 0f, k * k);
            }
            // 每帧推进一次(等一帧),而不是等整个 flashTime,
            // 否则总时长会被拉长约 flashTime/deltaTime 倍
            yield return null;
        }

        // 关闭特效根
        if (muzzleEffect != null && muzzleEffect != transform)
        {
            muzzleEffect.gameObject.SetActive(false);
        }

        // 还原光源,避免下次出池时残留
        if (flashLight != null) flashLight.intensity = _lightBase;

        // 通知外部"我播完了,可以归还到池了"
        Finished?.Invoke(this);

        // 事件 invoke 之后再清空,防止池复用同一 GameObject 时累积旧订阅
        Finished = null;

        _hideCo = null;
    }

    private void OnDisable()
    {
        if (_hideCo != null)
        {
            StopCoroutine(_hideCo);
            _hideCo = null;
        }
        if (flashLight != null) flashLight.intensity = _lightBase;
    }
}
