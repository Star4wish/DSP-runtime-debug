using System;
using System.Collections.Generic;
using System.Reflection;
using System.Text;

namespace DspBridge
{
    /// <summary>
    /// Version-tolerant reflective field access to the game's <c>Assembly-CSharp</c>.
    ///
    /// DSP patches often change field names/signatures (see DSP-MOD-开发环境说明.md 5.7 #9).
    /// Every single access in this plugin goes through <see cref="Get"/>/<see cref="GetStatic"/>:
    /// a renamed field yields JSON <c>null</c> plus a note, instead of a
    /// MissingFieldException that would take the whole command down and leave the LLM
    /// guessing. Member names were verified against the local Assembly-CSharp.dll
    /// (0.10.35.29104) with tools\metaprobe. No method bodies are reproduced anywhere.
    /// </summary>
    internal static class Reflect
    {
        private static readonly object Gate = new object();
        private static readonly Dictionary<string, MemberInfo> Cache = new Dictionary<string, MemberInfo>(StringComparer.Ordinal);

        /// <summary>Names that resolved to "not present in this game build".</summary>
        private static readonly HashSet<string> Missing = new HashSet<string>(StringComparer.Ordinal);

        public static IEnumerable<string> MissingMembers => Missing;

        private static MemberInfo Resolve(Type type, string member)
        {
            if (type == null || string.IsNullOrEmpty(member)) return null;
            var key = type.FullName + "|" + member;

            lock (Gate)
            {
                if (Cache.TryGetValue(key, out var hit)) return hit;
                if (Missing.Contains(key)) return null;

                MemberInfo found = null;
                const BindingFlags flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;

                var f = type.GetField(member, flags);
                if (f != null) found = f;
                else
                {
                    var p = type.GetProperty(member, flags);
                    if (p != null && p.CanRead) found = p;
                }

                if (found == null) Missing.Add(key);
                else Cache[key] = found;
                return found;
            }
        }

        /// <summary>Read an instance field/property. Returns null on any failure (never throws).</summary>
        public static object Get(object target, string member)
        {
            if (target == null) return null;
            try
            {
                var mi = Resolve(target.GetType(), member);
                if (mi is FieldInfo fi) return fi.GetValue(target);
                if (mi is PropertyInfo pi && pi.CanRead && pi.GetIndexParameters().Length == 0) return pi.GetValue(target, null);
            }
            catch (Exception)
            {
                // Swallow: a failed read is reported as null in the payload.
            }
            return null;
        }

        /// <summary>Read a static field/property by type.</summary>
        public static object GetStatic(Type type, string member)
        {
            try
            {
                var mi = Resolve(type, member);
                if (mi is FieldInfo fi) return fi.GetValue(null);
                if (mi is PropertyInfo pi && pi.CanRead && pi.GetIndexParameters().Length == 0) return pi.GetValue(null, null);
            }
            catch (Exception)
            {
                // Swallow.
            }
            return null;
        }

        /// <summary>
        /// Cheap reflective "call this public no-arg method" used for game actions such as
        /// <c>GameMain.Pause()</c>. Only whitelisted names are ever passed in -- there is
        /// deliberately no generic invocation exposed over HTTP (L4 red line, see doc 5.9).
        /// </summary>
        public static bool CallStatic(Type type, string method)
        {
            try
            {
                var m = type?.GetMethod(method, BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null);
                if (m == null) return false;
                m.Invoke(null, null);
                return true;
            }
            catch (Exception)
            {
                return false;
            }
        }

        // ------------------------------------------------------------ typed helpers

        public static long GetLong(object target, string member, long fallback = 0)
            => ToLong(Get(target, member), fallback);

        public static long GetStaticLong(Type type, string member, long fallback = 0)
            => ToLong(GetStatic(type, member), fallback);

        public static int GetInt(object target, string member, int fallback = 0)
            => (int)ToLong(Get(target, member), fallback);

        public static string GetString(object target, string member, string fallback = null)
            => Get(target, member) as string ?? fallback;

        public static double GetDouble(object target, string member, double fallback = 0)
        {
            var v = Get(target, member);
            return v == null ? fallback : Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture);
        }

        public static long ToLong(object v, long fallback = 0)
        {
            if (v == null) return fallback;
            try
            {
                if (v is long l) return l;
                if (v is int i) return i;
                if (v is short sh) return sh;
                if (v is byte by) return by;
                if (v is bool b) return b ? 1 : 0;
                return Convert.ToInt64(v, System.Globalization.CultureInfo.InvariantCulture);
            }
            catch (Exception)
            {
                return fallback;
            }
        }

        /// <summary>Length of an array, or -1 when the value is not an array. Used for "*Count" probes.</summary>
        public static int Length(object array)
        {
            if (array is Array a) return a.Length;
            return -1;
        }
    }

    /// <summary>Tiny fluent JSON object writer so payloads stay readable in C#.</summary>
    internal sealed class JsonObject
    {
        private readonly StringBuilder _sb = new StringBuilder(256);
        private bool _first = true;

        public JsonObject() { _sb.Append('{'); }

        public JsonObject Add(string key, string value) => Raw(key, Json.Str(value));
        public JsonObject Add(string key, long value) => Raw(key, Json.Num(value));
        public JsonObject Add(string key, int value) => Raw(key, Json.Num((long)value));
        public JsonObject Add(string key, double value) => Raw(key, Json.Num(value));
        public JsonObject Add(string key, bool value) => Raw(key, Json.Bool(value));

        /// <summary>Add a member whose value is already-serialized JSON (object/array/raw).</summary>
        public JsonObject Raw(string key, string rawJson)
        {
            if (!_first) _sb.Append(',');
            _first = false;
            _sb.Append(Json.Str(key)).Append(':').Append(rawJson ?? "null");
            return this;
        }

        /// <summary>Add a member only when the value is non-null/non-empty.</summary>
        public JsonObject AddIf(string key, string value)
            => string.IsNullOrEmpty(value) ? this : Add(key, value);

        public override string ToString() => _sb.ToString() + "}";
    }
}
