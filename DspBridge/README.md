# DspBridge

In-game BepInEx 5 plugin that exposes a loopback HTTP endpoint for LLM-driven runtime
debugging of Dyson Sphere Program.

**Full documentation (Chinese): `..\运行时调试环境-使用手册.md`**

This file is ASCII-only on purpose: it is the quick reference for the component itself.

## What it is

```
HTTP (127.0.0.1 only, bearer token)
  GET  /health   <- liveness; touches no Unity object, so it answers during loading
  GET  /state    <- main-thread snapshot, rebuilt every 30 frames
  POST /command  <- {"op":"...","args":{...}}, executed on the Unity main thread
```

The listener thread only parses and queues. Every game/Unity access goes through
`BridgePlugin.InvokeOnMain`, which ends up running inside `Update()`.

## Build and deploy

```powershell
# Elevated shell: the game lives under Program Files.
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\build-and-deploy.ps1
```

Produces `bin\Release\DspBridge.dll` and copies it to
`<game>\BepInEx\plugins\DspBridge\DspBridge.dll`.

Offline build: the project references the game assemblies from `..\tools\refs` and
BepInEx from `..\tools\bepinex-lib` via `HintPath` with `Private=false`, so nothing but
`DspBridge.dll` ends up in the plugin directory.

Override with `-p:RefsDir=<game>\DSPGAME_Data\Managed` and
`-p:BepInExLibDir=<game>\BepInEx\core` if the local copies are missing.

## Hard constraints (do not "clean these up")

| Constraint | Why |
|---|---|
| `net472` | BepInEx 5 / CommonAPI constraint; the plugin must load in Unity Mono |
| Zero third-party dependencies | BepInEx loads every dll under `plugins` at any depth, so a bundled `Newtonsoft.Json.dll` collides with other mods |
| Hand-written JSON (`Json.cs`) | `System.Text.Json` fails under Unity Mono (dotnet/runtime#80525); `JsonUtility` cannot do dictionaries |
| Never touch Unity API off the main thread | BepInEx source: "Most of Unity API can not be accessed while running on another thread!" |
| Listener + first dispatch deferred to `Update()` | `ThreadingHelper` assigns its main thread in its own `Update`, so `InvokeRequired` is always true inside `Awake`/`Start` |
| `http://127.0.0.1:PORT/` prefix only | avoids URL ACL, admin rights, firewall rules and LAN exposure |
| `Thread.Abort` is never used | `Stop()` + `Close()` makes the blocking `GetContext()` throw and end the loop |

## Files

| File | Responsibility |
|---|---|
| `BridgePlugin.cs` | BepInEx entry point, config, HTTP listener, main-thread dispatcher, `runtime.json` |
| `CommandRouter.cs` | Closed-by-default op table, write gate, audit trail, log tail, token redaction |
| `GameSnapshot.cs` | Main-thread snapshot builder and reflective readers |
| `Reflect.cs` | Version-tolerant member access plus the small `JsonObject` writer |
| `Json.cs` | Hand-written JSON writer and recursive-descent parser |

## Ops

L0 read: `get_health`, `get_state`, `get_catalog`, `get_power`, `get_planet_power`,
`list_planets`, `find_items`, `get_log_tail`, `get_audit`

L1 reversible write (off by default, `[Bridge] AllowWrites = true`): `set_pause`

Adding an op means adding a `case` in `CommandRouter.Dispatch`. Nothing is callable by
name at runtime; there is deliberately no eval/reflection-invoke op (L4 red line).

## Config

`<game>\BepInEx\config\org.yourname.dspbridge.cfg`

```ini
[Bridge]
Port = 17890
Token = <generated on first run; do not hand-edit>
AllowWrites = false
SnapshotEveryFrames = 30
AuditLogToFile = true
```

`runtime.json` is written to `%LOCALAPPDATA%\DSPBridge\runtime.json` and contains the
port, token, pid, schemaVersion, gameRoot and the write flag. It is the only discovery
mechanism the MCP server needs.

## Tests

```powershell
# Pure logic, no game required (JSON, op table, write gate, audit, redaction)
dotnet run --project ..\tools\bridge-core-test

# Full automated suite, including the MCP layer and the live game checks
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\test-all.ps1
```
