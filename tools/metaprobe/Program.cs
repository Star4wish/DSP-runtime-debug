using System;
using System.Collections.Generic;
using System.Linq;
using Mono.Cecil;

namespace MetaProbe
{
    /// <summary>
    /// Reads a managed assembly with Mono.Cecil and prints type/member signatures.
    ///
    /// Usage:
    ///   metaprobe &lt;assembly&gt; types [nameFilter]
    ///   metaprobe &lt;assembly&gt; type &lt;fullTypeName&gt; [--all]
    ///   metaprobe &lt;assembly&gt; find &lt;substring&gt; [kind]     kind = type|field|property|method
    ///
    /// Output is names + signatures only (no method bodies), which is the
    /// redistribution-safe part of reverse engineering per dsp-wiki.
    /// </summary>
    internal static class Program
    {
        private static int Main(string[] args)
        {
            if (args.Length < 2)
            {
                Console.Error.WriteLine("usage: metaprobe <assembly> types|type|find ...");
                return 2;
            }

            var asmPath = args[0];
            var cmd = args[1].ToLowerInvariant();

            using var resolver = new DefaultAssemblyResolver();
            resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(asmPath)));
            var rp = new ReaderParameters { AssemblyResolver = resolver, ReadSymbols = false };
            using var asm = AssemblyDefinition.ReadAssembly(asmPath, rp);

