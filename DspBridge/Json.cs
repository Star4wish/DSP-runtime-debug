using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace DspBridge
{
    /// <summary>
    /// Zero-dependency JSON: a small writer plus a real recursive-descent reader.
    ///
    /// Why hand-written instead of a library (see DSP-MOD-开发环境说明.md 5.3.1):
    ///   * any third-party dll dropped in BepInEx/plugins is loaded at any depth and
    ///     collides with other mods' copies (Newtonsoft.Json is the classic victim);
    ///   * UnityEngine.JsonUtility cannot serialize dictionaries/interfaces and the
    ///     request side needs tolerant parsing anyway;
    ///   * System.Text.Json is broken under Unity Mono (dotnet/runtime#80525).
    /// </summary>
    internal static class Json
    {
        // ---------------------------------------------------------------- writing

        /// <summary>Escape and quote a string (null becomes JSON null).</summary>
        public static string Str(string s)
        {
            if (s == null) return "null";

            var sb = new StringBuilder(s.Length + 2).Append('"');
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    default:
                        // Control characters must be escaped or the document is invalid.
                        // U+2028/U+2029 are legal JSON but act as line terminators in some
                        // consumers (JS string literals, several log viewers), so they are
                        // escaped too: cheap insurance for text that came from the game.
                        if (c < 0x20 || c == '\u2028' || c == '\u2029')
                            sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }

        /// <summary>Locale-independent number formatting -- a comma decimal separator would break JSON.</summary>
        public static string Num(double d)
        {
            if (double.IsNaN(d) || double.IsInfinity(d)) return "null";
            return d.ToString("R", CultureInfo.InvariantCulture);
        }

        public static string Num(long l) => l.ToString(CultureInfo.InvariantCulture);

        public static string Bool(bool b) => b ? "true" : "false";

        // ---------------------------------------------------------------- reading

        /// <summary>Parse a JSON document. Returns null when the text is not valid JSON.</summary>
        public static JsonValue Parse(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            try
            {
                var p = new Parser(text);
                p.SkipWs();
                var v = p.ReadValue();
                p.SkipWs();
                return v;
            }
            catch (Exception)
            {
                return null;
            }
        }

        private sealed class Parser
        {
            private readonly string _s;
            private int _i;

            public Parser(string s) { _s = s; }

            public void SkipWs()
            {
                while (_i < _s.Length && (_s[_i] == ' ' || _s[_i] == '\t' || _s[_i] == '\r' || _s[_i] == '\n')) _i++;
            }

            public JsonValue ReadValue()
            {
                SkipWs();
                if (_i >= _s.Length) throw new FormatException("eof");

                var c = _s[_i];
                switch (c)
                {
                    case '{': return ReadObject();
                    case '[': return ReadArray();
                    case '"': return JsonValue.OfString(ReadString());
                    case 't': Expect("true"); return JsonValue.OfBool(true);
                    case 'f': Expect("false"); return JsonValue.OfBool(false);
                    case 'n': Expect("null"); return JsonValue.Null;
                    default: return JsonValue.OfNumber(ReadNumber());
                }
            }

            private JsonValue ReadObject()
            {
                var obj = new Dictionary<string, JsonValue>(StringComparer.Ordinal);
                _i++;                       // '{'
                SkipWs();
                if (_i < _s.Length && _s[_i] == '}') { _i++; return JsonValue.OfObject(obj); }

                while (true)
                {
                    SkipWs();
                    var key = ReadString();
                    SkipWs();
                    if (_i >= _s.Length || _s[_i] != ':') throw new FormatException("expected ':'");
                    _i++;
                    obj[key] = ReadValue();
                    SkipWs();
                    if (_i >= _s.Length) throw new FormatException("eof in object");
                    if (_s[_i] == ',') { _i++; continue; }
                    if (_s[_i] == '}') { _i++; break; }
                    throw new FormatException("expected ',' or '}'");
                }
                return JsonValue.OfObject(obj);
            }

            private JsonValue ReadArray()
            {
                var list = new List<JsonValue>();
                _i++;                       // '['
                SkipWs();
                if (_i < _s.Length && _s[_i] == ']') { _i++; return JsonValue.OfArray(list); }

                while (true)
                {
                    list.Add(ReadValue());
                    SkipWs();
                    if (_i >= _s.Length) throw new FormatException("eof in array");
                    if (_s[_i] == ',') { _i++; continue; }
                    if (_s[_i] == ']') { _i++; break; }
                    throw new FormatException("expected ',' or ']'");
                }
                return JsonValue.OfArray(list);
            }

            private string ReadString()
            {
                if (_i >= _s.Length || _s[_i] != '"') throw new FormatException("expected string");
                _i++;
                var sb = new StringBuilder();
                while (true)
                {
                    if (_i >= _s.Length) throw new FormatException("eof in string");
                    var c = _s[_i++];
                    if (c == '"') break;

                    if (c != '\\') { sb.Append(c); continue; }

                    if (_i >= _s.Length) throw new FormatException("eof in escape");
                    var e = _s[_i++];
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (_i + 4 > _s.Length) throw new FormatException("bad \\u");
                            sb.Append((char)Convert.ToInt32(_s.Substring(_i, 4), 16));
                            _i += 4;
                            break;
                        default: throw new FormatException("bad escape \\" + e);
                    }
                }
                return sb.ToString();
            }

            private double ReadNumber()
            {
                var start = _i;
                while (_i < _s.Length && "-+.eE0123456789".IndexOf(_s[_i]) >= 0) _i++;
                if (_i == start) throw new FormatException("expected number");
                return double.Parse(_s.Substring(start, _i - start), CultureInfo.InvariantCulture);
            }

            private void Expect(string literal)
            {
                if (_i + literal.Length > _s.Length || string.CompareOrdinal(_s, _i, literal, 0, literal.Length) != 0)
                    throw new FormatException("expected " + literal);
                _i += literal.Length;
            }
        }
    }

    /// <summary>A parsed JSON value. Deliberately tiny: only what the bridge needs.</summary>
    internal sealed class JsonValue
    {
        public static readonly JsonValue Null = new JsonValue { Kind = JKind.Null };

        private enum JKind { Null, Bool, Number, String, Object, Array }

        private JKind Kind;
        private bool _b;
        private double _n;
        private string _s;
        private Dictionary<string, JsonValue> _o;
        private List<JsonValue> _a;

        public static JsonValue OfBool(bool b) => new JsonValue { Kind = JKind.Bool, _b = b };
        public static JsonValue OfNumber(double d) => new JsonValue { Kind = JKind.Number, _n = d };
        public static JsonValue OfString(string s) => new JsonValue { Kind = JKind.String, _s = s };
        public static JsonValue OfObject(Dictionary<string, JsonValue> o) => new JsonValue { Kind = JKind.Object, _o = o };
        public static JsonValue OfArray(List<JsonValue> a) => new JsonValue { Kind = JKind.Array, _a = a };

        public bool IsNull => Kind == JKind.Null;
        public bool IsObject => Kind == JKind.Object;

        public string AsString(string fallback = null) => Kind == JKind.String ? _s : fallback;

        public bool AsBool(bool fallback = false)
        {
            if (Kind == JKind.Bool) return _b;
            if (Kind == JKind.Number) return Math.Abs(_n) > double.Epsilon;
            if (Kind == JKind.String) return string.Equals(_s, "true", StringComparison.OrdinalIgnoreCase);
            return fallback;
        }

        public double AsDouble(double fallback = 0)
        {
            if (Kind == JKind.Number) return _n;
            if (Kind == JKind.String && double.TryParse(_s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d)) return d;
            if (Kind == JKind.Bool) return _b ? 1 : 0;
            return fallback;
        }

        public int AsInt(int fallback = 0) => (int)AsDouble(fallback);

        public long AsLong(long fallback = 0)
        {
            if (Kind == JKind.Number) return (long)_n;
            if (Kind == JKind.String && long.TryParse(_s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var l)) return l;
            return fallback;
        }

        /// <summary>Member lookup; returns <see cref="Null"/> when absent so callers never null-check.</summary>
        public JsonValue this[string key]
        {
            get
            {
                if (Kind == JKind.Object && _o.TryGetValue(key, out var v) && v != null) return v;
                return Null;
            }
        }

        public bool Has(string key) => Kind == JKind.Object && _o.ContainsKey(key);

        public IEnumerable<JsonValue> Items
        {
            get
            {
                if (Kind != JKind.Array) yield break;
                foreach (var v in _a) yield return v;
            }
        }

        public int Count => Kind == JKind.Array ? _a.Count : (Kind == JKind.Object ? _o.Count : 0);
    }
}
