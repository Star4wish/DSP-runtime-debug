using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace DspMcpBridge;

/// <summary>
/// Information published by the in-game bridge so this process can find it.
/// The bridge rewrites this file every time the game starts (new random token),
/// which is exactly why the MCP server must not cache it for the process lifetime.
/// </summary>
public sealed record DspRuntimeInfo(
    int Port,
    string Token,
    int Pid,
    int SchemaVersion,
    string GameRoot,
    bool AllowWrites,
    DateTimeOffset? StartedAt);

/// <summary>
/// HTTP client for the in-game bridge.
///
/// Every failure mode is translated into a readable, actionable message rather than a
/// transport exception, because the LLM (not a human reading a stack trace) is the
/// consumer. Specifically, "the game is not running" must come back as an ordinary tool
/// result, not a protocol-level error -- otherwise the whole MCP session looks broken the
/// moment the player closes the game (doc 5.6 step 6).
/// </summary>
public sealed class DspClient
{
    private readonly ILogger<DspClient> _log;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(35) };
    private readonly object _gate = new();

    private DspRuntimeInfo _info;
    private string _lastError;

    public DspClient(ILogger<DspClient> log) => _log = log;

    /// <summary>Where the game writes its discovery file.</summary>
    public static string RuntimeFilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "DSPBridge", "runtime.json");

    /// <summary>
    /// Candidate discovery paths, in priority order.
    ///
    /// The extra entries exist because this repo's build scripts redirect LOCALAPPDATA into
    /// the workspace; when the game is launched from such a shell the file lands there
    /// instead. Every path is derived at runtime, so the tree can be moved to another
    /// machine, drive or folder and still find the bridge.
    /// </summary>
    public static IEnumerable<string> CandidateRuntimePaths()
    {
        var explicitPath = Environment.GetEnvironmentVariable("DSP_BRIDGE_RUNTIME");
        if (!string.IsNullOrWhiteSpace(explicitPath)) yield return explicitPath;

        yield return RuntimeFilePath;

        // Ask Windows for the profile rather than trusting the LOCALAPPDATA env var, which a
        // parent process may have redirected.
        var userProfile = Environment.GetEnvironmentVariable("USERPROFILE");
        if (!string.IsNullOrWhiteSpace(userProfile))
            yield return Path.Combine(userProfile, "AppData", "Local", "DSPBridge", "runtime.json");

        // Workspace-local redirect used by tools\dspenv.ps1 (fallback only). Derived from
        // this assembly's location: <repo>\DspMcpBridge\bin\Release\net10.0\ -> <repo>.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 6 && dir != null; i++, dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "tools", "localappdata", "DSPBridge", "runtime.json");
            if (File.Exists(candidate)) { yield return candidate; break; }
        }
    }

    /// <summary>True when a discovery file is currently present.</summary>
    public bool HasRuntimeFile => TryLoadRuntimeInfo(out _, out _);

    /// <summary>Schema version reported by the last successful discovery, for diagnostics.</summary>
    public int SchemaVersion => _info?.SchemaVersion ?? 0;

    public bool AllowWrites
    {
        get
        {
            TryLoadRuntimeInfo(out var info, out _);
            return info?.AllowWrites ?? false;
        }
    }

    public string DescribeStatus()
    {
        if (TryLoadRuntimeInfo(out var info, out var why))
            return $"bridge found on port {info!.Port} (pid {info.Pid}, schemaVersion {info.SchemaVersion})";
        return why ?? "bridge not found";
    }

    private bool TryLoadRuntimeInfo(out DspRuntimeInfo info, out string reason)
    {
        info = null;
        reason = null;

        foreach (var path in CandidateRuntimePaths())
        {
            try
            {
                if (!File.Exists(path)) continue;

                // UTF-8 explicitly, for the same reason as StubMode.Read: the bridge writes
                // runtime.json with a UTF-8 (no BOM) encoder and can contain non-ASCII paths
                // such as gameRoot.
                using var doc = JsonDocument.Parse(File.ReadAllText(path, System.Text.Encoding.UTF8));
                var root = doc.RootElement;

                if (!root.TryGetProperty("port", out var portEl) || !root.TryGetProperty("token", out var tokenEl))
                {
                    reason = $"{path} exists but has no port/token (schema drift?)";
                    continue;
                }

                var pid = root.TryGetProperty("pid", out var pidEl) ? pidEl.GetInt32() : 0;
                var schema = root.TryGetProperty("schemaVersion", out var svEl) ? svEl.GetInt32() : 0;
                var gameRoot = root.TryGetProperty("gameRoot", out var grEl) ? grEl.GetString() : null;
                var allowWrites = root.TryGetProperty("allowWrites", out var awEl) && awEl.ValueKind == JsonValueKind.True;
                DateTimeOffset? startedAt = null;
                if (root.TryGetProperty("startedAt", out var saEl) && saEl.ValueKind == JsonValueKind.String
                    && DateTimeOffset.TryParse(saEl.GetString(), out var parsed))
                    startedAt = parsed;

                info = new DspRuntimeInfo(portEl.GetInt32(), tokenEl.GetString(), pid, schema, gameRoot, allowWrites, startedAt);
                _lastError = null;
                return true;
            }
            catch (Exception ex)
            {
                reason = $"could not read {path}: {ex.Message}";
            }
        }

        return false;
    }

    /// <summary>
    /// Returns the discovery info, refreshing from disk first so a restarted game is picked
    /// up automatically (and a stale pid is detected).
    /// </summary>
    private DspRuntimeInfo Resolve()
    {
        if (!TryLoadRuntimeInfo(out var info, out var reason))
        {
            lock (_gate) { _info = null; _lastError = reason; }
            throw new DspUnavailableException(
                "游戏未运行：没有找到 %LOCALAPPDATA%\\DSPBridge\\runtime.json。\n" +
                "请先启动戴森球计划，并确认 DspBridge 插件已加载（BepInEx\\LogOutput.log 里搜 [DspBridge]）。\n" +
                $"（查询过的路径：{string.Join("; ", CandidateRuntimePaths())}）" +
                (reason is null ? "" : $"\n最后原因：{reason}"));
        }

        if (info.Pid > 0)
        {
            try
            {
                using var p = Process.GetProcessById(info.Pid);
                if (p.HasExited)
                    throw new DspUnavailableException(
                        $"runtime.json 指向的进程 {info.Pid} 已退出，游戏可能刚刚关闭。请重新启动游戏。");
            }
            catch (ArgumentException)
            {
                throw new DspUnavailableException(
                    $"runtime.json 指向的进程 {info.Pid} 不存在，游戏可能已退出（或 runtime.json 是旧文件）。请重新启动游戏。");
            }
            catch (InvalidOperationException)
            {
                // Process exists but we cannot query it -- treat as alive and let HTTP decide.
            }
        }

        lock (_gate) { _info = info; }
        return info;
    }

    /// <summary>GET /health -- cheapest liveness probe; no Unity access in the game process.</summary>
    public async Task<string> HealthAsync(CancellationToken ct)
    {
        var stub = StubMode.Read("get_health");
        if (stub is not null) return stub;

        var info = Resolve();
        using var req = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{info.Port}/health");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + info.Token);

        using var resp = await SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        EnsureJson(body, resp.StatusCode);
        return body;
    }

    /// <summary>GET /state -- the main-thread snapshot; never blocks the game.</summary>
    public async Task<string> StateAsync(CancellationToken ct)
    {
        var stub = StubMode.Read("get_state");
        if (stub is not null) return stub;

        var info = Resolve();
        using var req = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{info.Port}/state");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + info.Token);

        using var resp = await SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        EnsureJson(body, resp.StatusCode);
        return body;
    }

    /// <summary>POST /command -- dispatch an op. Business errors come back as JSON, not exceptions.</summary>
    public async Task<string> CommandAsync(string op, object args, CancellationToken ct)
    {
        var stub = StubMode.Read(op);
        // The stub is validated exactly like a real response would be, otherwise the
        // malformed-payload path could only be tested by hijacking a real port.
        if (stub is not null) { EnsureJson(stub, HttpStatusCode.OK); return stub; }

        var payload = new Dictionary<string, object>(StringComparer.Ordinal) { ["op"] = op };
        if (args is not null) payload["args"] = args;

        var info = Resolve();

        using var resp = await SendCommandAsync(info, payload, ct).ConfigureAwait(false);

        // The bridge rotates its token on every game start. A 401 therefore usually means
        // "the game restarted"; re-read runtime.json once before reporting failure.
        if (resp.StatusCode == HttpStatusCode.Unauthorized)
        {
            resp.Dispose();
            _log.LogInformation("得到 401，重新读取 runtime.json 后重试一次（游戏可能已重启，token 已轮换）。");
            var refreshed = Resolve();
            using var retry = await SendCommandAsync(refreshed, payload, ct).ConfigureAwait(false);
            var retryBody = await retry.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (retry.StatusCode == HttpStatusCode.Unauthorized)
                throw new DspUnavailableException(
                    "鉴权失败（401）：runtime.json 里的 token 与游戏内插件不一致。" +
                    "游戏可能正在切换存档，或 runtime.json 是另一个实例写的。请重试，或重启游戏。");
            EnsureJson(retryBody, retry.StatusCode);
            return retryBody;
        }

        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        EnsureJson(body, resp.StatusCode);
        return body;
    }

    private async Task<HttpResponseMessage> SendCommandAsync(DspRuntimeInfo info, object payload, CancellationToken ct)
    {
        var req = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{info.Port}/command")
        {
            Content = JsonContent.Create(payload)
        };
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + info.Token);
        return await SendAsync(req, ct).ConfigureAwait(false);
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        try
        {
            return await _http.SendAsync(req, ct).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            _lastError = ex.Message;
            throw new DspUnavailableException(
                $"无法连接游戏内桥接（{req.RequestUri}）：{ex.Message}\n" +
                "常见原因：游戏已退出；游戏正在加载画面；端口被另一个程序占用。" +
                "请确认游戏正在运行且已进入存档。", ex);
        }
        catch (TaskCanceledException ex) when (!ct.IsCancellationRequested)
        {
            _lastError = ex.Message;
            throw new DspUnavailableException(
                "请求超时（35 秒）。游戏可能严重卡顿、正在读档，或窗口失焦被 Unity 暂停。" +
                "请切回游戏窗口后重试。", ex);
        }
    }

    private static void EnsureJson(string body, HttpStatusCode status)
    {
        if (string.IsNullOrWhiteSpace(body))
            throw new DspUnavailableException($"桥接返回了空响应（HTTP {(int)status}）。游戏可能正在退出。");

        // Guards against something that is NOT our bridge answering on that port: a stale
        // runtime.json pointing at a recycled port would otherwise feed the model an HTML
        // error page or a fragment of unrelated output.
        var trimmed = body.TrimStart();
        if (!trimmed.StartsWith('{') && !trimmed.StartsWith('['))
            throw new DspUnavailableException(
                $"桥接返回了非 JSON 内容（HTTP {(int)status}）：{trimmed[..Math.Min(120, trimmed.Length)]}\n" +
                "该端口可能被其它程序占用，或 runtime.json 指向了错误的实例。");

        try
        {
            using var _ = JsonDocument.Parse(body);
        }
        catch (JsonException ex)
        {
            throw new DspUnavailableException(
                $"桥接返回的内容不是合法 JSON（HTTP {(int)status}）：{ex.Message}\n" +
                "游戏可能正在写入过程中被查询，或端口被其它程序占用。重试一次；" +
                "若持续失败，用 dsp_tail_log 查看 BepInEx 日志。", ex);
        }
    }

    /// <summary>Raised for conditions the user can act on; rendered as a tool error, not a crash.</summary>
    public sealed class DspUnavailableException : Exception
    {
        public DspUnavailableException(string message) : base(message) { }
        public DspUnavailableException(string message, Exception inner) : base(message, inner) { }
    }
}

