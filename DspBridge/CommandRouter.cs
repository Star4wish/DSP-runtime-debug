using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace DspBridge
{
    /// <summary>
    /// Maps an op name to an implementation.
    ///
    /// SECURITY MODEL (doc 5.9): the router is CLOSED BY DEFAULT -- an op that is not
    /// explicitly listed here returns <c>unknown_or_disabled_op</c>. Forgetting to
    /// register something can never turn into an exposed capability.
    ///
    /// There is deliberately NO eval / reflection-invoke / Process.Start op anywhere in
    /// this class: L4 ("arbitrary code execution") is a hard red line, because exposing it
    /// would make every level above it meaningless.
    ///
    /// Every call is appended to an in-memory audit trail (<see cref="AuditJson"/>).
    /// </summary>
    internal static class CommandRouter
    {
        private const int AuditCapacity = 200;
        private static readonly Queue<AuditEntry> Audit = new Queue<AuditEntry>();
        private static readonly object AuditGate = new object();

        private sealed class AuditEntry
        {
            public DateTime AtUtc;
            public string Op;
            public string Args;
            public string Result;
            public int ElapsedMs;
        }

        /// <summary>Set from the "Allow writes" config entry. L1 ops are refused while false.</summary>
        public static bool AllowWrites;

        /// <summary>Token, scrubbed from log output that is handed back to a caller.</summary>
        public static string SecretToRedact = "";

        public static string Execute(string payload)
        {
            var req = Json.Parse(payload);
            var op = req?["op"].AsString();

            var sw = System.Diagnostics.Stopwatch.StartNew();
            string json;
            string verdict;

            try
            {
                json = Dispatch(op, req);
                verdict = json.IndexOf("\"error\"", StringComparison.Ordinal) >= 0 ? "error" : "ok";
            }
            catch (Exception ex)
            {
                json = new JsonObject()
                    .Add("error", "handler_exception")
                    .Add("detail", ex.GetType().Name + ": " + ex.Message)
                    .ToString();
                verdict = "exception";
            }

            sw.Stop();
            Record(op, payload, verdict, (int)sw.ElapsedMilliseconds);
            return json;
        }

        private static string Dispatch(string op, JsonValue req)
        {
            var args = req?["args"] ?? req;

            switch (op)
            {
                // ---------------------------------------------------------- L0 read-only
                case "get_health":
                    return GameSnapshot.HealthJson();

                case "get_state":
                    // Served from the main-thread snapshot: zero main-thread hops, so it
                    // cannot time out even while the game hitches.
                    return Stamp(GameSnapshot.SnapshotJson);

                case "get_catalog":
                    return BridgePlugin.InvokeOnMain(() => Stamp(GameSnapshot.CatalogSummary()));

                case "get_power":
                {
                    // Fresh, precise read -- costs one main-thread round trip.
                    var factoryIndex = args["factoryIndex"].AsInt(-1);
                    return BridgePlugin.InvokeOnMain(() => Stamp(LocalPowerJson(factoryIndex)));
                }

                case "get_planet_power":
                    return BridgePlugin.InvokeOnMain(() => Stamp(PlanetPowerJson(args)), 30000);

                case "list_planets":
                    return BridgePlugin.InvokeOnMain(() => Stamp(ListPlanetsJson(args)), 30000);

                case "find_items":
                    return BridgePlugin.InvokeOnMain(() => Stamp(GameSnapshot.QueryItems(
                        args["fromId"].AsInt(0),
                        args["limit"].AsInt(25),
                        args["nameContains"].AsString())), 30000);

                case "get_log_tail":
                    return LogTailJson(args);

                case "get_audit":
                    return AuditJson(args);

                // ---------------------------------------------------------- L1 reversible
                case "set_pause":
                {
                    if (!AllowWrites)
                        return Locked(op);

                    var paused = args["paused"].AsBool(!args.Has("paused"));
                    return BridgePlugin.InvokeOnMain(() => Stamp(SetPauseJson(paused)));
                }

                default:
                    return new JsonObject()
                        .Add("error", "unknown_or_disabled_op")
                        .Add("op", op)
                        .Add("hint", "see the op table in DspBridge\\README.md; the router is closed by default")
                        .ToString();
            }
        }

        private static string Locked(string op) => new JsonObject()
            .Add("error", "writes_disabled")
            .Add("op", op)
            .Add("hint", "L1 write ops are off by default; set [Bridge] AllowWrites = true in "
                       + "BepInEx\\config\\org.yourname.dspbridge.cfg and restart the game")
            .ToString();

        /// <summary>Every payload carries schemaVersion so the MCP layer can detect drift.</summary>
        private static string Stamp(string json)
        {
            if (string.IsNullOrEmpty(json)) return "{\"error\":\"empty_payload\"}";
            if (json.IndexOf("\"schemaVersion\"", StringComparison.Ordinal) >= 0) return json;
            return "{\"schemaVersion\":" + GameSnapshot.SchemaVersion + ",\"data\":" + json + "}";
        }

        // ------------------------------------------------------------------ ops

        private static string LocalPowerJson(int factoryIndex)
        {
            try
            {
                var gm = FindType("GameMain");
                var data = Reflect.GetStatic(gm, "data");
                if (data == null)
                    return new JsonObject().Add("error", "game_not_loaded").Add("hint", "no save is open yet").ToString();

                var factories = Reflect.Get(data, "factories") as Array;
                if (factories == null)
                    return new JsonObject().Add("error", "factories_unavailable").ToString();

                if (factoryIndex < 0)
                {
                    var localPlanet = Reflect.GetStatic(gm, "localPlanet") ?? Reflect.Get(data, "localPlanet");
                    if (localPlanet == null)
                        return new JsonObject().Add("error", "no_local_planet")
                            .Add("hint", "pass factoryIndex explicitly (see list_planets)").ToString();
                    factoryIndex = Reflect.GetInt(localPlanet, "factoryIndex", -1);
                }

                if (factoryIndex < 0 || factoryIndex >= factories.Length)
                    return new JsonObject().Add("error", "bad_factory_index")
                        .Add("factoryIndex", factoryIndex)
                        .Add("factoryCount", factories.Length).ToString();

                var factory = factories.GetValue(factoryIndex);
                if (factory == null)
                    return new JsonObject().Add("error", "factory_not_loaded")
                        .Add("factoryIndex", factoryIndex)
                        .Add("hint", "that planet is not currently instantiated").ToString();

                var planet = Reflect.Get(factory, "planet");
                var o = new JsonObject()
                    .Add("schemaVersion", GameSnapshot.SchemaVersion)
                    .Add("factoryIndex", factoryIndex)
                    .Add("planetId", Reflect.GetInt(factory, "planetId", -1))
                    .Add("planetName", GameSnapshot.Sanitize(planet == null ? null : Reflect.GetString(planet, "name")))
                    .Add("gameTick", Reflect.GetStaticLong(gm, "gameTick"))
                    .Raw("power", GameSnapshot.PowerOfFactory(factory));
                return o.ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).Add("detail", ex.Message).ToString();
            }
        }

        private static string PlanetPowerJson(JsonValue args)
        {
            var index = FindFactoryIndex(args["planetId"].AsString(), args["planetIndex"].AsInt(-1));
            if (index < 0)
                return new JsonObject()
                    .Add("error", "planet_not_found")
                    .Add("hint", "use list_planets to see the loaded planetIds, or omit planetId for the local planet")
                    .ToString();
            return LocalPowerJson(index);
        }

        private static string ListPlanetsJson(JsonValue args)
        {
            try
            {
                var gm = FindType("GameMain");
                var data = Reflect.GetStatic(gm, "data");
                if (data == null) return new JsonObject().Add("error", "game_not_loaded").ToString();

                var factories = Reflect.Get(data, "factories") as Array;
                var factoryCount = (int)Reflect.GetLong(data, "factoryCount", factories?.Length ?? 0);
                if (factories == null) return new JsonObject().Add("error", "factories_unavailable").ToString();

                var filter = args["nameContains"].AsString();
                var limit = args["limit"].AsInt(50);
                if (limit <= 0) limit = 50;
                if (limit > 200) limit = 200;

                var localPlanet = Reflect.GetStatic(gm, "localPlanet");
                var localFactoryIndex = localPlanet == null ? -1 : Reflect.GetInt(localPlanet, "factoryIndex", -1);

                var entries = new StringBuilder();
                var returned = 0;
                var matched = 0;

                for (var i = 0; i < Math.Min(factoryCount, factories.Length); i++)
                {
                    var f = factories.GetValue(i);
                    if (f == null) continue;

                    var planet = Reflect.Get(f, "planet");
                    var name = planet == null ? null : Reflect.GetString(planet, "name");
                    if (!string.IsNullOrEmpty(filter)
                        && (name == null || name.IndexOf(filter, StringComparison.OrdinalIgnoreCase) < 0))
                        continue;

                    matched++;
                    if (returned >= limit) continue;

                    var ps = Reflect.Get(f, "powerSystem");
                    var entry = new JsonObject()
                        .Add("factoryIndex", i)
                        .Add("planetId", Reflect.GetInt(f, "planetId", -1))
                        .Add("planetName", GameSnapshot.Sanitize(name))
                        .Add("isLocal", i == localFactoryIndex)
                        .Add("loaded", ps != null)
                        .Add("entityCount", Reflect.GetInt(f, "entityCount"))
                        .Add("veinCount", Reflect.GetInt(f, "veinCount"));
                    if (ps != null) entry.Raw("power", GameSnapshot.PowerOfFactory(f));

                    if (returned > 0) entries.Append(',');
                    entries.Append(entry);
                    returned++;
                }

                return new JsonObject()
                    .Add("schemaVersion", GameSnapshot.SchemaVersion)
                    .Add("factoryCount", factoryCount)
                    .Add("matched", matched)
                    .Add("returned", returned)
                    .Add("truncated", matched > returned)
                    .Raw("planets", "[" + entries + "]")
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).Add("detail", ex.Message).ToString();
            }
        }

        private static string SetPauseJson(bool paused)
        {
            try
            {
                var gm = FindType("GameMain");
                if (gm == null) return new JsonObject().Add("error", "GameMain type not found").ToString();

                // Only these two whitelisted, verified methods are ever invoked.
                var ok = paused ? Reflect.CallStatic(gm, "Pause") : Reflect.CallStatic(gm, "Resume");
                if (!ok)
                    return new JsonObject().Add("error", "call_failed")
                        .Add("hint", "GameMain.Pause/Resume signature changed in this game build").ToString();

                return new JsonObject()
                    .Add("schemaVersion", GameSnapshot.SchemaVersion)
                    .Add("requested", paused)
                    .Add("isPaused", Reflect.GetStaticLong(gm, "isPaused") != 0)
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).Add("detail", ex.Message).ToString();
            }
        }

        // ------------------------------------------------------------------ log tail

        private static string LogTailJson(JsonValue args)
        {
            try
            {
                var lines = args["lines"].AsInt(120);
                if (lines <= 0) lines = 120;
                if (lines > 1000) lines = 1000;

                var path = Path.Combine(BridgePlugin.GameRoot, "BepInEx", "LogOutput.log");
                if (!File.Exists(path))
                    return new JsonObject().Add("error", "log_not_found").Add("path", path).ToString();

                // The log is open for writing by BepInEx; FileShare.ReadWrite avoids a sharing violation.
                var tail = new Queue<string>(lines);
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var sr = new StreamReader(fs, Encoding.UTF8))
                {
                    string line;
                    while ((line = sr.ReadLine()) != null)
                    {
                        if (tail.Count == lines) tail.Dequeue();
                        tail.Enqueue(line);
                    }
                }

                var sb = new StringBuilder();
                var first = true;
                foreach (var line in tail)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    sb.Append(Json.Str(Redact(line)));
                }

                return new JsonObject()
                    .Add("schemaVersion", GameSnapshot.SchemaVersion)
                    .Add("path", path)
                    .Add("returned", tail.Count)
                    .Raw("lines", "[" + sb + "]")
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).Add("detail", ex.Message).ToString();
            }
        }

        private static string AuditJson(JsonValue args)
        {
            var limit = args["limit"].AsInt(50);
            if (limit <= 0) limit = 50;
            if (limit > AuditCapacity) limit = AuditCapacity;

            lock (AuditGate)
            {
                var entries = new List<AuditEntry>(Audit);
                var take = Math.Min(limit, entries.Count);
                var sb = new StringBuilder();

                for (var i = entries.Count - take; i < entries.Count; i++)
                {
                    var e = entries[i];
                    if (sb.Length > 0) sb.Append(',');
                    sb.Append(new JsonObject()
                        .Add("atUtc", e.AtUtc.ToString("o"))
                        .Add("op", e.Op)
                        .Add("verdict", e.Result)
                        .Add("ms", e.ElapsedMs)
                        .Raw("args", Truncate(e.Args, 400)));
                }

                return new JsonObject()
                    .Add("schemaVersion", GameSnapshot.SchemaVersion)
                    .Add("buffered", entries.Count)
                    .Add("returned", take)
                    .Raw("entries", "[" + sb + "]")
                    .ToString();
            }
        }

        private static string Truncate(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return "null";
            var clipped = s.Length <= max ? s : s.Substring(0, max) + "...";
            return Json.Str(Redact(clipped));
        }

        /// <summary>Never let the shared token reach a log file or an LLM context.</summary>
        public static string Redact(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            var secret = SecretToRedact;
            if (string.IsNullOrEmpty(secret) || secret.Length < 8) return s;
            return s.Replace(secret, "<redacted>");
        }

        // ------------------------------------------------------------------ audit

        private static void Record(string op, string args, string result, int ms)
        {
            var at = DateTime.UtcNow;
            lock (AuditGate)
            {
                if (Audit.Count >= AuditCapacity) Audit.Dequeue();
                Audit.Enqueue(new AuditEntry
                {
                    AtUtc = at,
                    Op = op ?? "(missing)",
                    Args = args,
                    Result = result,
                    ElapsedMs = ms
                });
            }

            // Full audit trail on disk too (doc 5.9: "who, when, what args, what result").
            BridgePlugin.AppendAuditFile($"{at:o} op={op ?? "(missing)"} verdict={result} ms={ms} args={TruncateRaw(args)}");
        }

        private static string TruncateRaw(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            var oneLine = s.Replace("\r", " ").Replace("\n", " ");
            return oneLine.Length <= 400 ? oneLine : oneLine.Substring(0, 400) + "...";
        }

        // ------------------------------------------------------------------ helpers

        private static Type FindType(string name)
        {
            foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
            {
                var t = asm.GetType(name, false);
                if (t != null) return t;
            }
            return null;
        }

        /// <summary>
        /// Resolve a planet selector to a factory index. Accepts the game's planet id
        /// ("1-3-2" / "132"), an explicit planetIndex, or an empty selector (local planet).
        /// Returns -1 when nothing matches; the caller turns that into a readable error.
        /// </summary>
        private static int FindFactoryIndex(string planetId, int planetIndex)
        {
            var gm = FindType("GameMain");
            var data = Reflect.GetStatic(gm, "data");
            if (data == null) return -1;

            var factories = Reflect.Get(data, "factories") as Array;
            if (factories == null) return -1;

            if (!string.IsNullOrEmpty(planetId))
            {
                int targetId;
                var digits = planetId.Replace("-", "").Replace("_", "").Trim();
                if (int.TryParse(digits, out targetId))
                {
                    for (var i = 0; i < factories.Length; i++)
                    {
                        var f = factories.GetValue(i);
                        if (f == null) continue;
                        if (Reflect.GetInt(f, "planetId", -1) == targetId) return i;
                    }
                }
                else
                {
                    for (var i = 0; i < factories.Length; i++)
                    {
                        var f = factories.GetValue(i);
                        if (f == null) continue;
                        var planet = Reflect.Get(f, "planet");
                        var name = planet == null ? null : Reflect.GetString(planet, "name");
                        if (name != null && name.Equals(planetId, StringComparison.OrdinalIgnoreCase)) return i;
                    }
                }
                return -1;
            }

            if (planetIndex >= 0) return planetIndex;

            var localPlanet = Reflect.GetStatic(gm, "localPlanet");
            if (localPlanet != null) return Reflect.GetInt(localPlanet, "factoryIndex", -1);

            return -1;
        }
    }
}
