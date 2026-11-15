using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using UnityEngine;

namespace DspBridge
{
    /// <summary>
    /// The in-game half of the runtime debugging environment: a loopback-only HTTP endpoint
    /// that lets an out-of-process MCP server read game state and issue a small, audited set
    /// of debug actions without restarting the game.
    ///
    /// Design constraints, all of them deliberate (see DSP-MOD-开发环境说明.md section 5.1):
    ///
    ///  * The listener thread only parses and queues. Every Unity API call happens on the
    ///    main thread -- BepInEx source: "Most of Unity API can not be accessed while
    ///    running on another thread!".
    ///  * The listener and the first main-thread dispatch are both deferred to the first
    ///    Update(): ThreadingHelper assigns its _mainThread in its own Update, so
    ///    InvokeRequired is unconditionally true inside Awake/Start and a dispatch there
    ///    would silently fail (doc 5.1 constraint 3).
    ///  * Read-only traffic is served from a snapshot string rebuilt every N frames on the
    ///    main thread, so a hitching game can never make a read time out. Writes use a
    ///    synchronous main-thread dispatch because the caller needs the real outcome.
    ///  * Zero third-party dependencies: only BCL HttpListener plus hand-written JSON.
    ///  * Loopback prefix only (http://127.0.0.1:port/). No URL ACL, no admin, no firewall
    ///    rule, no exposure to the LAN.
    /// </summary>
    [BepInPlugin(Guid, "DSP Runtime Bridge", "1.0.2")]
    public class BridgePlugin : BaseUnityPlugin
    {
        public const string Guid = "org.yourname.dspbridge";

        internal static BridgePlugin Instance;
        internal static ManualLogSource Log;

        /// <summary>Game root, e.g. C:\...\Dyson Sphere Program (derived from Application.dataPath).</summary>
        internal static string GameRoot;

        private ConfigEntry<int> _port;
        private ConfigEntry<string> _token;
        private ConfigEntry<bool> _allowWrites;
        private ConfigEntry<int> _snapshotEveryFrames;
        private ConfigEntry<bool> _auditLogToFile;

        private HttpListener _listener;
        private Thread _listenerThread;
        private volatile bool _started;
        private volatile bool _stopping;

        private int _frameCounter;
        private int _snapshotInterval = GameSnapshot.RefreshEveryFrames;

        /// <summary>Fallback channel for main-thread work when ThreadingHelper cannot be used yet.</summary>
        private static readonly ConcurrentQueue<Action> MainQueue = new ConcurrentQueue<Action>();

        /// <summary>PID of the process that owns this plugin instance (used to report staleness).</summary>
        private int _pid;

        private void Awake()
        {
            Instance = this;
            Log = Logger;
            _pid = System.Diagnostics.Process.GetCurrentProcess().Id;

            GameRoot = ResolveGameRoot();

            _port = Config.Bind("Bridge", "Port", 17890,
                "本地监听端口；只绑 127.0.0.1（改端口后 MCP server 无需改配置，它读 runtime.json）");
            _token = Config.Bind("Bridge", "Token", "",
                "共享密钥；留空则每次启动随机生成（写入 %LOCALAPPDATA%\\DSPBridge\\runtime.json）");
            _allowWrites = Config.Bind("Bridge", "AllowWrites", false,
                "L1 可逆写操作总开关（set_pause）。默认 false = 只读，最安全");
            _snapshotEveryFrames = Config.Bind("Bridge", "SnapshotEveryFrames", GameSnapshot.RefreshEveryFrames,
                "只读快照刷新间隔（帧）。30 ≈ 0.5 秒 @60fps");
            _auditLogToFile = Config.Bind("Bridge", "AuditLogToFile", true,
                "把每个命令追加到 BepInEx\\DspBridge-audit.log（token 会被抹掉）");

            if (string.IsNullOrEmpty(_token.Value))
            {
                _token.Value = System.Guid.NewGuid().ToString("N");
                Config.Save();
                Log.LogInfo("[DspBridge] 已生成新的共享 token 并保存到配置。");
            }

            CommandRouter.AllowWrites = _allowWrites.Value;
            CommandRouter.SecretToRedact = _token.Value;

            _snapshotInterval = _snapshotEveryFrames.Value <= 0 ? GameSnapshot.RefreshEveryFrames : _snapshotEveryFrames.Value;

            // Log the process id, never the token.
            Log.LogInfo($"[DspBridge] 配置就绪 pid={_pid} 端口={_port.Value} writes={_allowWrites.Value} " +
                        $"gameRoot={GameRoot}（监听器与首次主线程投递都推迟到首帧之后）");
        }

