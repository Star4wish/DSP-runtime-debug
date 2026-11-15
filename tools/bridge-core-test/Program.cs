using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using DspBridge;

namespace BridgeCoreTest;

/// <summary>
/// Executable checks for the bridge plugin's game-independent logic.
///
/// These are the paths where a bug is either a crash inside the game's Update loop or a
/// security hole, and both are expensive to find by playing the game:
///   * JSON: the bridge parses whatever arrives on the socket, including hostile input.
///   * The op table: closed by default, with an explicit write gate.
///   * Token redaction: the shared token must never appear in anything handed back.
///   * Reflect: a game patch that renames a field must degrade to null, not to an exception.
/// </summary>
internal static class Program
{
    private static int _passed;
    private static readonly List<string> Failures = new List<string>();

    private static int Main()
    {
        Console.WriteLine("=== DspBridge core logic checks (net10.0, no game, no Unity) ===");

        JsonWriterEscapesControlCharacters();
        JsonParserRoundTrips();
        JsonParserIsHostileInputSafe();
        RouterRejectsUnknownOp();
        RouterRejectsMissingOp();
        RouterBlocksWritesWhenDisabled();
        WriteGateReadsArgument();
        LogTailRedactsToken();
        LogTailHandlesMissingLog();
        ReflectDegradesOnRenamedMembers();
        JsonObjectEmitsValidJson();

        Console.WriteLine();
        Console.WriteLine("passed: " + _passed + ", failed: " + Failures.Count);

        if (Failures.Count == 0)
        {
            Console.WriteLine("ALL CORE CHECKS PASSED");
            return 0;
        }

        Console.WriteLine("FAILED:");
        foreach (var f in Failures) Console.WriteLine("  - " + f);
        return 1;
    }

    // ------------------------------------------------------------------ checks

    private static void JsonWriterEscapesControlCharacters()
    {
        var raw = "a\"b\\c\nd\te\u0001f\u2028g";
        var json = Json.Str(raw);
        Check("Json.Str escapes control characters",
            !json.Contains('\u0001') && !json.Contains('\u2028') && json.StartsWith("\""));

        // Round-trip through the parser to prove the escaped form is still the same string.
        var parsed = Json.Parse("{\"v\":" + json + "}");
        Check("Json.Str output round-trips",
            parsed != null && parsed["v"].AsString() == raw);
    }

    private static void JsonParserRoundTrips()
    {
        var text = "{\"op\":\"x\",\"args\":{\"s\":\"a\\\"b\",\"n\":-12.5,\"b\":true,\"nul\":null,"
                 + "\"arr\":[1,2,3],\"u\":\"\\u4e2d\\u6587\",\"empty\":{},\"earr\":[]}}";
        var v = Json.Parse(text);

        Check("nested object parsed", v != null && v["op"].AsString() == "x");
        Check("escaped quote decoded", v["args"]["s"].AsString() == "a\"b");
        Check("negative number parsed", Math.Abs(v["args"]["n"].AsDouble() - (-12.5)) < 1e-9);
        Check("bool parsed", v["args"]["b"].AsBool());
        Check("null parsed", v["args"]["nul"].IsNull);
        Check("array count", v["args"]["arr"].Count == 3);
        Check("unicode escape decoded", v["args"]["u"].AsString() == "中文");
        Check("empty object", v["args"]["empty"].IsObject && v["args"]["empty"].Count == 0);
        Check("empty array", v["args"]["earr"].Count == 0);
        Check("missing key yields Null (no exception)", v["nope"]["deeper"].IsNull);
    }

    private static void JsonParserIsHostileInputSafe()
    {
        foreach (var bad in new[]
                 {
                     null, "", "   ", "{", "}", "[", "]", "{\"a\"}", "{\"a\":}", "{'a':1}",
                     "{\"a\":1,}", "\"unterminated", "{\"a\":\"\\u00zz\"}", "{\"a\":\"\\q\"}",
                     new string('{', 500), new string('[', 500), "{\"a\":[1,2,}"
                 })
        {
            try
            {
                var v = Json.Parse(bad);
                // Any result is acceptable as long as it does not throw and is not a
                // partially-built object pretending to be valid.
                Check("hostile input did not throw: " + Describe(bad), true);
                _ = v == null ? 0 : v.Count;
            }
            catch (Exception ex)
            {
                Check("hostile input did not throw: " + Describe(bad), false, ex.GetType().Name);
            }
        }

        // Deep nesting must not blow the stack (recursive-descent parser with a depth guard
        // is not required, but a StackOverflowException would kill the game process).
        try
        {
            var deep = new StringBuilder();
            for (var i = 0; i < 200; i++) deep.Append("{\"a\":");
            deep.Append("1");
            for (var i = 0; i < 200; i++) deep.Append('}');
            Json.Parse(deep.ToString());
            Check("200-level nesting survived", true);
        }
        catch (Exception ex)
        {
            Check("200-level nesting survived", false, ex.GetType().Name);
        }
    }

