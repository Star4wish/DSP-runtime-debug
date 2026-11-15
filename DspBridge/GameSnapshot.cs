using System;
using System.Collections;
using System.Collections.Generic;
using System.Text;
using UnityEngine;

namespace DspBridge
{
    /// <summary>
    /// Builds the read-only game snapshots.
    ///
    /// THREADING: everything in this class touches the Unity API and therefore may only
    /// be called from the Unity main thread (BepInEx source: "Most of Unity API can not
    /// be accessed while running on another thread!"). The HTTP thread only ever reads
    /// the already-built <see cref="SnapshotJson"/> string.
    ///
    /// Field names are the ones verified present in the local Assembly-CSharp.dll
    /// (0.10.35.29104, tools\metaprobe). Reads are reflective so a future game patch
    /// degrades to null instead of throwing MissingFieldException.
    /// </summary>
    internal static class GameSnapshot
    {
        public const int SchemaVersion = 1;

        /// <summary>Refresh cadence in frames (~0.5 s at 60 fps). Cheap: a few hundred field reads.</summary>
        public const int RefreshEveryFrames = 30;

        // Cached type handles. Resolved once; null when the game build does not have them.
        private static readonly Type TGameMain = FindType("GameMain");
        private static readonly Type TGameData = FindType("GameData");
        private static readonly Type TGameHistoryData = FindType("GameHistoryData");
        private static readonly Type TPlanetFactory = FindType("PlanetFactory");
        private static readonly Type TPowerSystem = FindType("PowerSystem");
        private static readonly Type TPowerNetwork = FindType("PowerNetwork");
        private static readonly Type TPlanetData = FindType("PlanetData");
        private static readonly Type TLDB = FindType("LDB");

        /// <summary>Fully built snapshot, replaced as a whole (never mutated in place) so readers cannot tear.</summary>
        private static volatile string _snapshot = "{}";
        private static long _snapshotTick = -1;

        public static string SnapshotJson => _snapshot;
        public static long SnapshotTick => _snapshotTick;

        private static Type FindType(string name)
        {
            try
            {
                // Global namespace (Assembly-CSharp); do NOT prefix with a namespace -- see doc 5.1.1.
                foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
                {
                    var t = asm.GetType(name, false);
                    if (t != null) return t;
                }
            }
            catch (Exception) { }
            return null;
        }

        // ------------------------------------------------------------------ health

        /// <summary>Liveness probe. Deliberately independent of game state so it works in the main menu.</summary>
        public static string HealthJson()
        {
            var loaded = IsGameLoaded();
            return new JsonObject()
                .Add("status", "ok")
                .Add("pid", System.Diagnostics.Process.GetCurrentProcess().Id)
                .Add("schemaVersion", SchemaVersion)
                .Add("gameLoaded", loaded)
                .Add("snapshotTick", _snapshotTick)
                .Add("unityVersion", Application.unityVersion)
                .Add("timeUtc", DateTime.UtcNow.ToString("o"))
                .ToString();
        }

