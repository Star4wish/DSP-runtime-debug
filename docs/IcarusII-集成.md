# IcarusII（游戏内 AI / 工具通道）· 集成与无人值守调试

> 本文是 [`在线调试环境-使用说明.md`](使用说明.md) 的补充章节，记录 **IcarusII 1.2.342**
> 在本机的接入方式、两条驱动路径（`!tool` 直调 / AI 对话）、权限放行语义、以及实测结论。
> 踩坑汇总见文末 §9；环境级坑仍以 [`在线调试环境-踩坑与排查.md`](踩坑与排查.md) 为准。

---

## 0. 一句话

IcarusII = **游戏内 AI 助手插件** + **本地 sidecar 进程**（`ws://127.0.0.1:8765/`）。它把 40+ 个游戏工具
（读状态、改配方/仓库/研究、uGUI 快照与合成点击、其它 BepInEx 插件配置桥）挂给模型；
把 `PermissionLevel` 设为 `takeover` 后**所有写操作不再弹确认**，再配合 `DebugToolConsole` 的
`!tool` 直调通道，就能做到：**不开 AI、不花 token、不点确认，由外部脚本逐条触发游戏内动作**。

和 DspBridge 的分工：

| 通道 | 端口 | 强项 | 弱项 |
|---|---|---|---|
| DspBridge（本项目） | `127.0.0.1:17890` | 只读快照稳定、结构化、`get_log_tail` | 只有 10 个固定 op，改存档能力有限 |
| IcarusII sidecar | `127.0.0.1:8765` | 工具面大（写配方/仓库/研究/UI/uGUI 点击/其它 mod 配置） | 依赖游戏内连接执行、`takeover` 风险高 |

---

## 1. 架构（已按 DLL 反编译 + 运行期日志核实）

```
IcarusII.dll（BepInEx 5.4.17 插件，GUID=icarus-ii，v1.2.342）
  ├─ 启动时 spawn：sidecar\icarus-ii-sidecar.exe serve --host 127.0.0.1 --port 8765
  │                --data-dir "%APPDATA%\icarus-ii"  [--debug-tools]
  ├─ sidecar 写 %APPDATA%\icarus-ii\runtime.json：{host,port,token,pid,version}
  ├─ 插件以 WebSocket ws://127.0.0.1:8765/ 连接，hello 携带 token / capabilities / saveKey
  └─ 每个 WS 连接一个 session；game 工具只由"绑定了游戏连接"的客户端执行

sidecar 同时提供 HTTP：GET /health -> {"status":"ok","version":"1.2.342","uptimeMs":...}
```

- **token**：每次 sidecar 重启都会变化（`runtime.json`），别写死；DspBridge 的 token 是另一套
  （`%LOCALAPPDATA%\DSPBridge\runtime.json`），两套不要混。
- **多客户端**：实测允许并发（多个 WS 各自 session，互不干扰）。
- **外部程序能做什么**：可以连上去 `hello` + `prompt`，收到 `status/stream/message` 流式回复；
  **不能**让外部客户端执行 `game_*` 工具——工具会被路由给真正的游戏连接（见 §7 坑 1）。

---

## 2. 一次性配置（改完必须重启游戏）

文件：`<游戏目录>\BepInEx\config\icarus-ii.cfg`
r2modman 用户同时改 profile 里的那份：`%APPDATA%\r2modmanPlus-local\DysonSphereProgram\profiles\Default\BepInEx\config\icarus-ii.cfg`

```ini
[General]
DebugToolConsole = true      ; 输入框可用 !tools / !tool <name> <JSON>，且 sidecar 会带 --debug-tools 启动

[Agent]
PermissionLevel = takeover   ; readonly | limited | takeover
                             ; takeover = 所有写操作直接执行，不再弹确认（危险，见 §6）
```

其它保持默认即可：`[Sidecar] Host=127.0.0.1`、`Port=8765`、`DataDir` 留空（默认 `%APPDATA%\icarus-ii`）；
`[UI] AutoFocusInput=false`（脚本发命令前会先按一次 Enter 聚焦输入框；保持 false 不影响 R 键开关窗）。

一键完成（同时写 profile 与游戏目录、并备份）：

```powershell
cd '<repo>'
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-r2modman-profile.ps1 -WhatIfOnly   # 先看计划
powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-r2modman-profile.ps1             # 应用
```

> **为什么必须装进 profile**：r2modman 的 **Start modded** 每次启动都会用 profile 内容覆盖游戏目录。
> 只装在 `<游戏>\BepInEx\plugins\DspBridge` 的桥接会被覆盖删除（2026-11-10 实际发生）。
> 该脚本把 `DspBridge.dll` 写进 profile + 游戏目录，并统一写 `icarus-ii.cfg`。

---

## 3. 两条驱动路径

### 3.1 `!tool` 直调（推荐给脚本，确定性、不耗 token、不需要 Key）

在游戏内聊天输入框发送：

