using System;
using System.Buffers.Binary;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using EasyEdgeApps.Core;
using EasyEdgeApps.Persistence;

namespace EasyEdgeApps.Windows;

public static class IconService
{
    public const int MaximumInputBytes = 8 * 1024 * 1024;
    public const int MaximumDimension = 4096;

    public static byte[] FromFile(string path, CancellationToken cancellationToken = default)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".ico" or ".png" or ".jpg" or ".jpeg" or ".gif" or ".bmp" or ".svg")) throw new ValidationException("Choose an ICO, PNG, JPEG, GIF, BMP or static SVG image.");
        return Convert(SafeFiles.Read(Path.GetFullPath(path), MaximumInputBytes), extension, cancellationToken);
    }

    public static byte[] Convert(byte[] bytes, string format, CancellationToken cancellationToken = default)
    {
        if (bytes.Length is < 8 or > MaximumInputBytes) throw new ValidationException("Choose an image no larger than 8 MiB.");
        cancellationToken.ThrowIfCancellationRequested();
        ValidateHeader(bytes, format);
        using var stream = new MemoryStream(bytes, false);
        using var source = format == ".ico" ? DecodeIcon(bytes) : format == ".svg" ? StaticSvg.Render(bytes) : Image.FromStream(stream, false, false);
        if (source.Width < 1 || source.Height < 1 || source.Width > MaximumDimension || source.Height > MaximumDimension || (long)source.Width * source.Height > 16 * 1024 * 1024)
            throw new ValidationException("Choose an image no larger than 4096 pixels per side and 16 megapixels.");
        if (format is not (".ico" or ".svg") && source.RawFormat.Guid != ImageFormat.Png.Guid && source.RawFormat.Guid != ImageFormat.Jpeg.Guid && source.RawFormat.Guid != ImageFormat.Gif.Guid && source.RawFormat.Guid != ImageFormat.Bmp.Guid)
            throw new ValidationException("The file is not a PNG, JPEG, GIF or BMP image.");
        using var target = new Bitmap(256, 256, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(target))
        {
            graphics.Clear(Color.Transparent); graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            var scale = Math.Min(256d / source.Width, 256d / source.Height);
            var width = Math.Max(1, (int)Math.Round(source.Width * scale));
            var height = Math.Max(1, (int)Math.Round(source.Height * scale));
            graphics.DrawImage(source, new Rectangle((256 - width) / 2, (256 - height) / 2, width, height));
        }
        cancellationToken.ThrowIfCancellationRequested();
        return Encode(target);
    }

    public static void ValidateHeader(byte[] bytes, string format)
    {
        long width = 0, height = 0;
        if (format == ".ico") { IconContract.Validate(bytes); return; }
        if (format == ".svg") { if (bytes.Length > 1024 * 1024) throw new ValidationException("Static SVG exceeds 1 MiB."); return; }
        if (format == ".png" && bytes.Length >= 33 && bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) && bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8))
        { width = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(16)); height = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(20)); }
        else if (format == ".gif" && bytes.Length >= 13 && (bytes.AsSpan().StartsWith("GIF87a"u8) || bytes.AsSpan().StartsWith("GIF89a"u8)))
        { width = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(6)); height = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(8)); }
        else if (format == ".bmp" && bytes.Length >= 26 && bytes.AsSpan().StartsWith("BM"u8))
        {
            var headerSize = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(14));
            if (headerSize == 12)
            { width = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(18)); height = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(20)); }
            else if (headerSize is 40 or 52 or 56 or 108 or 124 && bytes.Length >= 14 + headerSize)
            { width = BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(18)); height = Math.Abs((long)BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(22))); }
            var pixelOffset = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(10));
            if (pixelOffset < 14 + headerSize || pixelOffset >= bytes.Length) throw new ValidationException("Invalid BMP pixel offset.");
        }
        else if (format is ".jpg" or ".jpeg" && bytes.Length >= 4 && bytes[0] == 255 && bytes[1] == 216)
        {
            for (var offset = 2; offset + 3 < bytes.Length;)
            {
                if (bytes[offset++] != 255) throw new ValidationException("Invalid JPEG marker.");
                while (offset < bytes.Length && bytes[offset] == 255) offset++;
                if (offset >= bytes.Length) break;
                var marker = bytes[offset++];
                if (marker is 0xd9 or 0xda) break;
                if (marker is 0x01 or >= 0xd0 and <= 0xd8) continue;
                if (offset + 2 > bytes.Length) break;
                var length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset));
                if (length < 2 || offset + length > bytes.Length) throw new ValidationException("Invalid JPEG segment length.");
                if (marker is >= 0xc0 and <= 0xcf && marker is not (0xc4 or 0xc8 or 0xcc))
                {
                    if (length < 8) throw new ValidationException("Invalid JPEG frame.");
                    height = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset + 3)); width = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset + 5)); break;
                }
                offset += length;
            }
        }
        if (width is < 1 or > MaximumDimension || height is < 1 or > MaximumDimension || (long)width * height > 16 * 1024 * 1024)
            throw new ValidationException("Choose a valid PNG, JPEG, GIF or BMP no larger than 4096 pixels per side and 16 megapixels.");
    }

    public static void Validate(byte[] bytes)
    {
        IconContract.Validate(bytes);
        using var bitmap = DecodeIcon(bytes);
        if (bitmap.Width is < 1 or > 256 || bitmap.Height is < 1 or > 256) throw new ValidationException("Invalid decoded icon dimensions.");
        using var drawn = new Bitmap(bitmap.Width, bitmap.Height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(drawn);
        graphics.DrawImageUnscaled(bitmap, 0, 0);
        _ = drawn.GetPixel(0, 0);
    }

    private static Bitmap DecodeIcon(byte[] bytes)
    {
        IconContract.Validate(bytes);
        using var stream = new MemoryStream(bytes, false);
        using var icon = new Icon(stream, 256, 256);
        return icon.ToBitmap();
    }

    public static byte[] PreviewPng(byte[] bytes)
    {
        using var image = DecodeIcon(bytes);
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }

    public static byte[] Generate(string name)
    {
        name = Identity.Name(name);
        var palette = new[] { "#126C65", "#2859A0", "#A03558", "#654F96" };
        var color = palette[int.Parse(Identity.LegacyId(name)[..2], NumberStyles.HexNumber, CultureInfo.InvariantCulture) % palette.Length];
        using var bitmap = new Bitmap(256, 256, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
        using (var font = new Font("Segoe UI", 144, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
        {
            graphics.Clear(ColorTranslator.FromHtml(color));
            graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            graphics.DrawString(StringInfo.GetNextTextElement(name).ToUpperInvariant(), font, Brushes.White, new RectangleF(0, 0, 256, 256), format);
        }
        return Encode(bitmap);
    }

    private static byte[] Encode(Bitmap bitmap)
    {
        var width = bitmap.Width;
        var height = bitmap.Height;
        var maskStride = ((width + 31) / 32) * 4;
        var imageSize = width * height * 4 + maskStride * height;
        using var stream = new MemoryStream();
        using (var writer = new BinaryWriter(stream, Encoding.UTF8, true))
        {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)1);
            writer.Write((byte)(width == 256 ? 0 : width)); writer.Write((byte)(height == 256 ? 0 : height)); writer.Write((byte)0); writer.Write((byte)0);
            writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(40 + imageSize); writer.Write(22);
            writer.Write(40); writer.Write(width); writer.Write(height * 2); writer.Write((ushort)1); writer.Write((ushort)32);
            writer.Write(0); writer.Write(imageSize); writer.Write(0); writer.Write(0); writer.Write(0); writer.Write(0);
            for (var row = height - 1; row >= 0; row--)
            for (var column = 0; column < width; column++)
            {
                var pixel = bitmap.GetPixel(column, row);
                writer.Write(pixel.B); writer.Write(pixel.G); writer.Write(pixel.R); writer.Write(pixel.A);
            }
            writer.Write(new byte[maskStride * height]);
        }
        var bytes = stream.ToArray();
        IconContract.Validate(bytes);
        return bytes;
    }
}