        public static bool IsGameLoaded()
        {
            try
            {
                if (TGameMain == null) return false;
                var data = Reflect.GetStatic(TGameMain, "data");
                if (data == null) return false;

                // isMenuDemo is an INSTANCE field (GameMain.instance.isMenuDemo), not a static
                // one. Reading it as a static member always returned null, the cast threw, and
                // the catch below turned that into a permanent "gameLoaded: false" -- even with
                // a save fully loaded. Verified against Assembly-CSharp 0.10.35: the main-menu
                // check in the game itself is `GameMain.instance.isMenuDemo`.
                var instance = Reflect.GetStatic(TGameMain, "instance");
                if (instance != null)
                {
                    var flag = Reflect.Get(instance, "isMenuDemo");
                    if (flag is bool menu) return !menu;
                }

                // No menu flag available: data != null already means a game is instanced.
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }

        // ------------------------------------------------------------------- state

        /// <summary>
        /// The composite read-only snapshot behind <c>GET /state</c>. Called ~2x/second on the
        /// main thread; the HTTP thread only reads the resulting string.
        /// </summary>
        public static string BuildStateJson()
        {
            var root = new JsonObject()
                .Add("schemaVersion", SchemaVersion)
                .Add("pid", System.Diagnostics.Process.GetCurrentProcess().Id)
                .Add("generatedAt", DateTime.UtcNow.ToString("o"));

            try
            {
                if (TGameMain == null)
                {
                    _snapshotTick = -1;
                    return root.Add("gameLoaded", false)
                               .Add("reason", "GameMain type not found; Assembly-CSharp layout changed")
                               .ToString();
                }

                root.Add("gameLoaded", IsGameLoaded());
                root.Add("gameTick", Reflect.GetStaticLong(TGameMain, "gameTick"));
                // isPaused is a bool; Reflect.ToLong normalises bool/int/long alike.
                root.Add("paused", Reflect.GetStaticLong(TGameMain, "isPaused") != 0);
                root.Add("tickPerSec", (long)Reflect.ToLong(Reflect.GetStatic(TGameMain, "tickPerSecI"), 60));
                root.Add("unityVersion", Application.unityVersion);

                var data = Reflect.GetStatic(TGameMain, "data");
                if (data == null)
                {
                    _snapshotTick = -1;
                    return root.Add("gameLoaded", false)
                               .Add("reason", "GameMain.data is null (main menu / still loading)")
                               .ToString();
                }

                // ---- local planet / factory ----
                var localPlanet = Reflect.GetStatic(TGameMain, "localPlanet") ?? Reflect.Get(data, "localPlanet");
                var factories = Reflect.Get(data, "factories") as Array;
                var factoryCount = (int)Reflect.GetLong(data, "factoryCount", factories?.Length ?? 0);

                root.Add("factoryCount", factoryCount);

                if (localPlanet != null)
                {
                    root.Raw("localPlanet", PlanetSummary(localPlanet, factories));
                }
                else
                {
                    root.Raw("localPlanet", "null");
                }

                // ---- galaxy-wide power roll-up ----
                root.Raw("power", PowerRollup(factories, factoryCount));

                // ---- research ----
                root.Raw("research", ResearchSummary(data));

                // ---- proto catalogue sizes (static, no game state needed) ----
                root.Raw("catalog", CatalogSummary());

                // ---- snapshot bookkeeping ----
                _snapshotTick = Reflect.GetStaticLong(TGameMain, "gameTick");
                root.Add("snapshotTick", _snapshotTick);

                var missing = Reflect.MissingMembers;
                if (missing != null)
                {
                    // Surface layout drift instead of silently returning nulls.
                    var sb = new StringBuilder();
                    var n = 0;
                    foreach (var m in missing)
                    {
                        // Json.Str, not naive concatenation: a member key can contain a
                        // backslash or quote, which would emit invalid JSON.
                        if (n > 0) sb.Append(',');
                        sb.Append(Json.Str(m));
                        if (++n >= 20) break;
                    }
                    if (n > 0) root.Raw("unresolvedMembers", "[" + sb + "]");
                }

                return root.ToString();
            }
            catch (Exception ex)
            {
                // Never let a snapshot failure escape into the game's Update loop.
                return new JsonObject()
                    .Add("schemaVersion", SchemaVersion)
                    .Add("gameLoaded", false)
                    .Add("error", "snapshot_failed")
                    .Add("detail", ex.GetType().Name + ": " + ex.Message)
                    .ToString();
            }
        }

        private static string PlanetSummary(object planet, Array factories)
        {
            var o = new JsonObject()
                .Add("id", Reflect.GetInt(planet, "id"))
                .Add("index", Reflect.GetInt(planet, "index"))
                .Add("name", Reflect.GetString(planet, "name"))
                .Add("radius", Math.Round(Reflect.GetDouble(planet, "radius"), 3))
                .Add("factoryIndex", Reflect.GetInt(planet, "factoryIndex", -1));

            var star = Reflect.Get(planet, "star");
            if (star != null)
            {
                o.Raw("star", new JsonObject()
                    .Add("index", Reflect.GetInt(star, "index", -1))
                    .Add("name", Reflect.GetString(star, "name"))
                    .Add("type", Stringify(Reflect.Get(star, "type")))
                    .ToString());
            }

            var factoryIndex = Reflect.GetInt(planet, "factoryIndex", -1);
            if (factoryIndex >= 0 && factories != null && factoryIndex < factories.Length)
            {
                var f = factories.GetValue(factoryIndex);
                if (f != null)
                {
                    o.Raw("factory", new JsonObject()
                        .Add("index", factoryIndex)
                        .Add("entityCount", Reflect.GetInt(f, "entityCount"))
                        .Add("prebuildCount", Reflect.GetInt(f, "prebuildCount"))
                        .Add("craftCount", Reflect.GetInt(f, "craftCount"))
                        .Add("veinCount", Reflect.GetInt(f, "veinCount"))
                        .Add("enemyCount", Reflect.GetInt(f, "enemyCount"))
                        .ToString());

                    o.Raw("power", PowerOfFactory(f));
                }
            }

            return o.ToString();
        }

        /// <summary>
        /// Sum the per-network numbers of one planet's PowerSystem.
        /// PowerNetwork.energyCapacity is the supplied energy, energyServed the satisfied
        /// demand and energyRequired the total demand for the current tick.
        /// </summary>
        public static string PowerOfFactory(object factory)
        {
            try
            {
                var ps = Reflect.Get(factory, "powerSystem");
                if (ps == null)
                    return new JsonObject().Add("available", false).Add("reason", "powerSystem null (planet not loaded)").ToString();

                long capacity = 0, served = 0, required = 0, stored = 0, charge = 0, discharge = 0;
                var nets = 0;

                var netPool = Reflect.Get(ps, "netPool") as Array;
                var netCursor = Reflect.GetInt(ps, "netCursor", netPool?.Length ?? 0);

                if (netPool != null)
                {
                    for (var i = 1; i < netCursor && i < netPool.Length; i++)
                    {
                        var net = netPool.GetValue(i);
                        if (net == null) continue;
                        nets++;
                        capacity += Reflect.GetLong(net, "energyCapacity");
                        served += Reflect.GetLong(net, "energyServed");
                        required += Reflect.GetLong(net, "energyRequired");
                        stored += Reflect.GetLong(net, "energyAccumulated");
                        charge += Reflect.GetLong(net, "energyCharge");
                        discharge += Reflect.GetLong(net, "energyDischarge");
                    }
                }

                var ratio = capacity > 0 ? Math.Round((double)served / capacity, 4) : 1.0;

                return new JsonObject()
                    .Add("available", true)
                    .Add("networks", nets)
                    .Add("supply", capacity)
                    .Add("demand", required)
                    .Add("served", served)
                    .Add("satisfactionRatio", ratio)
                    .Add("deficit", Math.Max(0, required - served))
                    .Add("accumulated", stored)
                    .Add("charging", charge)
                    .Add("discharging", discharge)
                    .Add("generatorCount", Reflect.GetInt(ps, "genCursor") - 1)
                    .Add("consumerCount", Reflect.GetInt(ps, "consumerCursor") - 1)
                    .Add("nodeCount", Reflect.GetInt(ps, "nodeCursor") - 1)
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("available", false).Add("error", ex.GetType().Name).ToString();
            }
        }

        private static string PowerRollup(Array factories, int factoryCount)
        {
            long supply = 0, served = 0, required = 0;
            var loaded = 0;

            try
            {
                if (factories == null)
                    return new JsonObject().Add("available", false).ToString();

                var limit = Math.Min(factoryCount, factories.Length);
                for (var i = 0; i < limit; i++)
                {
                    var f = factories.GetValue(i);
                    if (f == null) continue;
                    var ps = Reflect.Get(f, "powerSystem");
                    if (ps == null) continue;
                    loaded++;

                    var netPool = Reflect.Get(ps, "netPool") as Array;
                    var netCursor = Reflect.GetInt(ps, "netCursor", netPool?.Length ?? 0);
                    if (netPool == null) continue;

                    for (var j = 1; j < netCursor && j < netPool.Length; j++)
                    {
                        var net = netPool.GetValue(j);
                        if (net == null) continue;
                        supply += Reflect.GetLong(net, "energyCapacity");
                        served += Reflect.GetLong(net, "energyServed");
                        required += Reflect.GetLong(net, "energyRequired");
                    }
                }

                return new JsonObject()
                    .Add("available", true)
                    .Add("loadedFactories", loaded)
                    .Add("supply", supply)
                    .Add("demand", required)
                    .Add("served", served)
                    .Add("deficit", Math.Max(0, required - served))
                    .Add("satisfactionRatio", supply > 0 ? Math.Round((double)served / supply, 4) : 1.0)
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("available", false).Add("error", ex.GetType().Name).ToString();
            }
        }

        private static string ResearchSummary(object data)
        {
            try
            {
                var history = Reflect.Get(data, "history");
                if (history == null) return "null";

                long unlocked = 0, total = 0, hashUploaded = 0, hashNeeded = 0;

                var techStates = Reflect.Get(history, "techStates") as IDictionary;
                if (techStates != null)
                {
                    foreach (DictionaryEntry e in techStates)
                    {
                        total++;
                        var st = e.Value;
                        if (st == null) continue;
                        if (Reflect.ToLong(Reflect.Get(st, "unlocked")) != 0) unlocked++;
                        hashUploaded += Reflect.GetLong(st, "hashUploaded");
                        hashNeeded += Reflect.GetLong(st, "hashNeeded");
                    }
                }

                var recipeUnlocked = Reflect.Get(history, "recipeUnlocked") as ICollection;

                return new JsonObject()
                    .Add("techTotal", total)
                    .Add("techUnlocked", unlocked)
                    .Add("hashUploaded", hashUploaded)
                    .Add("hashNeeded", hashNeeded)
                    .Add("recipesUnlocked", recipeUnlocked?.Count ?? 0)
                    .Add("universeMatrixPointUploaded", Reflect.GetLong(history, "universeMatrixPointUploaded"))
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).ToString();
            }
        }