        /// <summary>
        /// Deferred start + per-frame work. The snapshot is rebuilt here, on the main thread,
        /// and published as one immutable string.
        /// </summary>
        private void Update()
        {
            if (!_started)
            {
                _started = true;
                StartHttpServer();
            }

            // Fallback main-thread channel (only used before ThreadingHelper is usable).
            DrainMainQueue();

            if (++_frameCounter >= _snapshotInterval)
            {
                _frameCounter = 0;
                try
                {
                    // Rebuilt on the main thread, published by whole-string replacement.
                    // Readers can never observe a torn snapshot and never block this frame.
                    SnapshotHolder.Value = GameSnapshot.BuildStateJson();
                }
                catch (Exception ex)
                {
                    Log.LogWarning($"[DspBridge] 快照刷新失败（保留上一份，HTTP 照常返回）：{ex.Message}");
                }
            }
        }

        private void OnDestroy() => Shutdown("OnDestroy");

        private void OnApplicationQuit() => Shutdown("OnApplicationQuit");

        private void Shutdown(string reason)
        {
            if (_stopping) return;
            _stopping = true;

            try
            {
                // Stop() makes the blocking GetContext() throw, which ends the loop
                // naturally. Thread.Abort is never used (doc 5.7 #4).
                _listener?.Stop();
                _listener?.Close();
            }
            catch (Exception)
            {
                // Exit path: nothing useful left to do with the error.
            }

            Log?.LogInfo($"[DspBridge] 已停止 HTTP 监听（{reason}）。");
            CleanupRuntimeFile();
        }

        /// <summary>
        /// Remove the discovery file this process published, so that "runtime.json exists"
        /// really means "a bridge is alive". The pid is checked first: if a newer instance has
        /// already replaced the file (fast relaunch), that instance's file is left alone.
        /// </summary>
        private void CleanupRuntimeFile()
        {
            try
            {
                var path = RuntimeFile.FilePath;
                if (!File.Exists(path)) return;

                var text = File.ReadAllText(path, Encoding.UTF8);
                if (!RuntimeFileBelongsTo(text, _pid)) return;

                File.Delete(path);
                Log?.LogInfo("[DspBridge] 已删除 runtime.json（进程已退出）。");
            }
            catch (Exception ex)
            {
                Log?.LogWarning($"[DspBridge] 删除 runtime.json 失败：{ex.Message}");
            }
        }

        /// <summary>Cheap parse of the one field we care about; runtime.json is a flat object.</summary>
        private static bool RuntimeFileBelongsTo(string json, int pid)
        {
            var idx = json.IndexOf("\"pid\"", StringComparison.Ordinal);
            if (idx < 0) return false;

            idx += 5;
            while (idx < json.Length && (json[idx] == ' ' || json[idx] == ':')) idx++;

            var start = idx;
            while (idx < json.Length && json[idx] >= '0' && json[idx] <= '9') idx++;
            if (idx == start) return false;

            return int.Parse(json.Substring(start, idx - start), System.Globalization.CultureInfo.InvariantCulture) == pid;
        }

