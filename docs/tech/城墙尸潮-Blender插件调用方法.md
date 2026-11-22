# 《城墙尸潮》Blender 插件调用方法

> 实测日期 **2026-11-17** ｜ workspace `D:\TAPTAP\G-A` ｜ 插件 `dsh-blender 0.2.4` ｜ Blender **5.3.0** ｜ Godot **4.7.2**
> 读者：在本项目里要做 3D 低模资产（`待办清单-2026-11-08.md` 的 **P0-1**）的人或 Agent。
> 定位：只讲「怎么调用、调完怎么验收、本项目必须守什么规矩」，不重复美术风格与玩法设计。

---

## 0. 一页纸结论

调用分三层，**先选层，再动手**：

| 层 | 入口 | 适合 | 不适合 |
|---|---|---|---|
| **L1 插件工具**（13 个） | 会话内直接调 `blender_*` 工具 | 单个资产：建模 → 预览 → 审计 → 导出 → 回读，全程可回读、可验收 | 需要连续交互/大规模程序化生成 |
| **L2 Helper**（26 个，当前 23 个可用） | `blender_helper_catalog` 查参数 → `blender_helper_run` 执行 | 参考图量测、剪影/多视图拟合、UV/贴图覆盖、动画接触表等**确定性验收** | 创造性建模本身 |
| **L3 原生 blender.exe** | shell 里 `blender.exe --background ... --python xxx.py` | 项目已有的**地形生成器**这类一次跑完的大批量几何 | 需要插件审计/版本化 `.blend` 产物时（要自己补） |

三条铁律（违反时工具会直接报错，不是建议）：

1. **所有输入/输出路径必须在本 workspace（`D:\TAPTAP\G-A`）内**；相对路径按 workspace 解析。
2. **默认拒绝覆盖**：`save_path` / `output_path` / `out_*` 已存在就报 `already exists; choose a versioned path or set allow_overwrite=true`。资产一律版本化 `_v001`、`_v002`。
3. **插件每次调用都是新开一个 Blender 后台进程**，不保留会话状态；跨调用的状态只能通过 `.blend` 文件传递。

当前环境实测：`blender_status` → `available: true`，Blender `G:\SteamLibrary\steamapps\common\Blender\blender.exe` 5.3.0；图像分析 Python 可用（cv2 4.14.0 / numpy 2.4.6 / pillow 12.3.0 / scipy 1.17.1）；注册 Skill 30 个，可执行 Helper 23 个。

---

## 1. 环境与配置（已核实，不用再猜）

### 1.1 实际生效的配置

| 项 | 值 | 来源 |
|---|---|---|
| 插件安装目录 | `<profile>/node_modules/dsh-blender` | profile 的 node_modules |
| 生效配置 | `<profile>/cordis.patch.yml` | profile patch 层（会覆盖插件自带 `cordis.patch.yml`） |
| Blender 可执行 | `G:\SteamLibrary\steamapps\common\Blender\blender.exe` | 同上 `blenderExecutable` |
| 分析 Python | 插件目录下 `.venv\Scripts\python.exe`（Python 3.11.6） | `analysisPythonExecutable: ''` 时自动回落到包内 venv |
| 单次超时 | Blender 调用 **180 s**；Helper **120 s** | `timeoutMs` / `helperTimeoutMs` |
| 输出截断 | 20,000 字符 | `maxOutputChars` |
| Python 执行 | 开 | `enablePython: true` |
| Helper | 开（维护类关） | `enableHelpers: true` / `enableMaintenanceHelpers: false` |
| 路径限制 | 开 | `restrictToWorkspace: true` |

要改配置就改 profile 的 `cordis.patch.yml` 再重启 DSH；**不要改插件目录里的同名文件**（会被 profile 键覆盖，且升级会丢）。

### 1.2 每次工具调用实际发生了什么（读插件源码得到，排查问题用）

无输入 `.blend` 时（`index.js:494-505`）：

