# FPS-Rendering

GunWar — URP 第一人称射击与自定义贴花渲染 Demo
基于 团结引擎（Tuanjie 1.10.3 / Editor 2022.3.62t15）+ Universal Render Pipeline 14.2.0 的渲染向个人 Demo。 以"一枪打出去之后画面上留下什么"为主线，覆盖 自定义 Renderer Feature 贴花系统、命中特效对象池、赛博朋克风格化 Shader 与编辑器工具链。

说明：本项目为个人渲染技术验证 Demo，重点在渲染管线扩展与画面表现，关卡内容为测试场景。

一、项目亮点
亮点	        说明
自研贴花系统	不使用 URP 内置 Decal，手写 ScriptableRendererFeature + StructuredBuffer + DrawProcedural，N 个贴花恒为 1~2 次 DrawCall
程序化烧灼表现	深度重建世界坐标 + 盒体裁剪 + FBM 噪声，一次命中同时给出"碳化（乘法）"与"余烬（加法）"两个 Pass
面向性能的分级降级	按贴花数量与屏幕预算三档自动降档：旧贴花淘汰、噪声层数 4→2→1、跳过余烬 Pass
完整的编辑器工具链	霓虹烘焙点光、一键赛博朋克调色、烧灼贴图生成等 4 个 Editor 工具，全部菜单化
对象池贯穿全链路	枪口火花、命中特效、贴花统一走 prefab 分池，无运行时 Instantiate 抖动
二、运行环境
项	版本
引擎	团结引擎 Tuanjie 1.10.3（Editor 版本号 2022.3.62t15）
渲染管线	Universal RP 14.2.0-t1
依赖	TextMeshPro 3.0.9、Timeline 1.8.9-t1、Visual Scripting 1.9.4
平台	Windows（Standalone）
使用团结引擎打开；若用原版 Unity 2022.3 打开，需注意团结引擎内置包（如 TuanjieGI 相关 Shader）的兼容性告警。

三、快速开始
克隆仓库：
bash
git clone https://github.com/lyhbk/FPS-Rendering.git
仓库名与本地工程名不同：克隆后得到的是 FPS-Rendering 目录，工程实际名称为 GunWar，二者指同一个工程，直接打开该目录即可。
用团结引擎 1.10.3 打开工程根目录（首次导入会重建 Library/，耗时较长属正常）。
打开场景 Assets/Scenes/Main.unity，点击 Play。
若画面霓虹下方没有光池：执行菜单 Tools → 赛博朋克光照 → ① 检查烘焙前置条件 → ② 为霓虹生成烘焙点光，再烘焙光照贴图（这些灯是 Baked 模式，不烘焙不生效）。
若想调整整体色调：菜单 Tools → 赛博朋克调色 → 应用第一档(后处理全套)，可用 还原(关闭第一档) 回退。
四、操作说明
输入	行为
W / A / S / D	移动（CharacterController，速度 20 m/s）
鼠标移动	视角旋转，上下视角限制在 ±30°
Space	跳跃（跳跃高度 1.5 m，重力 -9.81）
鼠标左键	开火（射速上限 5 发/秒，射线检测距离 200 m）
开火后会在命中点生成特效与烧灼贴花，贴花默认存活 8 秒，最后 2 秒淡出。

五、功能一览
第一人称控制：CharacterController 驱动，鼠标视角 + 身体朝向系数可调，瞄准红点沿命中面法线抬升 0.02 m 避免 Z-Fighting。
射线命中判定：使用 Physics.RaycastAll 取射线路径全部命中并逐个有效性校验，避免 Physics.Raycast 只返回首个命中导致的薄物体/密集物体误判。
枪口火花 / 命中特效：粒子系统按命中面法线朝外对齐，零向量法线有兜底，避免 LookRotation viewing vector is zero 中断特效链。
自定义贴花：命中留痕，支持盒体尺寸、存活时长、淡出时长、年龄驱动的余烬冷却。
风格化 Shader：霓虹网格地面、建筑窗格、自发光招牌、灯笼、火焰、枪械自定义 PBR 等 16 个 Shader。
后处理：ACES Tonemapping、Bloom、Color Adjustments、色差、暗角、颗粒。
编辑器工具：霓虹烘焙点光、一键调色、烧灼贴图生成、Bloom 参数修复。
六、技术实现
6.1 自定义贴花系统
贴花相关的四个核心文件：

文件	职责
Assets/Code/DecalRenderFeature.cs	Renderer Feature：收集本帧贴花、打包实例数据、发起绘制
Assets/Code/DecalProjector.cs	贴花投射器：盒体尺寸 + 生命周期，自动注册/反注册
Assets/MatShader/BurnDecal.shader	两个 Pass：碳化（乘法混合）与余烬（加法混合）
Assets/MatShader/BurnDecalCommon.hlsl	两 Pass 共用的顶点、Uniform、深度重建与碳化评估逻辑
绘制路径：Feature 挂在 Main_Renderer 上，renderPassEvent = AfterRenderingOpaques，并通过 ConfigureInput(ScriptableRenderPassInput.Depth) 取得深度图。

一次打包、一次绘制：每帧把最多 MaxDecals = 10 个贴花的 worldToBox / boxToWorld / boxSize / fadeAge 打包进一个 StructuredBuffer（结构体 160 字节，与 HLSL 端逐字段对应），然后以 DrawProcedural 绘制 6 × count 个顶点——每个贴花对应一个投影包围盒矩形。这样 DrawCall 数与贴花数量无关（恒为 1~2 次），片元开销也退化为"各贴花投影面积之和"，而不是"数量 × 全屏"。

