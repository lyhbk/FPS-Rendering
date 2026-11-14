# GunWar

项目简介：基于团结引擎（Tuanjie 1.10.3，对应 Unity 2022.3.62t15）与 URP 14.2.0-t1 的第一人称射击 Demo，场景是一条室内赛博朋克窄街。玩家持 AK 移动、跳跃、开火，命中面会留下带碳化与余烬两段效果的枪击贴花。

代码集中在 `Assets/Code`与 `Assets/Editor`，渲染相关资产在 `Assets/MatShader`与 `Assets/URP`。

## 一、项目概览

| 项目 | 说明 |
| --- | --- |
| 引擎 | 团结引擎 Tuanjie 1.10.3（Editor 2022.3.62t15） |
| 语言 | C#；运行时脚本 14 个、编辑器脚本 4 个，共 18 个 .cs |
| 核心依赖 | URP 14.2.0-t1（Forward + Volume 后处理）、uGUI 1.0.0、TextMeshPro 3.0.9、Timeline 1.8.9-t1；未引入第三方包 |
| 场景 | `Assets/Scenes/Main.unity` 为主场景；`Load.unity` 只有 Canvas/Button/Text 的加载页；`TEST.unity` 为材质与光照测试场景 |
| 交付形态 | 本地工程，用团结引擎打开 `Assets/Scenes/Main.unity` 直接 Play；没有发布包与可执行文件 |