```
blender --background --factory-startup --disable-autoexec --python-exit-code 1 \
        --python <插件>/scripts/dsh_blender_driver.py -- \
        --operation <op> --payload <tmp>/payload.json --result <tmp>/result.json
```

有输入 `.blend` 时把 `--factory-startup` 换成 `<input.blend>`（即先打开该文件再跑 driver）。Blender 侧 driver 执行完把 JSON 写进 `result.json`，Node 侧读回并清理临时文件；**exit code 非 0 或 `result.json` 缺失 = 该次调用失败，没有产出**。

由此推出排错要点：报错信息里的 Blender traceback 就是真实原因；超时 180 s 说明这次 Python 太重（拆小段）；中文/长输出被截断时看 `maxOutputChars`。

---

## 2. L1：13 个 Blender 工具的调用方法

### 2.1 推荐顺序（单资产闭环）

```
blender_status                      # 确认 backend 在线（每个任务第一次）
   ↓ 已有资产要改？
blender_scene_info / blender_object_info        # 先只读，别急着写
   ↓ 外部格式（GLB/FBX/OBJ/STL/USD/PLY/DAE）
blender_import                      # 导入干净场景 → 版本化 .blend
   ↓ 建模/改材质/打灯/设相机
blender_python                      # 小步、幂等、每次存新版本 .blend
   ↓
blender_validate_scene              # 结构审计（general / web / 3d-print / animation）
blender_preview 或 blender_render   # 出图 → read_image 真看
   ↓ 通过后
blender_export                      # .glb（默认）/ .fbx / .obj / .stl / .usd / .ply
blender_validate_export             # 干净进程回读 + 目标档位校验
```

### 2.2 工具清单与关键参数

| 工具 | 必填 | 主要可选 | 产出 | 备注 |
|---|---|---|---|---|
| `blender_status` | — | — | 环境报告 | `available:false` 就别往下走 |
| `blender_scene_info` | `blend_path` | `max_objects`(200) | 场景/对象摘要 | 只读 |
| `blender_object_info` | `blend_path` | `object_names[]`、`evaluated`(true) | 包围盒/拓扑/UV/材质/修改器/形态键/动画 | 不传 `object_names` 查 active |
| `blender_import` | `source_path`、`save_path` | `allow_overwrite` | 新 `.blend` | 净场景导入 |
| `blender_python` | `script`、`save_path` | `blend_path`、`allow_overwrite` | 新 `.blend` + `dsh_result` | 脚本内可用 `bpy / bmesh / mathutils / workspace / input_path / output_path`，把要回传的 JSON 塞进 `dsh_result` |
| `blender_preview` | `blend_path`、`output_path` | `view`(isometric/front/back/left/right/top/bottom)、`object_names[]`、`orthographic`、`focal_length`、`width/height`(768)、`samples`(32)、`transparent`、`allow_overwrite` | PNG/JPEG | **临时相机+三点灯，不改源文件** |
| `blender_render` | `blend_path`、`output_path` | `camera`、`frame`、`width/height`、`samples`(64)、`transparent`、`allow_overwrite` | PNG/JPEG | 用场景里作者相机 |
| `blender_render_frames` | `blend_path`、`output_dir` | `frames[]` 或 `start/end/step`、`camera`、`prefix`、`format`、`width/height`、`samples`、`transparent`、`allow_overwrite` | 序列帧 | 动画 QA 用 |
| `blender_export` | `blend_path`、`output_path` | `selection_only`、`allow_overwrite` | 模型文件 | 格式按扩展名选；见 §2.4 |
| `blender_validate_scene` | `blend_path` | `object_names[]`、`profile`(general/web/3d-print/animation) | 审计报告 | 导出前跑 |
| `blender_validate_export` | `model_path` | `profile`、`object_names[]` | 回读审计 | 交付前必跑，**不看字节数** |
| `blender_helper_catalog` | — | `module`、`include_maintenance` | Helper 清单+精确参数 | 先查再跑 |
| `blender_helper_run` | `helper`、`arguments` | `blend_path`(Blender 类 Helper 必填)、`allow_overwrite` | 报告/图/配方 | 见 §3 |