        /// <summary>Sizes of the global proto tables. Useful as a cheap "is the LDB sane" check.</summary>
        public static string CatalogSummary()
        {
            try
            {
                if (TLDB == null) return "null";
                return new JsonObject()
                    .Add("items", ProtoCount("items"))
                    .Add("recipes", ProtoCount("recipes"))
                    .Add("techs", ProtoCount("techs"))
                    .Add("models", ProtoCount("models"))
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).ToString();
            }
        }

        private static int ProtoCount(string protoSetName)
        {
            var set = Reflect.GetStatic(TLDB, protoSetName);
            if (set == null) return -1;
            var len = Reflect.Length(Reflect.Get(set, "dataArray"));
            if (len >= 0) return len;
            return (int)Reflect.GetLong(set, "Length", -1);
        }

        /// <summary>
        /// Item catalogue query (L0). Backed by LDB.items, which is a ProtoSet&lt;ItemProto&gt;
        /// with a sparse dataArray -- entries at index 0 and gaps are null.
        /// </summary>
        public static string QueryItems(int fromId, int limit, string nameContains)
        {
            try
            {
                if (TLDB == null)
                    return new JsonObject().Add("error", "LDB type not found").ToString();

                var set = Reflect.GetStatic(TLDB, "items");
                if (set == null)
                    return new JsonObject().Add("error", "LDB.items is null (game not loaded yet)").ToString();

                var dataArray = Reflect.Get(set, "dataArray") as Array;
                if (dataArray == null)
                    return new JsonObject().Add("error", "items.dataArray not an array").ToString();

                if (limit <= 0) limit = 25;
                if (limit > 500) limit = 500;

                var results = new List<string>();
                var scanned = 0;
                var totalMatched = 0;

                for (var i = Math.Max(0, fromId); i < dataArray.Length; i++)
                {
                    var proto = dataArray.GetValue(i);
                    if (proto == null) continue;
                    scanned++;

                    var name = Reflect.GetString(proto, "Name");
                    if (!string.IsNullOrEmpty(nameContains)
                        && (name == null || name.IndexOf(nameContains, StringComparison.OrdinalIgnoreCase) < 0))
                        continue;

                    totalMatched++;
                    if (results.Count >= limit) continue;

                    results.Add(new JsonObject()
                        .Add("id", Reflect.GetInt(proto, "ID", i))
                        .Add("name", Sanitize(name))
                        .Add("sid", Sanitize(Reflect.GetString(proto, "SID")))
                        .Add("stackSize", Reflect.GetInt(proto, "StackSize"))
                        .Add("type", Stringify(Reflect.Get(proto, "Type")))
                        .Add("isFluid", Reflect.GetLong(proto, "IsFluid") != 0)
                        .Add("isEntity", Reflect.GetLong(proto, "IsEntity") != 0)
                        .Add("canBuild", Reflect.GetLong(proto, "CanBuild") != 0)
                        .Add("gridIndex", Reflect.GetInt(proto, "GridIndex"))
                        .ToString());
                }

                var body = new StringBuilder();
                for (var i = 0; i < results.Count; i++)
                {
                    if (i > 0) body.Append(',');
                    body.Append(results[i]);
                }

                return new JsonObject()
                    .Add("schemaVersion", SchemaVersion)
                    .Add("scannedFrom", fromId)
                    .Add("scanned", scanned)
                    .Add("totalMatched", totalMatched)
                    .Add("returned", results.Count)
                    .Add("truncated", totalMatched > results.Count)
                    .Raw("items", "[" + body + "]")
                    .ToString();
            }
            catch (Exception ex)
            {
                return new JsonObject().Add("error", ex.GetType().Name).Add("detail", ex.Message).ToString();
            }
        }

        // ------------------------------------------------------------------ utils

        /// <summary>Enums (EItemType, EPlanetType...) need ToString; anything else stringifies.</summary>
        public static string Stringify(object v)
        {
            if (v == null) return "?";
            try { return v.ToString(); }
            catch (Exception) { return "?"; }
        }

        /// <summary>
        /// Game text (planet names, blueprint names, chat) can contain arbitrary characters and
        /// is fed back into an LLM context. Strip control characters and cap the length so a
        /// crafted name cannot smuggle format/escape sequences into the model's prompt.
        /// </summary>
        public static string Sanitize(string s)
        {
            if (string.IsNullOrEmpty(s)) return s;
            var sb = new StringBuilder(s.Length);
            foreach (var c in s)
            {
                if (c < 0x20 || c == 0x7F) continue;   // control chars
                sb.Append(c);
                if (sb.Length >= 200) break;
            }
            return sb.ToString();
        }
    }

    /// <summary>Waits for the main-thread dispatcher to hand back a result.</summary>
    internal sealed class ResultBox
    {
        public string Value;
        public string Error;
        public readonly System.Threading.ManualResetEventSlim Done = new System.Threading.ManualResetEventSlim(false);
    }
}
