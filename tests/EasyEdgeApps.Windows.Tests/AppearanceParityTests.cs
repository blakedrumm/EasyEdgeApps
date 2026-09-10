using System.Drawing.Imaging;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class AppearanceParityTests
{
    [Fact]
    public void OriginalStarfieldHasOpaqueRepeatableFramesAndRespondsToTimeAndPointer()
    {
        var rendererType = typeof(IconService).Assembly.GetType("EasyEdgeApps.Windows.StarfieldRenderer");
        Assert.NotNull(rendererType);
        using var renderer = (IDisposable)Activator.CreateInstance(rendererType)!;
        var render = rendererType.GetMethod("Render")!;
        var first = Frame(renderer, render, 0, new(0.5f, 0.5f), 0);
        Assert.Equal(first, Frame(renderer, render, 0, new(0.5f, 0.5f), 0));
        Assert.All(first, pixel => Assert.Equal(255, (int)((uint)pixel >> 24)));
        Assert.True(first.Distinct().Count() > 100, "The original scene must contain visible stars, not a flat background.");
        Assert.Contains(unchecked((int)0xff050709), first);
        Assert.NotEqual(Hash(first), Hash(Frame(renderer, render, 20, new(0.5f, 0.5f), 0)));
        Assert.NotEqual(Hash(first), Hash(Frame(renderer, render, 0, new(1, 0), 1)));
        renderer.Dispose();
        var failure = Assert.Throws<TargetInvocationException>(() => Frame(renderer, render, 0, new(0.5f, 0.5f), 0));
        Assert.IsType<ObjectDisposedException>(failure.InnerException);
    }

    private static int[] Frame(IDisposable renderer, MethodInfo render, double seconds, PointF pointer, float influence)
    {
        using var bitmap = new Bitmap(960, 640, PixelFormat.Format32bppPArgb);
        using (var graphics = Graphics.FromImage(bitmap)) render.Invoke(renderer, [graphics, bitmap.Size, seconds, pointer, influence]);
        var data = bitmap.LockBits(new(Point.Empty, bitmap.Size), ImageLockMode.ReadOnly, PixelFormat.Format32bppPArgb);
        try
        {
            var pixels = new int[bitmap.Width * bitmap.Height];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            return pixels;
        }
        finally { bitmap.UnlockBits(data); }
    }

    private static string Hash(int[] pixels) => Convert.ToHexString(SHA256.HashData(MemoryMarshal.AsBytes(pixels.AsSpan())));
}