### 2.3 本次真实调用记录（可直接照抄）

```text
blender_status()                                    → available:true, Blender 5.3.0, helpers:23, skills:30
blender_scene_info(blend_path="art/blender-demo/citywall_merlon_v001.blend")
    → 5 objects / materials [Ground, MossStone, Stone] / Merlon dims 1.095×1.095×1.3 / Bevel modifier 存在
blender_preview(blend_path="art/blender-demo/citywall_merlon_v001.blend",
                output_path="art/review/blender-plugin-call-demo/v001_iso.png",
                view="isometric", width=640, height=480, samples=16)
    → 285,359 B / bounds [-6,-6,0]..[6,6,1.3]；调 read_image 实看：地面 + 垛口块，无破面
```

证据图：`art/review/blender-plugin-call-demo/v001_iso.png`（`art/review` 有 `.gdignore`，不会进 Godot 资源树）。

### 2.4 参数语义 + 本项目踩过的坑

1. **`selection_only` 依赖 `.blend` 里已保存的选择状态**（driver 直接传 `use_selection=selected`）。要「只导几个对象」，先在 `blender_python` 里把选择设好并保存，再导出。
2. **`blender_export` 不会自动应用修改器**。本次实测：源 `.blend` 的 Merlon 带 `Bevel`，导出 GLB 仍是 **12 tris 的原始立方体**（`art/review/blender-plugin-call-demo/merlon_export_probe_v001.glb`）。低模资产大量用 Bevel / Mirror / Subdivision，**导出前必须在 `blender_python` 里 `modifier_apply`（或复制求值网格）并另存版本化 `.blend`**，否则 Godot 里没有倒角、没有镜像、面数对不上预算。
3. glTF 导出**不含相机与灯光**（本次导出 nodes 只有 3 个 mesh），所以 `strip_for_export.py` 的剥离动作对 GLB 不是必须；但源文件整洁、面数审计仍建议剥。
4. `blender_python` 每次是**全新命名空间**：重新 `import`，按稳定对象名取数据，不要指望上次的变量。
5. `save_path` 与输入 `blend_path` 相同会被拒：`Refusing to overwrite the input .blend; choose a versioned save_path`。
6. 渲染只是 QA，不替代模型；**每次渲染完都要 `read_image` 真看**，「文件存在」不算验收。

---

## 3. L2：26 个 Helper 的调用方法

### 3.1 两步流程

```text
blender_helper_catalog(module?="atlas-uv-fitting")
   → 拿到 helper 名、runtime(python|blender)、依赖、arguments[].name/type/pathKind/required/choices
blender_helper_run(helper="atlas-region-detector",
                   arguments={...},            # 键名必须与 catalog 完全一致
                   blend_path=...)             # runtime=blender 时必须给
```

- `pathKind` 决定路径校验：`input-file` 必须存在；`output-file` / `output-dir` 默认不能已存在（`allow_overwrite` 才覆盖）。
- Helper 产出物（`outputs[]`）与解析后的 JSON `report` 会一并在返回值里；**别只看 metrics，掩膜/叠加图/接触表要用 `read_image` 看**。

### 3.2 当前 23 个可用 Helper（按用途）

| 用途 | Helper |
|---|---|
| 参考图量测 / 外观 | `reference-manifest-compiler`、`render-overlay-validator`、`silhouette-validator`、`template-analyzer`、`look-fit-report` |
| 多视图 / 正交配准 | `multiview-fit-report`、`view-constraint-report`、`register-orthographic-views`、`landmark-fit-report` |
| 线框 / 轮廓 / 部件分段 | `wireframe-analyzer`、`mask-to-mesh-recipe`、`source-locked-skin-recipe`、`segment-source-parts`、`seeded-part-masks` |
| UV / 贴图覆盖 | `atlas-region-detector`、`atlas-region-mapper`、`surface-texture-coverage-audit`、`contour-correspondence-report`、`texture-transition-plan` |
| 动画 QA | `animation-contact-sheet` |
| 修复 / HUD 布局 | `fit-repair-queue`、`quality-refinement-plan`、`orbit-layout-manifest` |