        private void StartHttpServer()
        {
            var port = _port.Value;
            if (port <= 0 || port > 65535)
            {
                Log.LogError($"[DspBridge] 端口 {port} 非法，监听未启动。");
                return;
            }

            _listener = new HttpListener();
            // The trailing slash is mandatory; and 127.0.0.1 (not localhost/+/*) keeps this
            // out of URL-ACL and firewall territory (doc 5.7 #16).
            _listener.Prefixes.Add($"http://127.0.0.1:{port}/");

            try
            {
                _listener.Start();
            }
            catch (Exception ex)
            {
                Log.LogError($"[DspBridge] 端口 {port} 绑定失败（可能被另一个游戏实例或其它程序占用）：{ex.Message}");
                _listener = null;
                return;
            }

            _listenerThread = new Thread(Loop)
            {
                IsBackground = true,          // must be background or the Unity process cannot exit
                Name = "DspBridge.Http"
            };
            _listenerThread.Start();

            Log.LogInfo($"[DspBridge] 已监听 http://127.0.0.1:{port}/ （只读快照 + /command）");
            WriteRuntimeFile(port);
        }

        private void Loop()
        {
            while (!_stopping)
            {
                HttpListenerContext ctx;
                try
                {
                    ctx = _listener.GetContext();
                }
                catch (HttpListenerException) { break; }        // raised by Stop()
                catch (ObjectDisposedException) { break; }      // raised by Close()
                catch (InvalidOperationException) { break; }    // listener not started / already closed
                catch (Exception ex)
                {
                    Log.LogWarning($"[DspBridge] 接受连接异常：{ex.Message}");
                    continue;
                }

                // Parse on a pool thread; blocking here would serialise keep-alive clients.
                ThreadPool.QueueUserWorkItem(_ => Handle(ctx));
            }
        }

        private void Handle(HttpListenerContext ctx)
        {
            try
            {
                if (!Auth(ctx))
                {
                    Respond(ctx, 401, "{\"error\":\"unauthorized\"}");
                    return;
                }

                var path = ctx.Request.Url?.AbsolutePath?.TrimEnd('/') ?? "";
                var method = ctx.Request.HttpMethod?.ToUpperInvariant() ?? "GET";

                if (path.Length == 0) path = "/";

                switch (path)
                {
                    case "/":
                    case "/health":
                        // Pure liveness; no Unity access at all, so it answers even mid-load.
                        Respond(ctx, 200, GameSnapshot.HealthJson());
                        return;

                    case "/state":
                    case "/snapshot":
                    {
                        // Read-only, served from the main-thread snapshot: cannot block, cannot
                        // time out, never touches a Unity object on this thread.
                        var body = SnapshotHolder.Value;
                        if (string.IsNullOrEmpty(body)) body = "{}";
                        Respond(ctx, 200, body);
                        return;
                    }

                    case "/command":
                    {
                        if (method != "POST")
                        {
                            Respond(ctx, 200, "{\"error\":\"method_not_allowed\",\"hint\":\"POST /command\"}");
                            return;
                        }

                        string payload;
                        using (var sr = new StreamReader(ctx.Request.InputStream, Encoding.UTF8))
                            payload = sr.ReadToEnd();

                        if (payload.Length > 65536)
                        {
                            Respond(ctx, 200, "{\"error\":\"payload_too_large\"}");
                            return;
                        }

                        // Unity work is dispatched to the main thread with a generous timeout:
                        // a hitching game or a loading screen can stall for a long while, and a
                        // short timeout would be misread by the LLM as "game not responding" (5.7 #5).
                        var json = InvokeOnMain(() => CommandRouter.Execute(payload), 30000);
                        Respond(ctx, 200, json);
                        return;
                    }

                    default:
                        Respond(ctx, 404, "{\"error\":\"not_found\",\"hint\":\"/health /state /command\"}");
                        return;
                }
            }
            catch (Exception ex)
            {
                Log.LogError($"[DspBridge] 请求处理失败：{ex}");
                try { Respond(ctx, 500, "{\"error\":\"handler_failure\"}"); } catch { /* client gone */ }
            }
        }

