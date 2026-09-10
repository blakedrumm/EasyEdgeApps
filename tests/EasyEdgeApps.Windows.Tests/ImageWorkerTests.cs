using System.Buffers.Binary;
using EasyEdgeApps.Core;
using EasyEdgeApps.Core.Tests;
using EasyEdgeApps.Windows;

namespace EasyEdgeApps.Windows.Tests;

public sealed class ImageWorkerTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancellationAndDeadlineKillTheResourceLimitedOwnedWorkerBeforeReturning(bool expireDeadline)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var executable = Path.Combine(repository, "tests", "EasyEdgeApps.NativeFixture", "bin", configuration, "net10.0-windows10.0.19041.0", "EasyEdgeApps.NativeFixture.exe");
        var readyName = "Local\\EasyEdgeApps-Decoder-" + Guid.NewGuid().ToString("N");
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, readyName);
        using var cancellation = new CancellationTokenSource();
        var marker = Path.Combine(fixture.Root, "decoder.pid");
        var request = System.Text.Encoding.UTF8.GetBytes(marker + "\n" + readyName);
        var work = new IconWorkerClient(executable).ConvertAsync(request, ".png", cancellation.Token);
        System.Diagnostics.Process? owned = null;
        try
        {
            Assert.True(await Task.Run(() => ready.WaitOne(10000)), "The synthetic decoder did not consume its input.");
            owned = System.Diagnostics.Process.GetProcessById(int.Parse(File.ReadAllText(marker), System.Globalization.CultureInfo.InvariantCulture));
            Assert.False(owned.HasExited);
            using var report = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(Path.ChangeExtension(marker, ".limits.json")));
            Assert.True(report.RootElement.GetProperty("Queried").GetBoolean(), "The synthetic child could not query its own Windows job.");
            const uint expectedFlags = 0x2000 | 0x100 | 0x8;
            Assert.Equal(expectedFlags, report.RootElement.GetProperty("Flags").GetUInt32() & expectedFlags);
            Assert.Equal(1u, report.RootElement.GetProperty("ActiveProcesses").GetUInt32());
            Assert.Equal(384ul * 1024 * 1024, report.RootElement.GetProperty("ProcessMemory").GetUInt64());
            if (expireDeadline)
            {
                var failure = await Assert.ThrowsAsync<ValidationException>(() => work.WaitAsync(TimeSpan.FromSeconds(25)));
                Assert.Contains("time limit", failure.Message);
            }
            else
            {
                cancellation.Cancel();
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work.WaitAsync(TimeSpan.FromSeconds(5)));
            }
            Assert.True(owned.WaitForExit(3000), "Cancellation or the deadline returned before the owned decoder exited.");
        }
        finally
        {
            cancellation.Cancel();
            if (owned is not null)
            {
                if (!owned.HasExited) { owned.Kill(true); owned.WaitForExit(10000); }
                owned.Dispose();
            }
            try { await work; } catch (Exception failure) when (failure is OperationCanceledException or ValidationException) { }
        }
    }

    [Theory]
    [InlineData(".gif")]
    [InlineData(".bmp")]
    public async Task LegacyRasterFormatsRenderThroughTheBoundedWorker(string format)
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var worker = new IconWorkerClient(Path.Combine(repository, "src", "EasyEdgeApps.ImageWorker", "bin", configuration, "net10.0-windows10.0.19041.0", "EasyEdgeApps.ImageWorker.exe"));
        var path = Path.Combine(fixture.Root, "synthetic" + format);
        using (var bitmap = new Bitmap(32, 24))
        {
            using var graphics = Graphics.FromImage(bitmap);
            graphics.Clear(Color.FromArgb(230, 50, 30));
            bitmap.Save(path, format == ".gif" ? System.Drawing.Imaging.ImageFormat.Gif : System.Drawing.Imaging.ImageFormat.Bmp);
        }
        var bytes = await worker.FromFileAsync(path, default);
        using var stream = new MemoryStream(bytes);
        using var icon = new Icon(stream);
        using var pixels = icon.ToBitmap();
        Assert.Equal(256, pixels.Width);
        Assert.True(pixels.GetPixel(128, 128).R > 180);
        Assert.True(pixels.GetPixel(128, 128).G < 100);
    }

    [Theory]
    [InlineData(".gif")]
    [InlineData(".bmp")]
    public void OversizedLegacyRasterHeadersAreRejectedBeforeNativeDecode(string format)
    {
        var header = new byte[54];
        if (format == ".gif")
        {
            "GIF89a"u8.CopyTo(header);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(6), 50000);
            BinaryPrimitives.WriteUInt16LittleEndian(header.AsSpan(8), 50000);
        }
        else
        {
            "BM"u8.CopyTo(header);
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(14), 40);
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(18), 50000);
            BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(22), int.MinValue);
        }
        Assert.Throws<ValidationException>(() => IconService.ValidateHeader(header, format));
    }

    [Fact]
    public async Task RealBoundedWorkerRendersStaticSvgAndRejectsActiveContent()
    {
        using var fixture = new TestDirectory();
        var repository = Directory.GetParent(fixture.Root)!.Parent!.FullName;
        var configuration = new DirectoryInfo(AppContext.BaseDirectory).Parent!.Name;
        var worker = new IconWorkerClient(Path.Combine(repository, "src", "EasyEdgeApps.ImageWorker", "bin", configuration, "net10.0-windows10.0.19041.0", "EasyEdgeApps.ImageWorker.exe"));
        var svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 256 256'><rect width='256' height='256' fill='#e45241'/></svg>"u8.ToArray();
        var bytes = await worker.ConvertAsync(svg, ".svg", default);
        using var icon = new Icon(new MemoryStream(bytes));
        using var pixels = icon.ToBitmap();
        Assert.True(pixels.GetPixel(128, 128).R > 180);
        await Assert.ThrowsAsync<ValidationException>(() => worker.ConvertAsync("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"u8.ToArray(), ".svg", default));
        await Assert.ThrowsAsync<ValidationException>(() => worker.ConvertAsync("<!DOCTYPE svg [<!ENTITY private SYSTEM 'file:///private'>]><svg xmlns='http://www.w3.org/2000/svg'>&private;</svg>"u8.ToArray(), ".svg", default));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => worker.ConvertAsync(svg, ".svg", new CancellationToken(true)));
    }

    [Fact]
    public void OversizedPngIsRejectedFromItsHeaderBeforeNativeDecode()
    {
        var header = new byte[33];
        new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }.CopyTo(header, 0);
        "IHDR"u8.CopyTo(header.AsSpan(12));
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(16), 50000);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(20), 50000);
        Assert.Throws<ValidationException>(() => IconService.ValidateHeader(header, ".png"));
    }
}