维护类另外 3 个默认被 `enableMaintenanceHelpers:false` 挡住，做资产时用不到。

### 3.3 本项目最可能用到的 4 个

| 场景 | 调用 | 产出用途 |
|---|---|---|
| 拿 `art/concept/**` 基准图量尺寸、数部件 | `reference-manifest-compiler(inputs=[...], out=..., mode="auto")` | bbox/质心/连通域 → 建模前的硬约束 |
| 渲染图 vs 基准图剪影比对 | `silhouette-validator(reference=..., render=..., out=...)` | IoU/像素误差，判断「像不像」 |
| 看外观（明度/饱和度/主色）是否对 | `look-fit-report(reference=..., product=..., out=...)` | 本项目要求主体/背景灰度差 ≥30（`城墙尸潮-美术风格提案.md:371-372`） |
| 动画序列帧看跳变 | `animation-contact-sheet(frames=[...], out_image=..., out_report=...)` | 逐帧抽样 + 帧间跳变标记 |

Helper 是**确定性脚本**，同一输入同一输出，适合把「老板说不好看」变成可复跑的数字；但仍必须配 `read_image` 人眼判读（地形 v006 的教训：量化全过、肉眼是靶心，见 `城墙尸潮-地形接入说明.md:30-31`）。

---

## 4. L3：原生 `blender.exe` 调用（项目已有，继续用）

### 4.1 地形生成器的调用式（唯一成文写法）

```powershell
G:\SteamLibrary\steamapps\common\Blender\blender.exe --background --factory-startup `
  --disable-autoexec -noaudio --python generate_terrain.py -- `
  --out D:/TAPTAP/G-A/art/blender-work/terrain/terrain_next.blend `
  --size 480 --seed 7 --cell 1.6
