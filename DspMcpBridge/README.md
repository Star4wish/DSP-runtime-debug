# DspMcpBridge

MCP server that turns the in-game `DspBridge` HTTP endpoint into MCP tools and resources,
so an LLM client (Claude Code, Codex, ...) can read live Dyson Sphere Program state and issue
a small, audited set of debug actions.

**Full documentation (Chinese): `..\运行时调试环境-使用手册.md`**

## Why it is a separate process

The MCP C# SDK 2.x requires modern .NET, while the in-game plugin is pinned to `net472` by
BepInEx 5 / CommonAPI. The two cannot share an assembly, so this server:
`net10.0` + `ModelContextProtocol` 2.2.0, talking to the game over loopback HTTP.

## Build and register

```powershell
. '..\tools\dspenv.ps1'
& $DspDotnet build '..\DspMcpBridge\DspMcpBridge.csproj' -c Release
```

Point your client at the launcher, not at `dotnet run`:

```json
{
  "mcpServers": {
    "dsp-bridge": {
      "type": "stdio",
      "command": "C:\\XCM\\DSP MPD\\tools\\run-dsp-mcp.cmd",
      "args": [],
      "timeout": 30000
    }
  }
}
```

`tools\run-dsp-mcp.cmd` sets the workspace-local SDK/package directories and runs the built
dll, so startup needs no MSBuild, no restore and no writable user profile.

## Tools

| Tool | R/W | Notes |
|---|---|---|
| `dsp_health` | R | liveness; use this first |
| `dsp_get_state` | R | main-thread snapshot (planet, power, research, proto sizes) |
| `dsp_get_catalog` | R | proto table sizes |
| `dsp_get_planet_power` | R | per-planet power; omit `planetId` for the local planet |
| `dsp_list_planets` | R | instantiated factories/planets, paged |
| `dsp_find_items` | R | item proto search, paged |
| `dsp_tail_log` | R | `BepInEx\LogOutput.txt` tail, token redacted |
| `dsp_get_audit` | R | recent command audit trail |
| `dsp_set_pause` | W | L1, refused unless the game side sets `AllowWrites = true` |

Resources: `dsp://health`, `dsp://state`, `dsp://catalog`, `dsp://planets`.

Not implemented, on purpose: anything L2+ (bulk build/demolish, global recipe rewrite),
L3 (delete/overwrite save, quit game, arbitrary file writes) and L4 (eval / reflection
invoke / `Process.Start`). Exposing L4 would make every other guard meaningless.

## Two rules that matter more than anything else here

1. **stdout is the JSON-RPC channel.** Logging is configured with
   `LogToStandardErrorThreshold = Trace`, the console logger is the only provider, and
   `Console.WriteLine` is banned in this project. A single stray line makes the client fail
   with an error that points nowhere near the cause.
2. **The game is optional.** Every game-dependent call degrades into a readable tool error
   (`game_unavailable` + how to fix it), never a protocol exception. Most of the time the
   game will be closed, and the session must still behave.

## SDK details worth remembering (verified against 2.2.0)

* **Optional tool parameters need a C# default value.** The SDK treats parameters without a
  default as required and throws `ArgumentException: The arguments dictionary is missing a
  value for the required parameter 'x'` *before* the method body runs; the client only sees
  `An error occurred invoking '...'`.
* **Do not throw `McpException` for expected errors.** It is flattened to
  `{"error":{"code":-32603,"message":"An error occurred."}}` and the message never reaches
  the model. Return `CallToolResult { IsError = true, Content = [...] }` instead.
* **`Host.CreateApplicationBuilder` needs `Microsoft.Extensions.Hosting`** as an explicit
  package reference (the MCP package only brings `Hosting.Abstractions`).
* **Set `MimeType` on resources**, otherwise they advertise `application/octet-stream`.
* Only constructor *dependencies* need `AddSingleton`; tool/resource classes are constructed
  by the SDK via `ActivatorUtilities.CreateInstance(scope.ServiceProvider, type)`.

## Offline / stub mode

`DSP_BRIDGE_STUB=<json file>` makes every call answer from a canned payload instead of the
game. It exists so the whole MCP layer can be verified without launching the game; see
`tools\stub-runtime.json` and `tools\verify-mcp.ps1`.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\verify-mcp.ps1            # stub mode
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\verify-mcp.ps1 -Offline   # game absent
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\test-all.ps1              # everything
```