```
!tools                                  # 列出所有已注册工具
!tool game_get_progress {}              # 直接执行工具；参数是 JSON
!tool game_place_marker {"latitude":0,"longitude":0}
```

- 走 sidecar 的 `tool_debug` 通道，**不经过模型**；写工具仍会走确认流程，但 `takeover` 下自动放行（§5）。
- 需要 sidecar 以 `--debug-tools` 启动（由 `DebugToolConsole=true` 自动加上）。

### 3.2 AI 对话（自然语言，需要 API Key）

在聊天框输入自然语言（如「报告当前星球电力供需」），模型会自主选工具、读状态、给结论；
写操作同样受 `PermissionLevel` 控制。本机 Key 配置在 sidecar 的 `%APPDATA%\icarus-ii\config.json`
（本机已配置 DeepSeek，模型 `deepseek-flash`）。

---

## 4. 输入自动化：`tools\icarus-ctl.ps1`

把"开聊天窗 → 粘贴文本 → 回车 → 截图"做成可脚本化命令（DPI-aware，物理像素）。
前置条件：游戏已进入存档（主菜单不响应聊天热键）、`DebugToolConsole=true`。

```powershell
cd '<repo>'

# 状态：DspBridge /health + sidecar /health + 最近日志
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode status

# 抓图 / 聚焦 / 按键 / 点击（物理像素）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode shot -Out logs\a.png
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode focus
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode key -VK 27
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode click -X 1024 -Y 800

# !tool 直调（JSON 建议用 -ArgsFile，避免 PowerShell 命令行吞引号）
'{"latitude":0,"longitude":0}' | Set-Content logs\args.json -Encoding UTF8
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode tool -Name game_place_marker -ArgsFile logs\args.json

# AI 对话（聊天窗已开着时加 -ChatAlreadyOpen）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\icarus-ctl.ps1 -Mode talk -Text "报告当前星球电力供需" -ChatAlreadyOpen
```

- 发送流程：前台聚焦 → 按热键 `R` 开聊天窗 → `Enter` 聚焦输入框 → `Ctrl+V` 粘贴 → `Enter` 发送 → 等待 → 截图。
- 聊天窗是**开关**：已经打开时不要再带 `R`，用 `-ChatAlreadyOpen`；不确定就先 `-Mode key -VK 27` 关窗。
- `-WaitMs` 控制等待（`!tool` 6s 足够；AI 对话建议 20–40s）。

典型无人值守序列（示例，按需裁剪）：

```powershell
# 1) 启动并等桥接
tools\dev-loop.ps1 -Mode up
# 2) 载入存档（人工或点"继续"；见 dev-loop 的 click）
# 3) 连发多条确定性命令
'tools\icarus-ctl.ps1 -Mode tool -Name game_get_power -ArgsJson "{}"' | Invoke-Expression
# 4) 跑验收
tools\test-all.ps1 -RequireLive
```

---

## 5. 权限放行语义（`Protocol.AutoApprovesWrite`，已反编译核实）

| `PermissionLevel` | risk 0（只读） | risk 1（镜头/标记/面板/研究/方位/撤销） | risk 2（改存档：配方/仓库/投料/取产物/丢弃/脚本写） |
|---|---|---|---|
| `readonly` | 自动 | 弹确认 | 弹确认 |
| `limited`（默认） | 自动 | 自动 | 弹确认 |
| **`takeover`** | 自动 | **自动** | **自动** |

确认请求由 sidecar 发给游戏插件，插件侧按上表**直接回 allow**，不出现确认框。本机实测日志：

```
[Info : Icarus II] [confirm] 权限 takeover：自动同意 game_place_marker risk=1 callId=call_5
[Info : Icarus II] [confirm] 权限 takeover：自动同意 game_drop_item   risk=2 callId=call_6
```

沙盒存档另有 `SandboxAllows`：非沙盒只允许非 sandbox-only 工具；`sandbox=true` 时**全部放行**
（`game_spawn_item` / `game_teleport` 仅沙盒可用）。

---

## 6. 风险与还原

- `takeover` 意味着**模型/脚本可以在不询问的情况下改存档**。只在**测试存档/沙盒**里用；
  主力存档请切回 `limited`（游戏内聊天窗右下角「权限」下拉框，或改 cfg 后重启）。
- `game_drop_item`、`game_take_output` 等 risk 2 操作可能**不可撤销**（IcarusII 有撤销栈，但不覆盖全部）。
- 还原为安全档位：

```powershell
# 方法一：改两份 cfg（profile + 游戏目录），把 PermissionLevel 改成 limited，然后重启游戏
# 方法二：游戏内聊天窗右下角「权限」下拉框切到「受限」
```

---

## 7. 实测结论（2026-11-10，本机）