```

拆解：

| 参数 | 作用 |
|---|---|
| `--background` | 不弹 GUI，headless |
| `--factory-startup` | 忽略用户偏好/插件，保证可复现 |
| `--disable-autoexec` | 禁用 `.blend` 内嵌脚本自动执行（安全，和插件一致） |
| `-noaudio` | 无音频设备也能跑 |
| `--python <脚本>` | 跑脚本 |
| `--` 之后 | **原样传给脚本**，由脚本自己解析 |

项目脚本只解 `--` 之后的 argv：`art/blender-work/terrain/generate_terrain.py:56-76`（`--out/--size/--seed/--cell`），`art/assets/models/terrain/generate_terrain.py` 同构（783 行，正式版）。

### 4.2 项目内的两份生成器（别拿错）

| 文件 | 状态 | 参数口径 |
|---|---|---|
| `art/assets/models/terrain/generate_terrain.py`（783 行） | **正式版**，产出当前在用的地图 | `map_size 320 / cell 1.6 / chunks 5 / seed 20261115 / jitter 0.35`（`L27-35`） |
| `art/blender-work/terrain/generate_terrain.py`（545 行） | 早期版（v006 时期，参数已分叉） | `cell 2.5 / chunks 4 / jitter 0.95` |

输出：写 `<out>.heights.json` → `bpy.ops.wm.save_as_mainfile` → stdout 打印 `TERRAIN_SUMMARY {json}`。**生成器本身不导 GLB**（全工程搜不到 `export_scene.gltf`），GLB 是外部导出的（当前 GLB 的 `generator` 字段为 `Khronos glTF Blender I/O v5.3.43`）。

### 4.3 GLB 怎么出：两条路

1. **推荐给新资产**：`blender_export`（L1）。先在 `blender_python` 里应用修改器、清理对象，另存 `_export.blend`，再导出；最后 `blender_validate_export` 回读。
2. **地形这类大资产**：沿用 `art/blender-work/terrain/strip_for_export.py`（删相机/灯、只留 MESH、原地保存）+ Blender GUI 导出，或自己写 `export_scene.gltf`。若改用 `blender_export`，注意它只传 `export_format` + `use_selection`，**不会应用修改器/不传精细导出参数**。

### 4.4 GUI 侧脚本

`watch_build_gui.py` 是在 Blender **GUI 的 Scripting 面板** 里 Run Script 看地形分层长出来的教学脚本，**不能加 `--background`**（`:6-17`）。它不产出运行时资产。

---

## 5. 本项目资产规范（调用时必须遵守）

### 5.1 命名（四段式）

`<prefix>_<object>_<variant>_v<N>.<ext>`，前缀白名单 `char/mon/env/ui/icon/fx/anim/mdl/tex/font/img`，3D 模型用 `mdl_`：

```
mdl_wall_segment_a_v1.glb      mdl_mon_walker_normal_v1.glb      tex_mon_infected_atlas_v1.png
```

禁：中文名、空格、`最终版`、`未命名`、`@v2`（统一 `_vN`）。见 `城墙尸潮-美术资产清单.md:18-34`。
现状 `terrain_map_v001.glb` **不合规**（缺 `<variant>`、前缀不是 `mdl`）；新资产别再沿用这个风格。

### 5.2 面数 / 贴图预算（清单原文）

| 资产 | tris | 贴图 |
|---|---|---|
| 玩家 `mdl_char_hero_normal_v1` | 3.5k–5k | 1024² albedo + 512² ORM，单级 0.02 m 倒角 |
| walker / runner | 1.2k–2k / 1.2k–1.8k | 五只感染者共用 2048² 图集 |
| bomber | 1.8k | 同上 |
| brute / boss | 4k–6k / 12k–18k | boss 独立 2048² |
| 城墙单段 `mdl_wall_segment_a_v1` | 1.5k/段，7 段复用 + 2 变体 | — |
| 水晶 `mdl_crystal_core_v1` | 2k（自发光芯片） | — |
| 火盆 / 木箱 | 800 / 600 | — |

依据：`城墙尸潮-美术资产清单.md:57-110`、`城墙尸潮-美术风格提案.md:70`。**低于预算不是优点，是浪费辨识度；高于预算要在文档里写理由。**

### 5.3 单位、原点、轴向

- 单位 **米**（Blender METRIC、unit_scale 1；Godot 1 unit = 1 m）。先读 `view/unit_layer.gd:43-46` 现有 Capsule/Box 尺寸定体型，别凭空编身高。
- Blender Z-up → glTF/Godot Y-up：`x = gx`、`y = height`、`z = -gy`（`城墙尸潮-地形接入说明.md:88-95`）。**朝向要按这条换算**，否则模型进 Godot 会镜像。
- 场景锚点：原点 = 水晶位置、y=0 = 逻辑地面；地形可玩区 r≤84 m 内绝对 y=0（`:57-62`）。静态道具自己带好世界原点，**不要指望 Godot 侧平移/缩放补**（弩模型是 `WEAPON_SCALE 0.55` 这类特例，见 `view/unit_layer.gd:20`）。

### 5.4 材质口径

低模平色资产只用 glTF `baseColorFactor`（线性空间），`roughness 0.80–0.95`、`metallic 0`、无贴图（现有地形 GLB 即此口径，材质 15 个）。要贴图再走 `blender-uv-texturing` / `atlas-uv-fitting`，并注意 Godot 侧导入参数（下节）。

### 5.4.1 现有地形 GLB 的实测值（写文档/验收时以此为准）

| 项 | 实测（本次解析 `art/assets/models/terrain/terrain_map_v001.glb`） | 旧文档写法 |
|---|---|---|
| 文件 | 7,342,396 B | 7.7 MB |
| nodes / meshes | 30 / 30 | 29 |
| materials | 15 | 13 |
| primitives / tris | 104 / **98,318** | 95,002 |
| images | 0 | 无贴图 ✅ |
| 顶点属性 | `POSITION`、`NORMAL`、**`TEXCOORD_0` 存在** | §4.3「已生成 XZ 投影 UV」**成立** |

> 结论：地形确有 UV（生成器 `generate_terrain.py:427-431` 按 `uv=(vx/9, vy/9)` 做 XZ 投影，即每 9 m 一张），可直接挂 `albedo_texture`；但节点/材质/面数三个数字已漂移，引用时用上表。

### 5.5 目录与 `.gdignore` 规则（Godot 会吃 `.blend`，必须守）

| 目录 | 内容 | 规则 |
|---|---|---|
| `art/assets/models/<category>/` | **只放运行时资产**：`.glb` + `.glb.import`（+ 高度场等数据） | 不能放 `.blend`、`.py`（terrain 目录现有 `.py` 是历史遗留） |
| `art/blender-work/<category>/` | `.blend` 源、生成脚本、渲染图 | 已有 `.gdignore`，**必须保持** |
| `art/blender-demo/` | 学习/样例资产 | 已有 `.gdignore` |
| `art/concept/`、`art/raw/`、`art/review/`、`art/trash/`、`shots/` | 参考/中间/评审/截图 | 均带 `.gdignore` |

`.blend` 一旦落进 `res://`，Godot 会当场景导入（`.godot/imported` 里至今残留 `terrain_map_v001–v016` 的 `.scn` 缓存）；改 `.blend` 后要清缓存再 `--import`。