        /// <summary>Constant-time bearer comparison, so the token cannot be probed byte by byte.</summary>
        private bool Auth(HttpListenerContext ctx)
        {
            var header = ctx.Request.Headers["Authorization"];
            var expected = "Bearer " + _token.Value;
            if (header == null || header.Length != expected.Length) return false;

            var diff = 0;
            for (var i = 0; i < header.Length; i++) diff |= header[i] ^ expected[i];
            return diff == 0;
        }

        /// <summary>
        /// Run an action on the Unity main thread and wait for its result.
        ///
        /// This is the ONLY place in the plugin that touches game objects, and the only
        /// reason it is safe is that it always ends up executing inside Update().
        /// </summary>
        internal static string InvokeOnMain(Func<string> action, int timeoutMs = 2000)
        {
            if (action == null) return "{\"error\":\"null_action\"}";

            var box = new ResultBox();
            Action work = () => RunBoxed(box, action, timeoutMs);

            try
            {
                var helper = ThreadingHelper.Instance;
                if (helper != null && !helper.InvokeRequired)
                {
                    // Already on the main thread (e.g. called from a Harmony patch): run inline.
                    RunBoxed(box, action, timeoutMs);
                }
                else if (helper != null)
                {
                    helper.StartSyncInvoke(() => RunBoxed(box, action, timeoutMs));
                }
                else
                {
                    // ThreadingHelper is not constructed yet: use the queue that Update() drains.
                    MainQueue.Enqueue(work);
                }
            }
            catch (Exception)
            {
                // ThreadingHelper threw (it is not ready yet). Fall through to the queue so a
                // request that arrives in the first frames is delayed by one frame instead of
                // failing outright.
                MainQueue.Enqueue(work);
            }

            if (!box.Done.Wait(timeoutMs))
            {
                // Belt and braces: hand the work to the per-frame queue too. RunBoxed is
                // idempotent (it no-ops once the box is complete), so this cannot double-run,
                // and the caller still gets its answer if the main thread wakes up late.
                MainQueue.Enqueue(work);
                return "{\"error\":\"timeout\",\"hint\":\"主线程未在超时内响应：游戏可能卡顿、正在加载，或窗口失去焦点被 Unity 暂停\"}";
            }

            if (box.Error != null) return "{\"error\":" + Json.Str(box.Error) + "}";
            return box.Value ?? "{\"error\":\"empty_result\"}";
        }

        private static void RunBoxed(ResultBox box, Func<string> action, int timeoutMs)
        {
            if (box.Done.IsSet) return;      // already executed (e.g. via the sync path)

            try
            {
                box.Value = action();
            }
            catch (Exception ex)
            {
                box.Error = ex.Message;
                Log?.LogError($"[DspBridge] 主线程动作异常：{ex}");
            }
            finally
            {
                try { box.Done.Set(); } catch (ObjectDisposedException) { /* caller already gave up */ }
            }
        }

        private static void DrainMainQueue()
        {
            while (MainQueue.TryDequeue(out var a))
            {
                try { a(); }
                catch (Exception ex) { Log?.LogError($"[DspBridge] 队列动作异常：{ex}"); }
            }
        }

        private void Respond(HttpListenerContext ctx, int status, string json)
        {
            try
            {
                var buf = Encoding.UTF8.GetBytes(json ?? "{}");
                ctx.Response.StatusCode = status;
                ctx.Response.ContentType = "application/json; charset=utf-8";
                ctx.Response.ContentLength64 = buf.Length;
                ctx.Response.OutputStream.Write(buf, 0, buf.Length);
            }
            catch (Exception ex)
            {
                Log.LogWarning($"[DspBridge] 回写响应失败：{ex.Message}");
            }
            finally
            {
                try { ctx.Response.Close(); } catch { /* client already gone */ }
            }
        }