/// <summary>
/// File-backed fake bridge.
///
/// Setting <c>DSP_BRIDGE_STUB=&lt;json file&gt;</c> makes every call read a canned response
/// from that file instead of talking to the game. This exists so the whole MCP layer can be
/// verified end to end (handshake, tools/list, tools/call, error text) without a running
/// game -- the acceptance checklist needs an offline path anyway.
///
/// Expected file shape:
/// <code>
/// {
///   "get_health": { ... JSON payload ... },
///   "get_state":  { "localPlanet": { "name": "Stub\u0007Planet" } },
///   "_raw":       { "some_op": "{\"not\":\"re-serialized\"}" },
///   "_default":   { "error": "not_implemented" }
/// }
/// </code>
///
/// Values are parsed and re-serialized, so escapes in the file behave exactly like escapes
/// coming off the wire (this is what lets the sanitizer test use real control characters).
/// <c>_raw</c> passes a value through byte-for-byte, for exercising malformed payloads.
/// </summary>
internal static class StubMode
{
    public static string Path => Environment.GetEnvironmentVariable("DSP_BRIDGE_STUB");

    public static bool Enabled => !string.IsNullOrWhiteSpace(Path);

    public static string Read(string op)
    {
        if (!Enabled) return null;

        try
        {
            // Read as UTF-8 explicitly: File.ReadAllText would fall back to the system ANSI
            // code page (gb2312 here), turning every Chinese planet name into mojibake.
            using var doc = JsonDocument.Parse(File.ReadAllText(Path, System.Text.Encoding.UTF8));
            var root = doc.RootElement;

            // Verbatim escape hatch, checked first.
            if (root.TryGetProperty("_raw", out var rawSection) && rawSection.ValueKind == JsonValueKind.Object
                && rawSection.TryGetProperty(op, out var rawValue))
                return rawValue.GetString();

            if (root.TryGetProperty(op, out var picked))
                return picked.GetRawText();

            if (root.TryGetProperty("_default", out var fallback))
                return fallback.GetRawText();

            return null;
        }
        catch (Exception ex)
        {
            return JsonSerializer.Serialize(new { error = "stub_read_failed", detail = ex.Message, path = Path });
        }
    }
}
