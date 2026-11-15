using System.ComponentModel;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace DspMcpBridge;

/// <summary>
/// Write tools (risk level L1: reversible, no lasting effect on the save).
///
/// Gates, in order (doc 5.9):
///  1. The op must exist in the bridge's closed-by-default CommandRouter.
///  2. The game-side config <c>[Bridge] AllowWrites</c> must be true. That value is read
///     from runtime.json on EVERY call rather than cached, so flipping it (or restarting
///     the game) is picked up without restarting this server.
///  3. Nothing above L1 exists here at all. There is no delete-save, no overwrite-save,
///     no quit-game, and above all no eval/reflection-invoke op -- exposing arbitrary code
///     execution would make every other guard meaningless (doc 5.9.1, L4 red line).
/// </summary>
[McpServerToolType]
public sealed class DspWriteTools
{
    private readonly DspClient _dsp;
    private readonly ILogger<DspWriteTools> _log;

    public DspWriteTools(DspClient dsp, ILogger<DspWriteTools> log)
    {
        _dsp = dsp;
        _log = log;
    }

    [McpServerTool(Name = "dsp_set_pause", ReadOnly = false, Destructive = false,
                   Idempotent = true, OpenWorld = false, UseStructuredContent = false)]
    [Description("暂停或继续游戏（调用 GameMain.Pause / Resume）。L1 可逆写操作：不改变存档内容，"
               + "只影响游戏是否推进时间。需要游戏侧配置 [Bridge] AllowWrites = true，否则会被拒绝并给出原因。"
               + "适合在观察某个状态时冻结时间，避免数据一直变。")]
    public async Task<CallToolResult> SetPauseAsync(
        [Description("true = 暂停，false = 继续。")] bool paused,
        CancellationToken ct)
    {
        try
        {
            // Live check: runtime.json is tiny and is rewritten on every game start.
            if (!_dsp.AllowWrites)
            {
                return DspReadTools.Error("writes_disabled",
                    "游戏侧写操作开关是关闭的（[Bridge] AllowWrites = false），该命令未发送。",
                    "编辑 BepInEx\\config\\org.yourname.dspbridge.cfg，把 [Bridge] AllowWrites 改成 true 并重启游戏。");
            }

            var json = await _dsp.CommandAsync("set_pause", new { paused }, ct).ConfigureAwait(false);
            _log.LogInformation("set_pause({Paused}) -> {Result}", paused, json);
            return DspReadTools.Ok(json);
        }
        catch (DspClient.DspUnavailableException ex)
        {
            return DspReadTools.Error("game_unavailable", ex.Message, "启动游戏并进入存档后重试。");
        }
        catch (OperationCanceledException)
        {
            return DspReadTools.Error("cancelled", "调用被取消（超时或用户中断）。", "重试一次。");
        }
    }
}