    private static void RouterRejectsUnknownOp()
    {
        var json = CommandRouter.Execute("{\"op\":\"definitely_not_a_real_op\"}");
        Check("unknown op rejected", json.Contains("unknown_or_disabled_op"), json);

        // A hostile op name must be echoed back escaped, never executed.
        var hostile = CommandRouter.Execute("{\"op\":\"x\\\"y\\\\z\"}");
        Check("hostile op name is echoed escaped",
            hostile.Contains("unknown_or_disabled_op") && Json.Parse(hostile) != null, hostile);
    }

    private static void RouterRejectsMissingOp()
    {
        var json = CommandRouter.Execute("{}");
        Check("missing op rejected", json.Contains("unknown_or_disabled_op"), json);

        var garbage = CommandRouter.Execute("this is not json at all");
        Check("non-JSON body rejected", garbage.Contains("unknown_or_disabled_op"), garbage);

        var partial = CommandRouter.Execute("{\"op\":");
        Check("truncated body rejected", partial.Contains("unknown_or_disabled_op"), partial);
    }

    private static void RouterBlocksWritesWhenDisabled()
    {
        CommandRouter.AllowWrites = false;
        var json = CommandRouter.Execute("{\"op\":\"set_pause\",\"args\":{\"paused\":true}}");
        Check("set_pause refused while AllowWrites=false",
            json.Contains("writes_disabled"), json);

        // The read-only ops must keep working regardless of the write switch.
        var health = CommandRouter.Execute("{\"op\":\"get_health\"}");
        Check("get_health still allowed", health.Contains("\"status\":\"ok\""), health);
    }

    private static void WriteGateReadsArgument()
    {
        // With writes enabled the op reaches the game action. GameMain does not exist here,
        // so the expected outcome is a clean, readable error rather than a crash.
        CommandRouter.AllowWrites = true;
        try
        {
            var json = CommandRouter.Execute("{\"op\":\"set_pause\",\"args\":{\"paused\":true}}");
            Check("set_pause passes the gate and fails cleanly without a game",
                json.Contains("GameMain type not found") || json.Contains("error"), json);
        }
        finally
        {
            CommandRouter.AllowWrites = false;
        }
    }

    /// <summary>
    /// A writable scratch directory for tests that need real files.
    ///
    /// %TEMP% is the normal choice, but a locked-down machine or a sandboxed CI runner can
    /// deny writes there (UnauthorizedAccessException). Fall back to the build output folder
    /// and then the current directory so the suite still runs everywhere.
    /// </summary>
    private static string CreateScratchDir(string prefix)
    {
        var candidates = new[]
        {
            Path.GetTempPath(),
            AppContext.BaseDirectory,
            Directory.GetCurrentDirectory()
        };
        foreach (var candidate in candidates)
        {
            if (string.IsNullOrWhiteSpace(candidate)) continue;
            var dir = Path.Combine(candidate, prefix + "-" + Guid.NewGuid().ToString("N"));
            try { Directory.CreateDirectory(dir); return dir; }
            catch (Exception) { /* try the next candidate */ }
        }
        throw new InvalidOperationException("no writable scratch directory found (tried TEMP, base dir, cwd)");
    }