            switch (cmd)
            {
                case "types":
                    return ListTypes(asm, args.Length > 2 ? args[2] : null);
                case "type":
                    if (args.Length < 3) { Console.Error.WriteLine("need type name"); return 2; }
                    return DumpType(asm, args[2], args.Contains("--all"));
                case "find":
                    if (args.Length < 3) { Console.Error.WriteLine("need substring"); return 2; }
                    return Find(asm, args[2], args.Length > 3 ? args[3].ToLowerInvariant() : null);
                case "statics":
                    return Statics(asm, args.Length > 2 ? args[2] : null);
                case "refs":
                    foreach (var r in asm.Modules.SelectMany(m => m.AssemblyReferences).OrderBy(r => r.Name))
                        Console.WriteLine($"{r.Name}, Version={r.Version}");
                    return 0;
                default:
                    Console.Error.WriteLine("unknown command " + cmd);
                    return 2;
            }
        }

        private static IEnumerable<TypeDefinition> AllTypes(AssemblyDefinition asm)
            => asm.Modules.SelectMany(m => m.Types).SelectMany(Flatten);

        private static IEnumerable<TypeDefinition> Flatten(TypeDefinition t)
        {
            yield return t;
            foreach (var n in t.NestedTypes.SelectMany(Flatten)) yield return n;
        }

        private static int ListTypes(AssemblyDefinition asm, string filter)
        {
            foreach (var t in AllTypes(asm).OrderBy(t => t.FullName))
            {
                if (filter != null && t.FullName.IndexOf(filter, StringComparison.OrdinalIgnoreCase) < 0) continue;
                Console.WriteLine($"{Vis(t)} {(t.IsInterface ? "interface" : t.IsEnum ? "enum" : t.IsValueType ? "struct" : "class")} {t.FullName}");
            }
            return 0;
        }

        private static int Statics(AssemblyDefinition asm, string filter)
        {
            foreach (var t in AllTypes(asm))
            {
                var statics = t.Fields.Where(f => f.IsStatic).ToList();
                if (statics.Count == 0) continue;
                if (filter != null && t.FullName.IndexOf(filter, StringComparison.OrdinalIgnoreCase) < 0) continue;
                Console.WriteLine($"=== {t.FullName}");
                foreach (var f in statics) Console.WriteLine($"    static {Short(f.FieldType)} {f.Name}");
            }
            return 0;
        }

        private static int DumpType(AssemblyDefinition asm, string name, bool all)
        {
            var hits = AllTypes(asm)
                .Where(t => string.Equals(t.FullName, name, StringComparison.Ordinal)
                         || string.Equals(t.Name, name, StringComparison.Ordinal)
                         || t.FullName.EndsWith("." + name, StringComparison.Ordinal))
                .ToList();

            if (hits.Count == 0) { Console.Error.WriteLine("type not found: " + name); return 1; }

            foreach (var t in hits)
            {
                Console.WriteLine($"===== {Vis(t)} {(t.IsEnum ? "enum" : "class")} {t.FullName} : {Short(t.BaseType)}");
                foreach (var i in t.Interfaces) Console.WriteLine($"      impl {Short(i.InterfaceType)}");

                var fields = t.Fields.Where(f => all || f.IsPublic || f.IsAssembly || f.IsFamily).ToList();
                if (fields.Count > 0)
                {
                    Console.WriteLine("  -- fields --");
                    foreach (var f in fields)
                        Console.WriteLine($"     {(f.IsStatic ? "static " : "")}{Vis(f)} {Short(f.FieldType)} {f.Name}");
                }

                var props = t.Properties.Where(p => all || (p.GetMethod?.IsPublic ?? false) || (p.SetMethod?.IsPublic ?? false)).ToList();
                if (props.Count > 0)
                {
                    Console.WriteLine("  -- properties --");
                    foreach (var p in props)
                        Console.WriteLine($"     {(IsStaticProp(p) ? "static " : "")}{Short(p.PropertyType)} {p.Name} {{ {(p.GetMethod != null ? "get; " : "")}{(p.SetMethod != null ? "set; " : "")}}}");
                }

                var methods = t.Methods.Where(m => (all || m.IsPublic || m.IsAssembly || m.IsFamily) && !m.IsGetter && !m.IsSetter && m.Name != ".ctor" && m.Name != ".cctor").ToList();
                if (methods.Count > 0)
                {
                    Console.WriteLine("  -- methods --");
                    foreach (var m in methods)
                        Console.WriteLine($"     {(m.IsStatic ? "static " : "")}{Vis(m)} {Short(m.ReturnType)} {m.Name}({string.Join(", ", m.Parameters.Select(p => Short(p.ParameterType) + " " + p.Name))})");
                }

                if (t.IsEnum)
                {
                    Console.WriteLine("  -- values --");
                    foreach (var f in t.Fields.Where(f => f.HasConstant))
                        Console.WriteLine($"     {f.Name} = {f.Constant}");
                }
            }
            return 0;
        }

        private static bool IsStaticProp(PropertyDefinition p)
            => (p.GetMethod?.IsStatic ?? false) || (p.SetMethod?.IsStatic ?? false);

        private static int Find(AssemblyDefinition asm, string needle, string kind)
        {
            foreach (var t in AllTypes(asm))
            {
                if (kind == null || kind == "type")
                {
                    if (t.FullName.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0)
                        Console.WriteLine($"type     {t.FullName}");
                }
                if (kind == null || kind == "field")
                    foreach (var f in t.Fields.Where(f => f.Name.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0))
                        Console.WriteLine($"field    {t.FullName}::{f.Name} : {Short(f.FieldType)}");
                if (kind == null || kind == "property")
                    foreach (var p in t.Properties.Where(p => p.Name.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0))
                        Console.WriteLine($"property {t.FullName}::{p.Name} : {Short(p.PropertyType)}");
                if (kind == null || kind == "method")
                    foreach (var m in t.Methods.Where(m => m.Name.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0 && !m.IsGetter && !m.IsSetter))
                        Console.WriteLine($"method   {t.FullName}::{m.Name}({string.Join(", ", m.Parameters.Select(p => Short(p.ParameterType)))}) : {Short(m.ReturnType)}");
            }
            return 0;
        }

        private static string Vis(TypeDefinition t)
            => t.IsPublic ? "public" : t.IsNotPublic ? "internal" : "nested";

        private static string Vis(FieldDefinition f)
            => f.IsPublic ? "public" : f.IsFamily ? "protected" : f.IsAssembly ? "internal" : f.IsPrivate ? "private" : "other";

        private static string Vis(MethodDefinition m)
            => m.IsPublic ? "public" : m.IsFamily ? "protected" : m.IsAssembly ? "internal" : m.IsPrivate ? "private" : "other";

        private static string Short(TypeReference t)
        {
            if (t == null) return "?";
            if (t is GenericInstanceType g)
                return Short(g.ElementType) + "<" + string.Join(",", g.GenericArguments.Select(Short)) + ">";
            if (t is ArrayType a)
                return Short(a.ElementType) + "[]";
            if (t is ByReferenceType r)
                return "ref " + Short(r.ElementType);
            switch (t.MetadataType)
            {
                case MetadataType.Void: return "void";
                case MetadataType.Boolean: return "bool";
                case MetadataType.Int32: return "int";
                case MetadataType.Int64: return "long";
                case MetadataType.Single: return "float";
                case MetadataType.Double: return "double";
                case MetadataType.String: return "string";
                case MetadataType.UInt32: return "uint";
                case MetadataType.Object: return "object";
            }
            return t.Name;
        }
    }
}