### 5.6 Godot 侧导入与验收命令

```powershell
$GODOT = "D:/GODOT/Godot_v4.7.2-stable_win64_console.exe"

# 1) 新 class_name / 新资产后先重扫导入（否则找不到资源/类型）
& $GODOT --headless --import --path .

# 2) 无脚本错误
& $GODOT --headless --path . --quit-after 60 2>&1 | Select-String "SCRIPT ERROR|Parse Error"

# 3) 画面验证（headless 不画图，必须窗口渲染）
& $GODOT --path . --script res://tests/visual_capture.gd
```

`.glb` 的导入口径（两份现有 `.glb.import` 一致）：`importer="scene"`（所以代码必须 `load() as PackedScene`）、`ensure_tangents=true`、`generate_lods=true`、`create_shadow_meshes=true`、材质内嵌不抽取。项目级无任何 glTF 全局设置。

接入代码模式（照现有两处抄，不要发明新加载层）：

```gdscript
# 常量 + 存在性检查 + 缺失降级（view/world_builder.gd:30-32, 83-86, 99-107）
const MODEL := "res://art/assets/models/<category>/mdl_xxx_v1.glb"
func _try_add() -> bool:
    var packed := load(MODEL) as PackedScene
    if packed == null:
        push_warning("模型缺失，回退程序化几何")
        return false
    add_child(packed.instantiate())
    return true
```

---

## 6. 最短路径：从基准图到可接入 GLB（P0-1 实操）

以「城墙单段 `mdl_wall_segment_a_v1`（1.5k tris）」为例，其他资产同构。

**Step 0 建目录、选源文件**

```text
art/blender-work/wall/          # 源 .blend + 脚本（已在 .gdignore 内）
art/assets/models/wall/         # 只放 mdl_wall_segment_a_v1.glb + .import
基准图：art/concept/env/concept_env_wall_rampart_normal_v2.png（先 read_image 看）
```

现有基准图 → 目标资产名对照（P0 缺口，都在 `art/concept/` 下）：

| 基准图 | 目标模型 | 预算 |
|---|---|---|
| `char/concept_char_hero_normal_v4.png` | `mdl_char_hero_normal_v1.glb` | 3.5k–5k tris |
| `mon/concept_mon_walker_normal_v1.png` | `mdl_mon_walker_normal_v1.glb` | 1.2k–2k |
| `mon/concept_mon_runner_normal_v1.png` | `mdl_mon_runner_normal_v1.glb` | 1.2k–1.8k |
| `mon/concept_mon_bomber_normal_v2.png` | `mdl_mon_bomber_normal_v1.glb` | 1.8k |
| `mon/concept_mon_brute_normal_v2.png` | `mdl_mon_brute_normal_v1.glb` | 4k–6k |
| `mon/concept_mon_boss_normal_v2.png` | `mdl_mon_boss_normal_v1.glb` | 12k–18k（P1） |
| `env/concept_env_wall_rampart_normal_v2.png` | `mdl_wall_segment_a_v1.glb` | 1.5k/段 |
| `env/concept_env_crystal_core_v1.png` | `mdl_crystal_core_v1.glb` | 2k |
| `env/concept_env_brazier_normal_v1.png` | `env_brazier_normal_v1.glb` | 800 |
| `prop/concept_loot_box_{wood,metal,military}_v1.png` | `mdl_loot_box_{wood,metal,military}_v1.glb` | 600/800/900 |

