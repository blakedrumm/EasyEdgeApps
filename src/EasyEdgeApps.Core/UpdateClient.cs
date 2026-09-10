using System.Net;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;

namespace EasyEdgeApps.Core;

public sealed record ReleaseAsset(string Name, string Url, long Size);
public sealed record ReleaseInfo(string Tag, string PageUrl, ReleaseAsset[] Assets);

public sealed class UpdateClient : IDisposable
{
    public const string LatestEndpoint = "https://api.github.com/repos/blakedrumm/EasyEdgeApps/releases/latest";
    private readonly HttpClient client;
    public UpdateClient(HttpMessageHandler? handler = null)
    {
        client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, Credentials = null, DefaultProxyCredentials = null }) { Timeout = TimeSpan.FromSeconds(30) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("EasyEdgeApps", "2.0"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
    }

    public async Task<ReleaseInfo> CheckAsync(CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestEndpoint);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (response.StatusCode != HttpStatusCode.OK || response.Headers.Location is not null) throw new ValidationException("The trusted update endpoint did not return a direct success response.");
        var bytes = await BoundedRead(response.Content, 1024 * 1024, token);
        using var document = StrictJson.Parse(bytes, 1024 * 1024, 32, 16384);
        var root = document.RootElement;
        if (root.ValueKind != System.Text.Json.JsonValueKind.Object) throw new ValidationException("Invalid release metadata.");
        var tag = StrictJson.Text(root, "tag_name");
        var page = StrictJson.Text(root, "html_url");
        if (!Regex.IsMatch(tag, "\\Av[0-9]+\\.[0-9]+\\.[0-9]+\\z") || page != "https://github.com/blakedrumm/EasyEdgeApps/releases/tag/" + tag || StrictJson.Boolean(root, "draft") || StrictJson.Boolean(root, "prerelease"))
            throw new ValidationException("The response is not a trusted stable Easy Edge Apps release.");
        var assets = new List<ReleaseAsset>();
        if (root.TryGetProperty("assets", out var items))
        {
            if (items.ValueKind != System.Text.Json.JsonValueKind.Array || items.GetArrayLength() > 100) throw new ValidationException("Invalid release asset list.");
            foreach (var asset in items.EnumerateArray())
            {
                if (asset.ValueKind != System.Text.Json.JsonValueKind.Object) throw new ValidationException("Invalid release asset metadata.");
                var name = StrictJson.Text(asset, "name");
                var url = StrictJson.Text(asset, "browser_download_url");
                if (!Regex.IsMatch(name, "\\AEasyEdgeApps-[0-9A-Za-z.+_-]+\\.(zip|msi)\\z") || url != "https://github.com/blakedrumm/EasyEdgeApps/releases/download/" + tag + "/" + name) continue;
                if (!asset.TryGetProperty("size", out var storedSize) || storedSize.ValueKind != System.Text.Json.JsonValueKind.Number || !storedSize.TryGetInt64(out var size))
                    throw new ValidationException("Invalid release asset size.");
                if (size is < 1 or > 1073741824) continue;
                assets.Add(new(name, url, size));
            }
        }
        return new(tag, page, assets.ToArray());
    }

    public async Task DownloadAsync(ReleaseInfo release, ReleaseAsset asset, Stream destination, IProgress<long>? progress, CancellationToken token)
    {
        if (!release.Assets.Contains(asset) || asset.Url != "https://github.com/blakedrumm/EasyEdgeApps/releases/download/" + release.Tag + "/" + asset.Name)
            throw new ValidationException("Select an asset from the validated release response.");
        var uri = new Uri(asset.Url);
        for (var redirect = 0; redirect <= 3; redirect++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if ((int)response.StatusCode is >= 300 and < 400)
            {
                var location = response.Headers.Location;
                if (location is null || !location.IsAbsoluteUri || location.Scheme != "https" || location.Port != 443 || location.UserInfo.Length != 0 ||
                    location.Host is not ("release-assets.githubusercontent.com" or "objects.githubusercontent.com")) throw new ValidationException("Update download redirected outside the allowed release asset hosts.");
                uri = location;
                continue;
            }
            if (response.StatusCode != HttpStatusCode.OK) throw new ValidationException("Update download failed.");
            if (response.Content.Headers.ContentLength is long length && length != asset.Size) throw new ValidationException("The update size changed after approval.");
            using var body = await response.Content.ReadAsStreamAsync(token);
            var buffer = new byte[65536];
            long total = 0;
            int count;
            while ((count = await body.ReadAsync(buffer, token)) != 0)
            {
                total += count;
                if (total > asset.Size) throw new ValidationException("The update exceeds its approved size.");
                await destination.WriteAsync(buffer.AsMemory(0, count), token);
                progress?.Report(total);
            }
            if (total != asset.Size) throw new ValidationException("The update download is incomplete.");
            return;
        }
        throw new ValidationException("Too many update redirects.");
    }

    private static async Task<byte[]> BoundedRead(HttpContent content, int maximum, CancellationToken token)
    {
        if (content.Headers.ContentLength > maximum) throw new ValidationException("Update response exceeds its bound.");
        using var input = await content.ReadAsStreamAsync(token);
        using var output = new MemoryStream();
        var buffer = new byte[16384];
        int count;
        while ((count = await input.ReadAsync(buffer, token)) != 0)
        {
            if (output.Length + count > maximum) throw new ValidationException("Update response exceeds its bound.");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }

    public void Dispose() => client.Dispose();
}