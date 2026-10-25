# BREAK THE CHAIN / 断链

Roblox 多人感染对抗游戏。设计文档见 `docs/`，以 `断链_BREAK_THE_CHAIN_Game_Design_Bible_V1.1.md` 和 `断链_BREAK_THE_CHAIN_视觉圣经_V1.1.md` 为准。

## 开发环境

1. 安装 [Rokit](https://github.com/rojo-rbx/rokit)，然后在仓库根目录运行：

   ```bash
   rokit install
   ```

   这会按 `rokit.toml` 安装锁定版本的 Rojo、Wally、StyLua、Selene、Lune、luau-lsp。

2. 在 Roblox Studio 中安装 Rojo 插件（版本与 `rokit.toml` 中的 Rojo 一致），然后启动同步：

   ```bash
   rojo serve
   ```

   在 Studio 的 Rojo 插件里点 Connect。运行游戏后，输出窗口应出现 `[BreakTheChain] server boot ...`。

## 当前进度

Gate A（规则闭环）的代码已完成：追逐与扑咬（A0）、轻射击对抗层（A0.5，GDB §9A）、感染树、治愈、8 秒断联与重连、撤离与胜负。
下一步是 Studio 试玩验收，按 [docs/Gate_A_试玩验收清单.md](docs/Gate_A_试玩验收清单.md) 逐项确认；通过之前不开始 Gate B。

## 常用命令

| 用途 | 命令 |
|---|---|
| 单元测试（纯逻辑，Lune） | `lune run tests/lune/run` |
| 格式化 | `stylua src tests` |
| Lint | `selene src` 与 `selene --config tests/lune/selene.toml tests/lune` |
| 构建 place 文件 | `rojo build default.project.json -o build.rbxl` |
| 感染树形状模拟 | `python3 sim/tree_shape.py` |

## 目录

结构与 GDB V1.1 §20.2 一致：

- `src/shared` → `ReplicatedStorage.Shared`：可公开的配置、类型、常量、视觉 Token
- `src/server` → `ServerScriptService.Game`；`src/server/logic` 为纯逻辑，不引用 Roblox API，可在 Lune 中测试
- `src/client` → `StarterPlayerScripts.Controllers`
- `src/remotes` → `ReplicatedStorage.Remotes`
- `src/assets` → `ServerStorage.GameAssets`
- `tests/lune`：Lune 单元测试，新增测试文件命名为 `*.spec.luau` 即会被自动发现
- `sim`：平衡模拟脚本
- `art`：美术源文件（视觉圣经 §10.3）

## 约定

- 秘密信息（感染树拓扑、扫描结果、重连目标）不得放进 `src/shared` 或任何会复制给客户端的对象（GDB §17.6）。
- 纯逻辑放在 `src/server/logic`，配置通过参数传入，必须能在 Lune 中测试。
- 通过 Studio MCP 做的场景修改必须回写到 Rojo 管理的文件。
