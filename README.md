# GunWar

项目简介：基于团结引擎（Tuanjie 1.10.3，对应 Unity 2022.3.62t15）与 URP 14.2.0-t1 的第一人称射击 Demo，场景是一条室内赛博朋克窄街。玩家持 AK 移动、跳跃、开火，命中面会留下带碳化与余烬两段效果的枪击贴花。

### C#逻辑:`Assets/Code`
### 工具脚本:`Assets/Editor`
### 渲染资产: `Assets/MatShader`

## 一、项目概览

| 项目 | 说明 |
| --- | --- |
| 引擎 | 团结引擎 Tuanjie 1.10.3（Editor 2022.3.62t15） |
| 核心依赖 | URP 14.2.0-t1（Forward + Volume 后处理）、uGUI 1.0.0、TextMeshPro 3.0.9、Timeline 1.8.9-t1；未引入第三方包 |
| 交付形态 | https://github.com/lyhbk/FPS-Rendering/release 中,下载Demo.zip,解压后点击exe可执行程序打开  |

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


射速靠"最后开火时间 + 固定间隔"实现，而不是协程或计时器

### 贴花：数据与绘制彻底分开

贴花没有用 URP 自带的 Decal Projector，因为需要"每个贴花独立计时淡出 + 数量硬上限 + 一次 draw call 画完"。

| 脚本 | 职责 | 关键数值 |
| --- | --- | --- |
| `DecalProjector` | 纯数据：盒尺寸、坐标矩阵、生命周期，自行 Tick | `lifeTime = 8s`，`fadeTime = 2s` |
| `DecalManager` | 每个 `Update` 遍历活跃贴花，到期注销并按其 `sourcePrefab` 归还池 | 无固定容量 |
| `DecalRenderFeature` | 每帧把活跃贴花打包成结构化缓冲，一次 `DrawProcedural` 绘制 | `MaxDecals = 10`，每个实例 160 字节 |

绘制用 `DrawProcedural` 而不是实例化 Mesh：每个贴花只占 6 个顶点（屏幕矩形两个三角形），顶点索引由 `vertexID` 推出来，`MaxDecals = 10` 时总共 60 个顶点，CPU 侧只做一次 buffer 上传与一次提交。


### 贴花着色：屏幕包围盒 → 深度重建 → 盒体裁剪

每个贴花的片元计算是一条固定管线：

1. 顶点阶段把盒体 8 个角变换到裁剪空间，取 NDC 的 min/max 得到屏幕矩形；边缘再外扩 4 像素（`4.0 / _ScaledScreenParams.xy`），防止恰好落在边界的像素被光栅化裁掉。
2. 片元阶段用屏幕 UV 采样 `_CameraDepthTexture`，`LinearEyeDepth` 还原眼空间深度，再经逆投影 + 逆视图矩阵得到世界坐标。
3. 世界坐标乘 `worldToBox` 进入贴花盒局部空间，`boxMask` 判断是否落在盒内；盒外直接 `clip`。
4. 盒内按局部坐标算碳化强度与到边缘的距离，分别喂给两个 Pass。

无深度的情况必须回退：命中面不写深度时，该像素深度恒为远平面，重建点会落到几百米外，被盒体裁剪掉，整片贴花消失。回退做法是用屏幕 UV 从相机反投影出一条视线，与盒中心平面（局部 z = 0）求交。这里不能用"盒体进入点"——进入点落在盒边界上，`boxMask` 在那里恰好为 0，整片贴花会被裁掉；中心平面交点处 z 恒为 0，`boxMask.z` 稳定为 1。视线几乎平行于平面或平面落在相机后方时返回盒外坐标，交给 `boxMask` 处理。

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
            问题描述:初始方案是模型下有个空物体同时带有Collider 与 Renderer,这样即可以满足物理引擎(子弹命中),又可以进行贴花渲染(写入深度),但是在测试上产生了抖动
            问题原因:为什么均有子物体携带:这是因为模型由网上资源获取,在模型进行高模向低模处理时,面未处理好,导致碰撞体模型计算开销增长,所以改为由子物体带有box collider
                    这样做的后果:父子层级两层网格在视觉上重叠，引发了 Z-fighting
            解决方法:将Renderer去掉,仅保留Collider,当子弹命中Collider时,将参数(位置,法线)传递给贴花,并在此重建深度(当前方法)
            方案代价:贴花会出现穿透以及悬空.对于美术与Collider两套资产的维护困难上升
            其他方案:1.修复模型,将Collider 与 Renderer直接有模型本身携带,而不是有子物体代理
                     2.去除父物体的Renderer,保留子物体

   ### 问题2:
            问题描述:调整RenderScale时贴花整体偏移
            问题原因:_ScreenParams 是全屏尺寸，_ScaledScreenParams 是全屏 × renderScale。 而相机的 RT、_CameraDepthTexture 的实际尺寸是后者,
                     所有 UV 被系统性地压缩了 scale 倍
            解决方法:将GetNormalizedScreenSpaceUV`改为`_ScaledScreenParams`,让 UV 归一化彻底脱离分辨率，而不是换一个分辨率常量。
            方案代价:坐标链长（裁剪→UV→深度→反投影），每一环都可能出错,且受renderScale影响
            其他方案:1.使用URP 原生 Decal Projector
                     2.全屏贴花改为后处理模式
                     3.RT 烘焙方式


```

```
   ### 性能提升
            提升1:原本贴花需要全屏三角片元跑遍全屏再被 boxMask clip，成本 = N × 全屏像素 × 2 Pass，与贴花实际投影面积无关。
                  现在:顶点阶段把贴花盒 8 角投到 NDC 取屏幕包围盒，每个片元只画包围盒矩形内部
            提升2:原本多个贴花会产生多次drawcall,多次绘制
                  现在:将贴花盒的定点数据收集,在绘制时通过一次统一提交drawcall进行绘制
            提升3:原本不对贴花做出任何限制,仅对开枪做出0.2s的限制,导致贴花50个左右性能极速下降
                  现在:对贴花数做出上限(通过常数控制,当前为8),并且对贴花根据数量做出降级
                        当贴花数>2时,FBM 噪声由4层降为2层,并且余烬pass不进行绘制,N>4降为1层
      

```
```
## 不足

- 贴花上限固定 `MaxDecals = 10`，队列满时直接驱逐最旧实例，没有按距离或屏幕占比取舍；连射时最早的火花痕迹会提前消失。
- 贴花按全屏包围盒逐像素绘制，命中点靠近相机时开销与命中面在屏幕上的实际占比无关，缺少屏幕占比裁剪或遮挡剔除。
- 准星红点在 `LateUpdate` 里每帧做一次 `RaycastAll` 并全量排序，属于每帧固定开销，未做降频或对静态物体分帧检测。
- 玩法规格只到"命中点 + 视觉反馈"：没有伤害、弹药、后坐力、音效与换弹；血量链路是空转的——`UIFun.UpdateHealth` 由 `Player.NotifyUpdateHealth` 转发，而 `NotifyUpdateHealth` 没有任何调用方。
- 对于模型,除了AK模型为全手动建,其余场景模型均是通过AI,资源寻得,在高模进行处理时,出现一些偏差,导致美术效果下降
```