```
Assets
├── Code                                        # 运行时脚本 14 个
│   ├── PlayerControl.cs                        # 第一人称移动/视角/跳跃，开火链路：射速闸门 → RaycastAll → 特效 → 贴花；准星红点吸附
│   ├── Player.cs                               # 玩家中间层单例：存放视角角度、位置、地面状态，向 UI 转发通知
│   ├── PlayerQuestUI.cs                        # UI 契约接口：ShowHint / HideHint / UpdateHealth
│   ├── UIFun.cs                                # 实现 PlayerQuestUI，在 Canvas 上显示提示文本
│   ├── BulletBase.cs                           # 命中特效基类：记录来源预制体，SafeLookRotation 摆位，播粒子并生成贴花
│   ├── FireBullet.cs                           # 命中火花实例：活跃数达 MaxActive=8 时驱逐最旧并归还池
│   ├── MuzzleEffect.cs                         # 枪口火光：粒子 + Light 强度二次衰减，flashTime=0.1s 后抛 Finished 事件
│   ├── GameObjectPool.cs                       # 静态对象池表（按来源预制体的 instanceID 分池），Get / Release / Clear
│   ├── DecalProjector.cs                       # 单个贴花数据：OnEnable 注册、Tick 计时，lifeTime=8s、fadeTime=2s
│   ├── DecalManager.cs                         # 每帧 Tick 活跃贴花，到期注销并按其来源预制体归还池
│   ├── DecalRenderFeature.cs                   # URP RendererFeature：实例数据打包进 ComputeBuffer，一次 DrawProcedural 画完
│   ├── DecalDiag.cs                            # 贴花不可见时的编号化诊断（P1~P5 现象 / R1~R5 对策）
│   ├── EmissionFlickerControl.cs               # Sharp 材质自发光闪烁的全局 float 开关
│   └── Test.cs                                 # URP RendererFeature 模板残留，未挂到任何 Renderer
├── Editor                                      # 编辑器脚本 4 个
│   ├── CyberpunkGrade.cs                       # 一键给 Global Volume 挂全套后处理 / 还原第一档
│   ├── NeonBakeLights.cs                       # 为霓虹模型批量生成 Baked 点光、检查烘焙前置、清理生成物
│   ├── FixBloomParams.cs                       # 把 Bloom 的 maxIterations 改成 3、clamp 改成 20
│   └── BurnDecalTextureGenerator.cs            # 生成 512×512 灼烧贴图并尝试赋给 BurnDecal.mat
├── MatShader                                   # Shader 16 个 + 公共 HLSL 1 个
│   ├── BurnDecal.shader                        # 贴花绘制：CHAR（碳化）与 EMBER（余烬）两个 Pass
│   ├── BurnDecalCommon.hlsl                    # DecalData 结构、屏幕 UV、深度重建、盒体裁剪的公共实现
│   ├── DecalDepthProxy.shader                  # 早期"深度代理盒"方案，已被平面求交回退取代，未启用
│   ├── Cyber.shader / CyberWindow.shader / CyberNightSky.shader   # 街景主材质、霓虹窗、夜空穹顶
│   ├── Plane.shader / RandomLit.shader / Rendering.shader         # 地面网格、随机亮灯、调色用材质
│   ├── Sharp.shader                            # 霓虹边缘自发光，含 _GLOBAL_EMISSION_FLICKER 闪烁分支
│   ├── Fire.shader / MuzzleFlash.shader        # 命中火花、枪口火光
│   ├── Lantern.shader / LanternCutout.shader   # 纸灯笼与镂空版
│   └── DecoEmissive.shader / Target.shader / UnlitHash.shader     # 装饰自发光、红点准星、无光照网格
├── Material                                    # 材质 37 个、贴图 87 张
│   ├── AK/                                     # AK 的 10 个部件材质（枪管/机匣/弹匣/枪托…）
│   ├── Bullet/Fire/                            # BurnDecal.mat（贴花）、Fire.mat（火花）与效果贴图
│   ├── Lantern/                                # 纸灯笼的 baseColor / emissive / normal 贴图与材质
│   ├── MuzzleFlash/                            # 枪口火光贴图与材质
│   ├── Scene/                                  # 场景材质：Room、Cyber、Plane、Billboard、Light、LightMat
│   ├── MaterPic/                               # 11 个部件贴图目录
│   └── 1.mat / CyberEnvironment.mat / Rendering.mat   # 根目录遗留材质
├── Mode                                        # 模型与特效预制体
│   ├── 01_1.fbx ~ 04_1.fbx                     # 四套霓虹小人角色模型
│   ├── ak.fbx / ak_L.obj                       # 手持武器
│   ├── Room.fbx / Billboard.fbx / Lantern.fbx / Light.fbx    # 房间、广告牌、灯笼、灯
│   └── BulletEffect/                           # Fire.prefab（命中火花）、FireDecal.prefab（贴花）、MuzzleEffect.prefab（枪口）
├── PreObject
│   ├── Effects/ShellHole.shadergraph           # 早期 ShaderGraph 弹孔，已被贴花方案取代
│   └── Mode/Enemy.prefab                       # 备用敌人预制体
├── Picture                                     # 场景截图与开火流程说明图，2 张
├── Scenes
│   ├── Main.unity                              # 主场景：赛博朋克室内街景 + 玩家 + AK
│   ├── Load.unity                              # 只有 Canvas / Button / Text 的加载场景
│   └── TEST.unity                              # Cube / Plane 的材质与光照测试场景
└── URP
    ├── Main.asset                              # 管线资产：HDR 开、MSAA 2x、需深度纹理、RenderScale=1
    ├── Main_Renderer.asset                     # Forward Renderer，挂 DecalRenderFeature（decalMaterial = BurnDecal.mat）
    └── Bloom.asset                             # 后处理 Volume Profile（Tonemapping / Bloom / 调色 / 色差 / 暗角 / 颗粒）
```