    private static void LogTailRedactsToken()
    {
        const string token = "0123456789abcdef0123456789abcdef";

        var root = CreateScratchDir("bridge-core-test");
        var logDir = Path.Combine(root, "BepInEx");
        Directory.CreateDirectory(logDir);
        var logPath = Path.Combine(logDir, "LogOutput.log");

        File.WriteAllLines(logPath, new[]
        {
            "[Info   :DspBridge] 已监听 http://127.0.0.1:17890/",
            "[Debug  :DspBridge] Authorization: Bearer " + token,
            "runtime.json token=" + token
        }, new UTF8Encoding(false));

        try
        {
            var previousRoot = BridgePlugin.GameRoot;
            BridgePlugin.GameRoot = root;
            CommandRouter.SecretToRedact = token;

            var json = CommandRouter.Execute("{\"op\":\"get_log_tail\",\"args\":{\"lines\":10}}");
            Check("log tail returns lines", json.Contains("已监听") || json.Contains("DspBridge"), json);
            Check("log tail redacts the token", !json.Contains(token), json);
            Check("log tail marks the redaction", json.Contains("<redacted>"), json);

            var audit = CommandRouter.Execute("{\"op\":\"get_audit\",\"args\":{\"limit\":5}}");
            var auditJson = Json.Parse(audit);
            Check("audit trail returns an entries array",
                auditJson != null && auditJson["entries"].Count > 0, audit);

            // The entry for the call we just made is appended AFTER the response payload is
            // built, so the newest visible entry is the previous command. Assert ordering and
            // presence instead of self-reference.
            var firstAt = DateTimeOffset.MinValue;
            var lastAt = DateTimeOffset.MinValue;
            var seen = 0;
            foreach (var e in auditJson["entries"].Items)
            {
                var at = DateTimeOffset.Parse(e["atUtc"].AsString(),
                    System.Globalization.CultureInfo.InvariantCulture);
                if (seen == 0) firstAt = at;
                lastAt = at;
                seen++;
            }
            Check("audit entries are in chronological order", seen > 0 && lastAt >= firstAt, audit);

            var hasLogTailEntry = false;
            foreach (var e in auditJson["entries"].Items)
                if (e["op"].AsString() == "get_log_tail") hasLogTailEntry = true;
            Check("audit trail recorded get_log_tail", hasLogTailEntry, audit);

            BridgePlugin.GameRoot = previousRoot;
        }
        finally
        {
            CommandRouter.SecretToRedact = "";
            try { Directory.Delete(root, true); } catch { /* best effort */ }
        }
    }

    private static void LogTailHandlesMissingLog()
    {
        var previousRoot = BridgePlugin.GameRoot;
        BridgePlugin.GameRoot = Path.Combine(Path.GetTempPath(), "bridge-core-test-missing-" + Guid.NewGuid().ToString("N"));
        try
        {
            var json = CommandRouter.Execute("{\"op\":\"get_log_tail\"}");
            Check("missing log yields a readable error, not an exception",
                json.Contains("log_not_found"), json);
        }
        finally
        {
            BridgePlugin.GameRoot = previousRoot;
        }
    }

    private static void ReflectDegradesOnRenamedMembers()
    {
        var probe = new Probe { Known = 42, Name = "hello" };

        Check("known int read", Reflect.GetInt(probe, "Known") == 42);
        Check("known string read", Reflect.GetString(probe, "Name") == "hello");
        Check("renamed member yields fallback", Reflect.GetInt(probe, "Renamed", -7) == -7);
        Check("renamed member yields null", Reflect.Get(probe, "Renamed") == null);
        Check("read on null target is safe", Reflect.Get(null, "Anything") == null);
        Check("static read on missing type is safe", Reflect.GetStatic(null, "X") == null);
        Check("call on missing type is safe", !Reflect.CallStatic(null, "Pause"));
        Check("missing member is recorded for diagnostics", ContainsMissing("Renamed"));
    }

    private static void JsonObjectEmitsValidJson()
    {
        var o = new JsonObject()
            .Add("s", "a\"b")
            .Add("n", 123L)
            .Add("d", 1.5)
            .Add("b", true)
            .Raw("obj", "{\"k\":1}")
            .Raw("arr", "[1,2]")
            .ToString();

        var parsed = Json.Parse(o);
        Check("JsonObject output parses", parsed != null, o);
        Check("JsonObject string member", parsed?["s"].AsString() == "a\"b", o);
        Check("JsonObject long member", parsed?["n"].AsLong() == 123, o);
        Check("JsonObject bool member", parsed?["b"].AsBool() == true, o);
        Check("JsonObject raw object member", parsed?["obj"]["k"].AsInt() == 1, o);
        Check("JsonObject raw array member", parsed?["arr"].Count == 2, o);

        // A null value must be emitted as JSON null, not as the string "null".
        var withNull = new JsonObject().Add("v", (string)null).ToString();
        Check("null string member is JSON null", withNull == "{\"v\":null}", withNull);
    }

    // ------------------------------------------------------------------ helpers

    private sealed class Probe
    {
        public int Known;
        public string Name;
    }

    private static bool ContainsMissing(string member)
    {
        foreach (var m in Reflect.MissingMembers)
            if (m.EndsWith("|" + member, StringComparison.Ordinal)) return true;
        return false;
    }

    private static string Describe(string s)
        => s == null ? "<null>" : (s.Length > 24 ? s.Substring(0, 24) + "..." : s);

    private static void Check(string what, bool ok, string detail = null)
    {
        if (ok)
        {
            _passed++;
            Console.WriteLine("  PASS  " + what);
            return;
        }

        var suffix = string.IsNullOrEmpty(detail) ? "" : " -- " + detail;
        Console.WriteLine("  FAIL  " + what + suffix);
        Failures.Add(what);
    }
}
