# 城墙尸潮 G-A

2.5D 城墙守波（Tower-Defense × 射击）Godot 4.7 工程，v2.0 重构版。

玩家驻守一段可自由加建的城墙，在「搜集 → 建设 → 备战 → 守波」四阶段循环中抵御五波尸潮。
逻辑层完全无头可运行，渲染层与逻辑层通过 EventBus 解耦便于回归测试。

---

## 快速开始

### 环境要求

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| Godot | 4.7.2 stable | 标准版（非 .NET），需含 Windows 导出模板 |
| Python | 3.10+ | 仅美术/数值工具链需要，可选 |
| Pillow | 12.x | `tools/` 下图像脚本依赖，可选 |

### 运行

```bash
# 用编辑器打开工程（首次会自动导入，生成 .godot/ 缓存）
godot --path . -e

# 直接运行游戏
godot --path .
```

### 构建（无头验证 + 导出）

```bash
# 1. 资源导入（首次 / 清理缓存后必做）
godot --headless --path . --import

# 2. 逻辑层整局回归（约 15 秒，期望输出 SMOKE PASS）
godot --headless --path . --script tests/headless_smoke.gd

# 3. 导出 Windows 可执行文件到 build/windows/
godot --headless --path . --export-release "Windows Desktop"
```

Python 工具链（可选，用于生成/校验美术资源）：

```bash
python -m pip install pillow
python tools/asset_audit.py     # 资产审计
python tools/sfx_gen.py         # 程序化音效生成
```

---

## 目录结构

```
G-A/
├── project.godot            # 工程配置（主场景 / 渲染 / 物理）
├── export_presets.cfg       # 统一导出预设（Windows x86_64）
├── main.gd / main.tscn      # 入口
├── core/                    # 纯逻辑层，无渲染依赖，可 --headless 运行
│   ├── config_db.gd         # 数值单源加载（TSV / JSON）
│   ├── game_state.gd        # 全局状态
│   ├── phase_machine.gd     # 四阶段状态机
│   ├── event_bus.gd         # 逻辑 → 表现的事件总线
│   ├── sim.gd               # 定步长模拟主循环
│   ├── save_system.gd       # 存档
│   └── systems/             # 玩法子系统（波次/经济/背包/奖励/侦察/玩家…）
├── app/                     # 应用层：装配 core 与 view
├── view/                    # 3D 表现层（世界构建、相机、模型）
├── ui/                      # 界面层（HUD、商店、背包、设置、概率公示）
├── data/                    # 数值与配置
│   ├── numeric/             # 5 张 TSV：波次/敌人/守卫/商店/武器等级
│   └── *.json               # 平衡/建筑/物品/掉落/河道
├── art/
│   ├── assets/              # 运行时资源（唯一被引擎导入的美术目录）
│   ├── blender-work/        # Blender 源文件（.gdignore）
│   ├── raw/ concept/        # 原始素材与概念图（.gdignore）
│   ├── review/ trash/ logs/ # 渲染评审 / 废弃 / 工具日志（生成物，不入库）
│   └── baseline/ blender-demo/
├── tests/                   # 无头回归 + 截图验证脚本
├── tools/                   # Python 美术与资源工具
├── docs/                    # 设计与技术文档
│   ├── design/              # 玩法设计与开发总纲
│   ├── art/                 # 美术风格、资产清单、提示词包
│   ├── tech/                # 地形/模型接入、Blender 插件
│   └── records/             # 迭代记录与待办
└── shots/                   # 测试运行截图（生成物，不入库）
```

## 架构约定

- **单向依赖**：`data → core → app → view / ui`，反向不允许。
- **数值单源**：所有数值只在 `data/` 中定义，代码不写魔法数字。
- **逻辑可复现**：命中判定使用解析几何，`core` 不依赖物理引擎，可完全无头回归。
- **事件驱动**：表现层只订阅 `EventBus`，不直接改状态。

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/design/开发文档-2.5D.MD](docs/design/开发文档-2.5D.MD) | 开发总纲（v2.0 重构，含数值口径与阶段契约） |
| [docs/design/P1-开发计划.md](docs/design/P1-开发计划.md) | P1 迭代计划 |
| [docs/design/建造系统设计-2026-11-10.md](docs/design/建造系统设计-2026-11-10.md) | 城墙加建与修理设计 |
| [docs/art/城墙尸潮-美术风格提案.md](docs/art/城墙尸潮-美术风格提案.md) | 美术风格与配色 |
| [docs/art/城墙尸潮-美术资产清单.md](docs/art/城墙尸潮-美术资产清单.md) | 资产清单与命名规范 |
| [docs/tech/城墙尸潮-地形接入说明.md](docs/tech/城墙尸潮-地形接入说明.md) | 地形与碰撞接入 |
| [docs/records/overview.md](docs/records/overview.md) | 工程总览 |

## 许可

未声明开源许可，默认保留所有权利。
