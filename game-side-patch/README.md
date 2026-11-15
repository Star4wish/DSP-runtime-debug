# game-side-patch — 游戏目录需要什么

本目录**不包含任何二进制文件**（Doorstop 注入器、BepInEx core、已编译插件都不入库，原因见根 README）。
这里只说明游戏目录最终应该长什么样，以及每个文件从哪来。

## 目标布局（游戏根目录）

```
<游戏>\
├─ DSPGAME.exe
├─ winhttp.dll                  ← Doorstop 注入器（第三方）
├─ doorstop_config.ini          ← Doorstop 配置（本仓库提供模板，见下）
├─ BepInEx\
│  ├─ core\                     ← BepInEx 运行时（第三方）
│  │  ├─ BepInEx.Preloader.dll
│  │  ├─ BepInEx.dll
│  │  └─ 0Harmony.dll ...
│  ├─ config\
│  │  └─ org.yourname.dspbridge.cfg   ← 首次启动游戏后自动生成
│  └─ plugins\
│     └─ DspBridge\
│        └─ DspBridge.dll       ← 本仓库编译产物（tools\build-and-deploy.ps1 部署）
└─ BepInEx\LogOutput.log        ← 游戏内日志（每次启动重写）
```

## 各文件来源

| 文件 | 来源 | 备注 |
|---|---|---|
| `winhttp.dll` + `BepInEx\core\*` | 安装 BepInEx 5.4.x（推荐用 r2modman 安装，或官方 `BepInEx_win_x64_5.4.17.0.zip`） | 与社区/R2 玩家侧版本保持一致，建议 **5.4.17** |
| `doorstop_config.ini` | BepInEx 发行包自带；也可用下面模板 | 格式必须与注入器**同代**：Doorstop 3.x 用 `[UnityDoorstop]` |
| `BepInEx\plugins\DspBridge\DspBridge.dll` | 本仓库构建 | `tools\build-and-deploy.ps1` 或 `tools\install-r2modman-profile.ps1` |

## doorstop_config.ini 模板（Doorstop 3.4.0 代，配合 BepInEx 5.4.17）

```ini
[UnityDoorstop]
enabled=true
targetAssembly=BepInEx\core\BepInEx.Preloader.dll
redirectOutputLog=false
ignoreDisableSwitch=false
dllSearchPathOverride=
```

> **不要混代**：Doorstop 4.x 的 `[General]`/`[UnityMono]` 配置配 5.4.17 的 core、
> 或 Doorstop 3.4.0 的注入器配 5.4.23.x 的 core，都会**静默失败**（游戏照常启动，但 BepInEx 完全不注入）。
> 判断方法：`winhttp.dll` 约 25088 B → Doorstop 3.4.0；约 26112 B → Doorstop 4.5.0。
> 详见 [`../docs/踩坑与排查.md`](../docs/踩坑与排查.md) §1。

## 用 r2modman 的用户（推荐）

r2modman 每次 **Start modded** 都会用 profile 覆盖游戏目录，只装在游戏目录里的插件会被删掉。请改成：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\install-r2modman-profile.ps1
```

它会把 `DspBridge.dll` 写进 `%APPDATA%\r2modmanPlus-local\DysonSphereProgram\profiles\<Profile>\BepInEx\plugins\DspBridge\`，
并镜像一份到游戏目录。

## 校验安装是否成功

启动游戏后看 `<游戏>\BepInEx\LogOutput.log`：

```
[Info   :   BepInEx] BepInEx 5.4.17.0 - DSPGAME
[Info   :DSP Runtime Bridge] [DspBridge] 配置就绪 pid=... 端口=17890 writes=False
[Info   :DSP Runtime Bridge] [DspBridge] 已监听 http://127.0.0.1:17890/
```

或直接：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\dev-loop.ps1 -Mode status
```