| 项 | 结果 |
|---|---|
| sidecar 启动参数 | `serve --host 127.0.0.1 --port 8765 --data-dir "%APPDATA%\icarus-ii" --debug-tools` ✅ |
| sidecar `GET /health` | `{"status":"ok","version":"1.2.342","uptimeMs":…}` ✅ |
| 外部 WS 客户端 | 正确 token 握手 `ready`（含 sessionId/工具表/权限档位）；错误 token → `{"code":"unauthorized"}`；多客户端并发正常 ✅ |
| 外部 WS `prompt` | 能收到 `status → stream → message` 流式回复（echo agent 验证）✅ |
| 外部 WS 调 `game_*` | **不可行**：game 工具由绑定游戏连接的客户端执行；冒充游戏端会被路由给自己（交接文档 §9 坑 7）❌ |
| `!tool game_get_progress {}` | 聊天窗自动输入成功，返回完整 JSON ✅ |
| AI 自然语言 | 模型自主调用 `game_get_progress/get_overview/get_power/get_player` 并正确回答 ✅ |
| takeover risk1 写 | `game_place_marker` 自动同意并执行 ✅ |
| takeover risk2 写 | `game_drop_item` 自动同意并执行 ✅ |
| DspBridge `gameLoaded` | 修复后载入存档 5s 内 `true`（原 1.0.0–1.0.1 恒 false，见踩坑文档）✅ |

---

## 8. 与 MOD 调试的结合点

- **让 AI 看到 MOD 内部状态**：IcarusII 的 `game_get_entity` 等工具读的是实体通用组件；
  MOD 专属数据可通过反射往 `IcarusII.Game.Tools.EntityTool.BuildData` 做 Postfix 注入
  （分子枢纽 P6 的 `Common\IcarusInject.cs` 就是范例：未装 IcarusII 时自动跳过）。
- **让 MOD 配置可脚本化**：`mods_config_list/get/set` 工具可直接读写其它 BepInEx 插件的 cfg；
  `mods_api_list` + `mods_adapter_create` 还能把插件公开方法包成 AI 可调工具（每次调用需确认，
  除非配置文件等级设到接管）。
- **uGUI 自动化**：`ui_snapshot` 拿控件树、`ui_click` 按控件点（比像素坐标稳），适合验证自绘窗口。

---

## 9. 坑（IcarusII 专项）

1. **外部 WS 冒充游戏端调工具**：工具会被路由到真实游戏连接，你的客户端等不到结果、模型会反复重试。
   外部客户端只用来 chat/观察，执行必须走游戏内插件。
2. **r2modman 覆盖**：Start modded 会用 profile 覆盖游戏目录，只装在游戏目录的 `DspBridge.dll` 会被删。
   必须跑 `tools\install-r2modman-profile.ps1`（装 profile + 游戏目录）。
3. **token 每次变**：sidecar 重启后 `%APPDATA%\icarus-ii\runtime.json` 的 token 变化；
   每次连接前重新读，不要缓存。DspBridge 的 token 是另一套。
4. **`!tool` 无效**：先确认 sidecar 命令行里有 `--debug-tools`（由 `DebugToolConsole=true` 传递），
   再确认 cfg 已生效（改完要重启游戏）。
5. **JSON 参数被吞**：`powershell -File script.ps1 -ArgsJson '{"a":1}'` 到子进程会变成 `{a:1}`。
   用 `-ArgsFile`（本脚本已支持），或把 JSON 写进文件再读。
6. **聊天窗是开关**：已打开时再按 `R` 会关掉；用 `-ChatAlreadyOpen` 或先 `Esc`。
7. **主菜单不响应**：IcarusII 聊天窗只在载入存档后可用；先 `-Mode up` + 载入存档。
8. **焦点/前台**：按键前必须把游戏窗口切前台（`icarus-ctl` 内部已做）；不要在建造模式里按 `R`
   （会被游戏当作旋转建筑）。
9. **端口 8765 占用**：同机只能有一个 sidecar；插件重启会先结束旧 sidecar（会杀进程），
   若残留占用，检查 `runtime.json` 里的 pid 是否还活着，必要时手动结束。
10. **Key/配置位置**：API Key 只在 `%APPDATA%\icarus-ii\config.json`（sidecar 数据目录），
    不要提交进仓库、不要拷进游戏目录。
11. **不要用测试档验证 risk2**：takeover 下 risk2 直接改存档；用沙盒或一次性测试档。

---

## 10. 相关文件

| 路径 | 说明 |
|---|---|
| `tools\install-r2modman-profile.ps1` | 把 DspBridge 装进 r2modman profile（+游戏目录）并统一 IcarusII 调试配置 |
| `tools\icarus-ctl.ps1` | 游戏内输入自动化（status/shot/focus/key/click/tool/talk） |
| `<游戏>\BepInEx\config\icarus-ii.cfg` | IcarusII 插件配置（profile 里还有一份） |
| `%APPDATA%\icarus-ii\runtime.json` | sidecar 端口/token/pid（每次重启变化） |
| `%APPDATA%\icarus-ii\config.json` | 模型/Key/权限（sidecar 存储） |
| `<内部反编译产物>\` | 本次反编译与协议实验产物（`IcarusII.full.cs`、`sidecar-strings.txt`、`probe-ws*.ps1`） |