**Step 1 量参考图（可选但推荐）**

`blender_helper_run("reference-manifest-compiler", {inputs:["art/concept/env/<基准图>.png"], out:"art/review/wall/manifest_v001.json", mode:"auto"})` → 拿 bbox/部件数/质心当硬约束。

**Step 2 粗模（blockout）**

`blender_python`（不传 `blend_path`，从空场景开始；`save_path="art/blender-work/wall/mdl_wall_segment_a_v001.blend"`）
脚本内：命名 `GEO-Wall_Segment`、按基准图比例建体块、`dsh_result={"objects":[...],"dims":[...]}` 回传播出证据。

**Step 3 看粗模**

`blender_preview(blend_path=..., output_path="art/review/wall/v001_iso.png", view="isometric")` → `read_image` 检查比例/朝向/轮廓；再补 `view="front"`、`"top"` 对照基准图视角。

**Step 4 结构审计**

`blender_validate_scene(blend_path=..., profile="web")`：看非流形、孤立点、UV、材质、变换是否干净。

**Step 5 细化 + 材质 + 应用修改器（关键）**

`blender_python(blend_path=".../v001.blend", save_path=".../v002.blend", script=...)`：
加 Bevel（0.02 m 单级）+ 瓦片/破损细节 → **`modifier_apply` 全部修改器** → 赋 PBR 平色材质（roughness 0.9 / metallic 0）→ 保存。回传实际 tris 数，对照 1.5k 预算。

**Step 6 出图验收**

`blender_render(blend_path=".../v002.blend", output_path="art/review/wall/v002_iso.png", samples=64)` → `read_image`；
外观不对再 `blender_helper_run("look-fit-report", {reference:基准图, product:渲染图, ...})` 量化，改最小上游原因，重出同视角对比。

**Step 7 导出 + 回读**

```text
blender_export(blend_path=".../v002.blend", output_path="art/assets/models/wall/mdl_wall_segment_a_v1.glb")
blender_validate_export(model_path="art/assets/models/wall/mdl_wall_segment_a_v1.glb", profile="web")
```

**Step 8 Godot 导入 + 实机截图**

按 §5.6 三条命令跑；`view/` 里按 §5.6 代码模式加载；`tests/visual_capture.gd` 出 `shots/_shot_*.png` 后 `read_image` 确认。

**Step 9 记录**

在 `城墙尸潮-美术资产清单.md` 对应行改状态，并在 `art/logs/` 落一份验收记录（几何/面数/材质/渲染图/回读结果），否则下一轮又要重测。

---

## 7. 排错表