```
系统设计说明:

### 一次开火经过哪些环节


鼠标左键
   ↓  HandleFireInput → Fire()
射速闸门  Time.time - lastFireTime ≥ FIRE_INTERVAL(0.2s)
   ↓  不满足则直接返回 false，不产生任何特效
准星射线  playerCamera.ViewportPointToRay(0.5, 0.5)
   ↓  Physics.RaycastAll(ray, FIRE_RANGE = 200m, FIRE_MASK = ~0)
按距离排序 → IsValidHit 逐条过滤 → 取最近的有效命中
   ↓
命中分支  DecalDiag.LogHit → Player.NotifyShowHint → 对象池取命中特效 → BulletBase.PlayAt
          └→ SpawnDecal：池取 FireDecal → 记下 sourcePrefab → DecalRenderFeature.Register（队列满则驱逐最旧）
   ↓  命中与未命中都要走
枪口分支  对象池取 MuzzleEffect，父级设为 muzzle → MuzzleEffect.Fire() → 0.1s 后 Finished → 归还池


射速靠"最后开火时间 + 固定间隔"实现，而不是协程或计时器：`lastFireTime` 初值为 `float.NegativeInfinity`，第一次点击必然通过。间隔 0.2s 意味着单发上限 5 发/秒，这个值写在常量里改起来直观，也不会随帧率抖动。

### 贴花：数据与绘制彻底分开

贴花没有用 URP 自带的 Decal Projector，因为需要"每个贴花独立计时淡出 + 数量硬上限 + 一次 draw call 画完"。职责被拆成三层：

| 脚本 | 职责 | 关键数值 |
| --- | --- | --- |
| `DecalProjector` | 纯数据：盒尺寸、坐标矩阵、生命周期，自行 Tick | `lifeTime = 8s`，`fadeTime = 2s` |
| `DecalManager` | 每个 `Update` 遍历活跃贴花，到期注销并按其 `sourcePrefab` 归还池 | 无固定容量 |
| `DecalRenderFeature` | 每帧把活跃贴花打包成结构化缓冲，一次 `DrawProcedural` 绘制 | `MaxDecals = 10`，每个实例 160 字节 |

绘制用 `DrawProcedural` 而不是实例化 Mesh：每个贴花只占 6 个顶点（屏幕矩形两个三角形），顶点索引由 `vertexID` 推出来，`MaxDecals = 10` 时总共 60 个顶点，CPU 侧只做一次 buffer 上传与一次提交。

RenderFeature 只在 `CameraType.Game` 与 `CameraType.SceneView` 执行，跳过反射、预览、以及主相机之外的中间相机，避免同一帧对同一批贴花重复全屏绘制。

### 贴花着色：屏幕包围盒 → 深度重建 → 盒体裁剪

每个贴花的片元计算是一条固定管线：

1. 顶点阶段把盒体 8 个角变换到裁剪空间，取 NDC 的 min/max 得到屏幕矩形；边缘再外扩 4 像素（`4.0 / _ScaledScreenParams.xy`），防止恰好落在边界的像素被光栅化裁掉。
2. 片元阶段用屏幕 UV 采样 `_CameraDepthTexture`，`LinearEyeDepth` 还原眼空间深度，再经逆投影 + 逆视图矩阵得到世界坐标。
3. 世界坐标乘 `worldToBox` 进入贴花盒局部空间，`boxMask` 判断是否落在盒内；盒外直接 `clip`。
4. 盒内按局部坐标算碳化强度与到边缘的距离，分别喂给两个 Pass。

无深度的情况必须回退：命中面不写深度（纯碰撞体、透明材质、自发光装饰）时，该像素深度恒为远平面，重建点会落到几百米外，被盒体裁剪掉，整片贴花消失。回退做法是用屏幕 UV 从相机反投影出一条视线，与盒中心平面（局部 z = 0）求交。这里不能用"盒体进入点"——进入点落在盒边界上，`boxMask` 在那里恰好为 0，整片贴花会被裁掉；中心平面交点处 z 恒为 0，`boxMask.z` 稳定为 1。视线几乎平行于平面或平面落在相机后方时返回盒外坐标，交给 `boxMask` 处理。

两个 Pass 都用加法混合（`Blend One One`）与 `ZTest Always`：

| Pass | 内容 | 选择理由 |
| --- | --- | --- |
| `CHAR` | 碳化染色 | 早期用 `Blend DstColor Zero`（`dst *= lerp(white, dark, alpha)`），HDR 高亮表面乘 0.02 约等于不可见；改成加法后 HDR 颜色能直接穿透 Bloom |
| `EMBER` | 余烬边缘发光 | 叠加在已烧黑的痕迹边缘，靠 `_EmberWidth` 控制宽度 |

`ZTest Always` 是必须的：全屏三角的 z = 0，在 Reversed-Z 下 `LEqual` 会把远处场景整体裁掉。

### 贴花变多时性能节省

`DecalRenderFeature` 每帧根据活跃数量下发三档降级，阈值在 Inspector 可调，默认值如下：

| 活跃贴花数 | 余烬 Pass | fbm 噪声倍频 | 说明 |
| --- | --- | --- | --- |
| ≤ 2 | 绘制 | 4 | 全质量，`emberDegradeAbove = 2` |
| 3 ~ 4 | 跳过 | 2 | 省掉一个全屏 Pass 的一半开销，`noiseDegradeAbove = 2` |
| ≥ 5 | 跳过 | 1 | `noiseMinAbove = 4`，只保留最低频噪声 |

另有一个 `hardCap`：大于 0 且贴花数超出时，绘制阶段直接跳过队首若干个最旧的，只画最新的。它影响的是"画不画"，不影响"注册不注册"——注册阶段的硬上限仍然是 `MaxDecals = 10`，队列满时先 `Dequeue` 最旧的并归还其对象池，再把新贴花 `Enqueue`，避免产生孤儿实例。

### 玩家与 UI 的中间层

`PlayerControl` 只负责输入与物理，所有要被别处读取的状态都写进 `Player` 单例，UI 侧只认 `PlayerQuestUI` 接口，由 `UIFun` 实现。这样换 UI 实现不需要动玩家脚本，玩家脚本也不必知道 Canvas 存不存在。

相机位置在 `LateUpdate` 里算，因为要等玩家旋转先落地：位置 = `Player.Position + (0, 0.7 - 俯仰角 × 0.015, -0.4)`，`CAMERA_PITCH_HEIGHT_PER_DEGREE = 0.15 / 10`，即每向上 10° 头部抬高 0.1m，给俯仰一点位移感。身体旋转角乘以 `BODY_ROTATION_FACTOR`，Y 分量用 `Mathf.Repeat` 取余，防止系数不为 1 时角度无限增长。

### 编辑器工具链

| 菜单路径 | 作用 |
| --- | --- |
| `Tools/赛博朋克调色/应用第一档| 将各种后处理的参数调整为效果最好的效果 |
| `Tools/赛博朋克调色/还原` | 关闭上述效果 |
| `Tools/赛博朋克光照/① 检查烘焙前置条件` | 检查场景是否具备烘焙前提，获取已生成的点光 |
| `Tools/赛博朋克光照/② 为霓虹生成烘焙点光` | 遍历自发光物体，按亮度与尺寸生成 Baked 点光，父物体名 `NeonBakeLights` |
| `Tools/赛博朋克光照/③ 删除生成的点光` | 删除上一次生成的点光，便于重新生成 |
| `Tools/Bloom 性能参数修复` | 扫描 Profile，把 Bloom 的 `maxIterations` 覆盖为 3、`clamp` 覆盖为 20 |

```
```
问题与解决方案:
    ###　问题1:
        




```
```
## 不足

- 贴花上限固定 `MaxDecals = 10`，队列满时直接驱逐最旧实例，没有按距离或屏幕占比取舍；连射时最早的火花痕迹会提前消失。
- 贴花按全屏包围盒逐像素绘制，命中点靠近相机时开销与命中面在屏幕上的实际占比无关，缺少屏幕占比裁剪或遮挡剔除。
- 准星红点在 `LateUpdate` 里每帧做一次 `RaycastAll` 并全量排序，属于每帧固定开销，未做降频或对静态物体分帧检测。
- 玩法规格只到"命中点 + 视觉反馈"：没有伤害、弹药、后坐力、音效与换弹；血量链路是空转的——`UIFun.UpdateHealth` 由 `Player.NotifyUpdateHealth` 转发，而 `NotifyUpdateHealth` 没有任何调用方。
- 对于模型,除了AK模型为全手动建,其余场景模型均是通过AI,资源寻得,在高模进行处理时,出现一些偏差,导致美术效果下降
```
