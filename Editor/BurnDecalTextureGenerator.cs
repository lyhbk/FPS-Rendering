using System.IO;
using UnityEditor;
using UnityEngine;

/// <summary>
/// 灼烧贴花贴图生成器。
/// 菜单:Tools → 生成灼烧贴图 (BurnDecal)
/// 生成 512×512 RGBA 贴图,通道约定与 BurnDecalCommon.hlsl 一致:
///   R = 碳化强度(核心 1,边缘 0)
///   G = 噪声值(余烬亮度调制)
///   B = 余烬带遮罩
///   A = 整体遮罩
/// </summary>
public static class BurnDecalTextureGenerator
{
    private const string OutputDir  = "Assets/Material/Fire";
    private const string OutputPath = OutputDir + "/BurnMark.png";
    private const string MaterialPath = OutputDir + "/BurnDecal.mat";

    public static void Generate()
    {
        const int size = 512;
        var tex = new Texture2D(size, size, TextureFormat.RGBA32, false);
        var px = new Color[size * size];

        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                float u = x / (size - 1f);
                float v = y / (size - 1f);

                // 径向距离(中心 0,角上 ~1.41)
                float dx = (u - 0.5f) * 2f;
                float dy = (v - 0.5f) * 2f;
                float d = Mathf.Sqrt(dx * dx + dy * dy);

                // 4 倍频 Perlin 噪声(与 shader 里 fbm 手感一致)
                float n = 0f, amp = 0.5f, f = 6f;
                for (int o = 0; o < 4; o++)
                {
                    n += Mathf.PerlinNoise(u * f, v * f) * amp;
                    f *= 2.03f;
                    amp *= 0.5f;
                }
                n = Mathf.Clamp01(n / 0.95f);

                // 边缘粗糙化:噪声扰动碳化半径
                float rough = (n - 0.5f) * 0.55f;
                float edge = 0.62f + rough;

                // 碳化遮罩:软边过渡
                float charMask = 1f - Mathf.SmoothStep(edge - 0.16f, edge + 0.16f, d);
                // 核心更黑
                float core = 1f - Mathf.SmoothStep(0f, 0.34f, d);
                float darkness = Mathf.Lerp(0.8f, 1f, core);
                // 余烬带:贴着碳化边缘
                float emberBand = Mathf.SmoothStep(edge + 0.1f, edge, d)
                                * Mathf.SmoothStep(edge - 0.1f, edge, d);

                px[y * size + x] = new Color(
                    charMask * darkness,   // R 碳化强度
                    n,                     // G 噪声(余烬调制)
                    emberBand,             // B 余烬带
                    charMask);             // A 整体遮罩
            }
        }

        tex.SetPixels(px);
        tex.Apply();

        // 写盘并导入
        Directory.CreateDirectory(OutputDir);
        File.WriteAllBytes(OutputPath, tex.EncodeToPNG());
        Object.DestroyImmediate(tex);
        AssetDatabase.ImportAsset(OutputPath);

        // 导入设置:Clamp 防边缘接缝,开 mipmap 供远处采样
        if (AssetImporter.GetAtPath(OutputPath) is TextureImporter importer)
        {
            importer.wrapMode = TextureWrapMode.Clamp;
            importer.mipmapEnabled = true;
            importer.SaveAndReimport();
        }

        // 自动赋给现有 BurnDecal.mat
        var mat = AssetDatabase.LoadAssetAtPath<Material>(MaterialPath);
        if (mat != null && mat.HasProperty("_BurnTex"))
        {
            var generated = AssetDatabase.LoadAssetAtPath<Texture2D>(OutputPath);
            mat.SetTexture("_BurnTex", generated);
            EditorUtility.SetDirty(mat);
            AssetDatabase.SaveAssets();
            Debug.Log($"[BurnDecalTexGen] 已生成 {OutputPath} 并自动赋给 {MaterialPath}");
        }
        else
        {
            Debug.Log($"[BurnDecalTexGen] 已生成 {OutputPath}(未找到 {MaterialPath},手动拖入 _BurnTex 字段即可)");
        }
    }
}