| 症状 | 原因 | 处理 |
|---|---|---|
| `blender_status.available=false` | 可执行路径错/被移动 | 改 profile `cordis.patch.yml` 的 `blenderExecutable` 后重启 |
| `analysis.available=false` | venv 缺依赖 | 插件目录跑 `pnpm setup:analysis`，或把 `analysisPythonExecutable` 指向有 cv2/numpy/PIL/scipy 的 Python |
| `... already exists; choose a versioned path or set allow_overwrite=true` | 默认不覆盖 | 换 `_v002` 路径；确实要覆盖才传 `allow_overwrite=true` |
| `Refusing to overwrite the input .blend` | save_path == blend_path | 另存新版本 |
| 路径相关报错 | 越出 workspace / 未解析的软链 | 全部路径用 workspace 相对或绝对；别指到 `<user-home>` |
| `Blender timed out after 180000 ms` | 单次脚本太重（百万面/批量渲染） | 拆小段；大批量走 L3 shell + 更长超时 |
| `Blender produced no valid driver result` | Blender 崩了/脚本语法错 | 看返回的 stdout/stderr（含 traceback） |
| GLB 里没有倒角/镜像 | 导出不应用修改器 | 导出前 `modifier_apply`（§2.4-2） |
| Godot 报「无法加载 PackedScene」 | 导入未跑/`.import` 缺失 | `--headless --import --path .`，保留 `.glb.import` 入库 |
| Godot 把 `.blend` 当场景导入 | `.blend` 进了 `res://` | 移出到 `art/blender-work/`，保留 `.gdignore`，清缓存重导入 |
| 渲染图全黑/空 | 场景无相机且用了 `blender_render` | 用 `blender_preview`，或在 `blender_python` 里建相机 |
| 中文输出乱码 | Windows 控制台编码 | 插件已 `-X utf8`（分析 Python）/Blender UTF-8；文件路径仍避免中文 |

---

## 附录 A：30 个 Skill 的加载时机

`create-3d-model` 是总编排（先读它），其余 29 个按需用 `skill` 工具加载，**别一次全读**。

| 阶段 | Skill |
|---|---|
| 建模 | `blender-modeling`、`blender-materials`、`blender-uv-texturing` |
| 参考图/线框重建 | `reference-to-3d`、`wireframe-to-3d`、`contour-to-mesh`、`orthographic-registration`、`source-part-segmentation`、`multiview-constraint-solver`、`multiview-fit-loop`、`landmark-fit-repair`、`texture-driven-mesh-fitting`、`closed-surface-uv-coverage`、`atlas-uv-fitting`、`mascot-logo-reconstruction`（本项目暂不需要） |
| 相机/灯光/渲染 | `blender-cameras`、`blender-lighting`、`blender-rendering` |
| 动画 | `blender-animation`、`texture-state-animation`、`animation-quality-gate`、`orbital-hud-motion` |
| 验收/修复 | `reference-analysis-validator`、`reference-look-calibration`、`fit-repair-optimizer`、`quality-refinement-autoloop`、`blender-skill-harmonizer`、`blender-pro-workflow` |
| 导出 | `blender-export` |

## 附录 B：可直接复制的调用卡

```text
# 环境
blender_status()

# 只读检查
blender_scene_info(blend_path="art/blender-work/wall/mdl_wall_segment_a_v002.blend")
blender_object_info(blend_path="...", object_names=["GEO-Wall_Segment"])

# 建/改（小步、版本化）
blender_python(blend_path=".../v001.blend", save_path=".../v002.blend", script="...bpy...")

# 看图
blender_preview(blend_path=".../v002.blend", output_path="art/review/wall/v002_iso.png", view="isometric")
blender_render(blend_path=".../v002.blend", output_path="art/review/wall/v002_beauty.png", samples=64)
# → 之后必须 read_image

# 审计/导出/回读
blender_validate_scene(blend_path=".../v002.blend", profile="web")
blender_export(blend_path=".../v002.blend", output_path="art/assets/models/wall/mdl_wall_segment_a_v1.glb")
blender_validate_export(model_path="art/assets/models/wall/mdl_wall_segment_a_v1.glb", profile="web")

# Helper
blender_helper_catalog(module="reference-to-3d")
blender_helper_run(helper="silhouette-validator",
                   arguments={reference:"art/concept/...", render:"art/review/...", out:"art/review/wall/sil_v001.json"})
```

---

## 附：一句话交接

> 插件已经就绪、路径和超时都配好了；**建模调用走 L1 工具，验收看渲染图 + validate 报告，导出前务必应用修改器**；资产落 `art/assets/models/<category>/`（只放 GLB），源文件落 `art/blender-work/<category>/`；命名按 `mdl_<对象>_<变体>_v<N>.glb`，面数按清单表，最后用 Godot `--import` + `visual_capture` 做实机验收。