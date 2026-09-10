using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;
using EasyEdgeApps.Core;
using Svg;

namespace EasyEdgeApps.Windows;

public static class StaticSvg
{
    public static Bitmap Render(byte[] bytes)
    {
        if (bytes.Length > 1024 * 1024) throw new ValidationException("Static SVG exceeds 1 MiB.");
        using var stream = new MemoryStream(bytes, false);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1024 * 1024 });
        var document = XDocument.Load(reader);
        var allowed = new HashSet<string>(new[] { "svg", "g", "defs", "title", "desc", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "linearGradient", "radialGradient", "stop", "clipPath", "use", "style" }, StringComparer.Ordinal);
        var elements = document.Descendants().ToArray();
        if (document.Root == null || document.Root.Name.LocalName != "svg" || elements.Length > 2048) throw new ValidationException("Invalid or oversized static SVG.");
        foreach (var element in elements)
        {
            if (element.Name.NamespaceName != "http://www.w3.org/2000/svg" || !allowed.Contains(element.Name.LocalName) || element.Ancestors().Take(33).Count() > 32)
                throw new ValidationException("Only bounded static SVG shapes are supported.");
            foreach (var attribute in element.Attributes())
            {
                if (attribute.IsNamespaceDeclaration) continue;
                var name = attribute.Name.LocalName;
                var value = attribute.Value;
                if (name.StartsWith("on", StringComparison.OrdinalIgnoreCase) || value.Length > 32768 ||
                    (name == "href" && (!value.StartsWith("#", StringComparison.Ordinal) || value.Length < 2)) ||
                    value.Contains("@", StringComparison.Ordinal) || value.Contains("\\", StringComparison.Ordinal) ||
                    Regex.IsMatch(value, "url\\(\\s*['\"]?(?!#)[^)]", RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(100)))
                    throw new ValidationException("Active content and external SVG resources are not allowed.");
            }
            if (element.Name.LocalName == "style" && (element.Value.Contains('@') || element.Value.Contains('\\') || Regex.IsMatch(element.Value, "url\\(\\s*['\"]?(?!#)[^)]", RegexOptions.IgnoreCase, TimeSpan.FromMilliseconds(100))))
                throw new ValidationException("External SVG styles are not allowed.");
        }
        var source = document.ToString(SaveOptions.DisableFormatting);
        var svg = SvgDocument.FromSvg<SvgDocument>(source);
        return svg.Draw(256, 256) ?? throw new ValidationException("The static SVG did not render.");
    }
}