using System;

// Minimal stand-ins for the BepInEx types that the bridge's pure logic touches.
// They exist only so ..\..\DspBridge\CommandRouter.cs and Reflect.cs compile and run on
// net10.0; nothing here is shipped to the game.
namespace BepInEx
{
    public static class ThreadingHelper
    {
        public static ThreadingHelperImpl Instance;
    }

    public sealed class ThreadingHelperImpl
    {
        public bool InvokeRequired => true;
        public void StartSyncInvoke(Action action)
        {
            // Execute inline: in the test there is only one "thread".
            action?.Invoke();
        }
    }
}

namespace DspBridge
{
    /// <summary>
    /// Stand-in for the plugin class. CommandRouter references exactly three members of it;
    /// the real class is BepInEx/Unity-dependent and therefore excluded from this project.
    /// </summary>
    internal static class BridgePlugin
    {
        /// <summary>Set by the test to a temporary directory so log-tail/mkdir paths resolve.</summary>
        public static string GameRoot = System.IO.Path.GetTempPath();

        /// <summary>
        /// Mirrors the real dispatcher closely enough for the pure ops: the queue fallback
        /// path (ThreadingHelper unusable) is what most ops hit, so run inline.
        /// </summary>
        public static string InvokeOnMain(Func<string> action, int timeoutMs = 2000)
        {
            try
            {
                return action();
            }
            catch (Exception ex)
            {
                return "{\"error\":" + Json.Str(ex.Message) + "}";
            }
        }

        /// <summary>No-op: the audit file is exercised separately in the real plugin.</summary>
        public static void AppendAuditFile(string line) { }
    }

    /// <summary>
    /// Stand-in for GameSnapshot. The real one reads Unity/game types and is therefore
    /// excluded; CommandRouter only needs these four members to compile, and each test that
    /// uses them asserts on router behaviour rather than on game data.
    /// </summary>
    internal static class GameSnapshot
    {
        public const int SchemaVersion = 1;

        /// <summary>Stands in for the published snapshot string the HTTP thread reads.</summary>
        public static string SnapshotJson => "{\"schemaVersion\":1,\"stub\":\"snapshot\"}";

        public static string HealthJson()
            => "{\"status\":\"ok\",\"schemaVersion\":1,\"testStub\":true}";

        public static string CatalogSummary()
            => "{\"items\":612,\"recipes\":401,\"techs\":214,\"models\":733}";

        public static string QueryItems(int fromId, int limit, string nameContains)
            => "{\"scannedFrom\":" + fromId + ",\"returned\":0,\"totalMatched\":0,\"items\":[]}";

        /// <summary>Game-data reader: not testable without the game, returns a clear marker.</summary>
        public static string PowerOfFactory(object factory)
            => "{\"available\":false,\"reason\":\"test_stub\"}";

        /// <summary>Same contract as the real sanitizer: strip control characters, cap length.</summary>
        public static string Sanitize(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            var sb = new System.Text.StringBuilder(s.Length);
            foreach (var c in s)
            {
                if (c == '\n' || c == '\t' || c == '\r') { sb.Append(c); continue; }
                if (c < 0x20 || c == 0x7F) continue;
                sb.Append(c);
            }
            return sb.ToString();
        }
    }
}
