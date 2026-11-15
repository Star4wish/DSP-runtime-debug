using DspMcpBridge;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

// ---------------------------------------------------------------------------------------
// DspMcpBridge -- MCP server that exposes the DSP runtime bridge to an LLM client.
//
// TWO RULES THAT MATTER MORE THAN ANYTHING ELSE HERE:
//
// 1. stdout is the JSON-RPC channel. NOTHING may be written to stdout except protocol
//    messages: not one log line, not a banner. AddConsole is therefore configured with
//    LogToStandardErrorThreshold = Trace (everything to stderr), the console logger is the
//    only provider, and Console.WriteLine is banned in this project. A single stray line
//    makes the client fail with an error that points nowhere near the cause (doc 5.4.1).
//
// 2. The game is optional. Every game-dependent call degrades into a readable tool error
//    ("game is not running, start it and load a save"), never a protocol exception --
//    otherwise the session looks broken whenever the player closes the game (doc 5.6 #6).
// ---------------------------------------------------------------------------------------

var builder = Host.CreateApplicationBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddConsole(o => o.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Logging.SetMinimumLevel(LogLevel.Information);

// Only DEPENDENCIES need registering. The MCP SDK constructs tool/resource classes itself
// through ActivatorUtilities.CreateInstance(scope.ServiceProvider, type), so DspReadTools,
// DspWriteTools and DspResources are intentionally absent here.
builder.Services.AddSingleton<DspClient>();

// WithToolsFromAssembly / WithResourcesFromAssembly discover every class carrying
// [McpServerToolType] / [McpServerResourceType] in this assembly.
// NOTE: there is deliberately no prompts class -- prompt support is inconsistent across
// clients (doc 5.4.3), and an empty prompt list is more honest than a broken one.
builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithToolsFromAssembly()
    .WithResourcesFromAssembly();

var host = builder.Build();

var log = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("DspMcpBridge");
log.LogInformation("DspMcpBridge 1.0.0 启动：stdio 传输，日志全部走 stderr。");
log.LogInformation("游戏发现文件：{Path}", DspClient.RuntimeFilePath);
log.LogInformation("写操作由游戏侧 [Bridge] AllowWrites 决定（本进程不做二次开关）。");

if (StubMode.Enabled)
    log.LogWarning("STUB 模式已启用（DSP_BRIDGE_STUB={Path}）：不会连接真实游戏。", StubMode.Path);

await host.RunAsync().ConfigureAwait(false);
return 0;