逐贴花差异化：顶点阶段用 SV_VertexID 与 boxToWorld 把盒子 8 个角投到裁剪空间算出屏幕包围盒，片元阶段用 worldToBox 做盒体裁剪（boxMask），再从深度纹理重建世界坐标，得到每个贴花独立的朝向、尺寸与衰减。

三级性能降级（阈值均可在 Inspector 配置）：

降级	触发条件	做法
① 旧贴花淘汰	队列长度超过 hardCap	跳过队首最旧的若干个，只画最新的
② 噪声降档	数量 > 4 用 1 层 FBM，数量 > 2 用 2 层，否则 4 层	CPU 每帧下发 _DecalFbmOct，直接省 ALU
③ 余烬 Pass 跳过	数量 > emberDegradeAbove（默认 2）	不提交余烬 Pass，省掉一次全屏绘制
踩坑记录：RenderScale 下的屏幕 UV _ScreenParams 是最终屏幕尺寸，而相机 RT 与 _CameraDepthTexture 的尺寸是"屏幕尺寸 × RenderScale"。若用 _ScreenParams 归一化屏幕 UV，在 RenderScale < 1 时 UV 只覆盖到 0..renderScale，采样到的深度整体偏移，贴花随之错位。这里统一改用 _ScaledScreenParams，与 URP 官方 ShaderPassDecal.hlsl 用 _ScreenSize.zw 的写法等价，RenderScale = 1 时二者相同，向下兼容。另外不能改用 GetNormalizedScreenSpaceUV()——它会额外翻转 Y，而 ComputeWorldSpacePosition 内部已处理过翻转，再翻一次画面会上下颠倒。

6.2 射击与命中反馈链路
鼠标左键 → PlayerControl.HandleFireInput（射速闸门 0.2s）
        → TryGetAimHit：Physics.RaycastAll + 有效性过滤
        → 枪口火花：GameObjectPool.Get(muzzleEffectPrefab, 枪口位姿)
        → 命中特效：GameObjectPool.Get(bulletEffectPrefab, 命中点, 朝外法线)
        → BulletBase.PlayAt：摆位 → 播粒子 → SpawnDecal
        → DecalProjector.ResetDecal：注册进贴花队列，到期自行归还对象池
6.3 对象池
GameObjectPool 基于 UnityEngine.Pool.ObjectPool<GameObject>，按 prefab 的 InstanceID 分池，默认容量 8、上限 32。 归还时统一 SetActive(false) 并从父级脱钩（枪口特效作为父级时尤其关键），避免层级残留。

6.4 赛博朋克画面
Shader 层：Cyber（建筑霓虹描边）、CyberWindow（窗格）、CyberNightSky、Plane（霓虹网格地面）、DecoEmissive、Lantern / LanternCutout、Fire、Sharp（枪械自定义 PBR：法线贴图、金属/粗糙度分离贴图、IBL 开关、逐像素随机的自发光强度与世界坐标哈希驱动的闪烁）等。
后处理层：CyberpunkGrade 一键写入 Volume Profile——ACES Tonemapping、Bloom（threshold 0.85 / intensity 1.2 / scatter 0.78 / tint 纯白 / 高质量滤波）、Color Adjustments（对比度 +10、轻提曝光）、色差、暗角、颗粒，并统一拉满 Volume Weight。
6.5 编辑器工具链
工具	菜单	作用
NeonBakeLights	Tools → 赛博朋克光照	扫描场景内自发光材质，按亮度与尺寸自动生成 Baked 点光，补足自发光不会照亮环境的短板；含前置检查与一键删除
CyberpunkGrade	Tools → 赛博朋克调色	通过 Unity API 写入 Volume Profile（避免手改 .asset 的 script GUID 引用错误），可重复执行与还原
BurnDecalTextureGenerator	Assets → 生成烧灼贴图	程序化生成贴花需要的烧灼遮罩贴图
FixBloomParams	—	批量修正 Bloom 参数
七、目录结构
Assets/
├─ Code/                 # 运行时逻辑（14 个 C# 脚本，约 1.5k 行）
│  ├─ PlayerControl.cs   # 第一人称移动、视角、开火
│  ├─ Player.cs          # 玩家中间层单例，解耦控制与 UI
│  ├─ BulletBase.cs      # 命中特效与贴花生成
│  ├─ FireBullet.cs      # 子弹表现
│  ├─ MuzzleEffect.cs    # 枪口火花
│  ├─ DecalRenderFeature.cs / DecalProjector.cs / DecalManager.cs / DecalDiag.cs
│  ├─ GameObjectPool.cs  # prefab 分池对象池
│  └─ EmissionFlickerControl.cs / PlayerQuestUI.cs / UIFun.cs / Test.cs
├─ Editor/               # 编辑器工具（4 个）
├─ MatShader/            # 16 个自定义 Shader + 1 个共享 HLSL 库（约 3.2k 行）
├─ URP/                  # URP Asset、Renderer、Volume Profile
├─ Scenes/               # Main / Load / TEST 场景
├─ Material/  Mode/  PreObject/  Picture/  # 材质、模型、特效预制体、贴图
八、已知限制与后续计划
贴花上限为单帧 10 个（MaxDecals），超出后按数量降级；未做分帧预算调度。
命中贴花目前只有烧灼一种表现，未区分材质（金属/水泥/玻璃）。
未接入单元测试与 Assembly Definition，Code 目录仍为默认程序集。
后续计划：贴花材质分型、更精细的 GPU 剔除、性能数据（Frame Debugger / Profile Analyzer）整理成文。