        /// <summary>
        /// Publish port + token so the out-of-process MCP server can discover them.
        /// Written under %LOCALAPPDATA%\DSPBridge\ rather than the plugin folder so it is
        /// never picked up by a Thunderstore package.
        ///
        /// NOTE: the token is plain text here. That is "good enough", not "secure": any
        /// process running as this user can read it. See doc 5.9 for the threat model.
        /// </summary>
        private void WriteRuntimeFile(int port)
        {
            try
            {
                var dir = RuntimeFile.DirPath;
                System.IO.Directory.CreateDirectory(dir);

                var json = new JsonObject()
                    .Add("pid", _pid)
                    .Add("port", port)
                    .Add("token", _token.Value)
                    .Add("schemaVersion", GameSnapshot.SchemaVersion)
                    .Add("gameRoot", GameRoot)
                    .Add("allowWrites", _allowWrites.Value)
                    .Add("unityVersion", Application.unityVersion)
                    .Add("bridgeVersion", "1.0.2")
                    .Add("startedAt", DateTime.UtcNow.ToString("o"))
                    .ToString();

                File.WriteAllText(RuntimeFile.FilePath, json, new UTF8Encoding(false));
                Log.LogInfo($"[DspBridge] 运行时信息已写入 {RuntimeFile.FilePath}");
            }
            catch (Exception ex)
            {
                Log.LogWarning($"[DspBridge] 写 runtime.json 失败（MCP server 将无法自动发现端口/token）：{ex.Message}");
            }
        }

        private static string ResolveGameRoot()
        {
            try
            {
                // Application.dataPath = <game root>\DSPGAME_Data
                var dataPath = Application.dataPath;
                if (!string.IsNullOrEmpty(dataPath))
                {
                    var parent = Directory.GetParent(dataPath);
                    if (parent != null) return parent.FullName;
                }
            }
            catch (Exception) { }

            try
            {
                // Fallback: derive from the plugin's own location (BepInEx\plugins\DspBridge).
                var asmDir = Path.GetDirectoryName(typeof(BridgePlugin).Assembly.Location);
                var plugins = Directory.GetParent(asmDir)?.Parent;
                var gameRoot = plugins?.Parent;
                if (gameRoot != null) return gameRoot.FullName;
            }
            catch (Exception) { }

            return AppDomain.CurrentDomain.BaseDirectory;
        }

        /// <summary>Writes the audit trail next to the BepInEx log (token redacted).</summary>
        internal static void AppendAuditFile(string line)
        {
            try
            {
                if (Instance == null || !Instance._auditLogToFile.Value) return;
                var path = Path.Combine(GameRoot, "BepInEx", "DspBridge-audit.log");
                File.AppendAllText(path, CommandRouter.Redact(line) + Environment.NewLine, new UTF8Encoding(false));
            }
            catch (Exception)
            {
                // Auditing must never break the request path.
            }
        }
    }

    /// <summary>
    /// Holds the published snapshot string. Kept separate from the plugin instance so the
    /// HTTP thread never dereferences the MonoBehaviour (which would be a Unity API access
    /// off the main thread).
    /// </summary>
    internal static class SnapshotHolder
    {
        private static volatile string _value = "{}";
        public static string Value
        {
            get => _value;
            set { if (!string.IsNullOrEmpty(value)) _value = value; }
        }
    }

    /// <summary>
    /// Shared discovery file location. The MCP server searches the real
    /// %LOCALAPPDATA%\DSPBridge first and the workspace-local redirect second, so the two
    /// processes agree even when the build scripts redirect LOCALAPPDATA into the repo.
    /// </summary>
    internal static class RuntimeFile
    {
        public const string FolderName = "DSPBridge";
        public const string FileName = "runtime.json";

        public static string DirPath =>
            System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), FolderName);

        public static string FilePath => System.IO.Path.Combine(DirPath, FileName);
    }
}
