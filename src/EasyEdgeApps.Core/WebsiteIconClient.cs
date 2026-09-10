using System.Net;
using System.Net.Http.Headers;
using AngleSharp.Html.Parser;

namespace EasyEdgeApps.Core;

public sealed record DownloadedIcon(string Website, string Source, string Format, byte[] Bytes);
public sealed record ResolvedWebsite(string Website, bool UsedHttpFallback);

public sealed class WebsiteIconClient : IDisposable
{
    private readonly HttpClient client;
    public WebsiteIconClient(HttpMessageHandler? handler = null)
    {
        client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, Credentials = null,
            DefaultProxyCredentials = null, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli }) { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("EasyEdgeApps", "2.0"));
    }

    public async Task<ResolvedWebsite> ResolveAsync(string website, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var address = Identity.Website(website, true);
        var supplied = website.Trim();
        if (supplied.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || supplied.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            return new(address, false);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, address);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            return new(address, false);
        }
        catch (HttpRequestException failure) when (failure.HttpRequestError is HttpRequestError.ConnectionError or HttpRequestError.NameResolutionError)
        {
            address = "http://" + address[8..];
            using var request = new HttpRequestMessage(HttpMethod.Head, address);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            return new(address, true);
        }
    }

    public Task<DownloadedIcon> FetchAsync(string website, CancellationToken cancellationToken) => FetchAsync(website, null, cancellationToken);

    public async Task<DownloadedIcon> FetchAsync(string website, Func<DownloadedIcon, CancellationToken, Task<byte[]>>? convert, CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(45));
        var token = deadline.Token;
        website = website.Trim();
        var explicitScheme = website.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || website.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        var address = Identity.Website(website, true);
        (Uri Address, string MediaType, byte[] Bytes) page;
        try { page = await ReadAsync(new Uri(address), 1024 * 1024, token, true); }
        catch (HttpRequestException failure) when (!explicitScheme && failure.HttpRequestError is HttpRequestError.ConnectionError or HttpRequestError.NameResolutionError)
        { address = "http://" + address[8..]; page = await ReadAsync(new Uri(address), 1024 * 1024, token, true); }
        var candidates = new List<Uri>();
        if (page.MediaType.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
            return await Prepare(new(page.Address.AbsoluteUri, page.Address.AbsoluteUri, Format(page.MediaType, page.Bytes), page.Bytes));
        using (var document = await new HtmlParser(new HtmlParserOptions { IsScripting = false }).ParseDocumentAsync(new MemoryStream(page.Bytes, false), token))
        {
            var baseAddress = page.Address;
            var declaredBase = document.QuerySelector("base[href]")?.GetAttribute("href");
            if (Uri.TryCreate(page.Address, declaredBase, out var baseUri) && SafeCandidate(baseUri, page.Address)) baseAddress = baseUri;
            foreach (var link in document.QuerySelectorAll("link[href]").Take(256))
            {
                var relations = (link.GetAttribute("rel") ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                if (!relations.Any(relation => relation.Equals("icon", StringComparison.OrdinalIgnoreCase) || relation.Equals("apple-touch-icon", StringComparison.OrdinalIgnoreCase))) continue;
                if (Uri.TryCreate(baseAddress, link.GetAttribute("href"), out var candidate) && SafeCandidate(candidate, page.Address) && !candidates.Contains(candidate)) candidates.Add(candidate);
                if (candidates.Count == 16) break;
            }
        }
        candidates.Add(new Uri(page.Address, "/favicon.ico"));
        foreach (var candidate in candidates)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var icon = await ReadAsync(candidate, 8 * 1024 * 1024, token);
                return await Prepare(new(page.Address.AbsoluteUri, icon.Address.AbsoluteUri, Format(icon.MediaType, icon.Bytes), icon.Bytes));
            }
            catch (Exception failure) when (failure is ValidationException or HttpRequestException) { }
        }
        throw new ValidationException("No supported website icon was available. The existing icon is unchanged.");

        async Task<DownloadedIcon> Prepare(DownloadedIcon icon)
        {
            if (convert is null) return icon;
            var converted = await convert(icon, token);
            token.ThrowIfCancellationRequested();
            IconContract.Validate(converted);
            return icon with { Format = ".ico", Bytes = converted };
        }
    }

    private async Task<(Uri Address, string MediaType, byte[] Bytes)> ReadAsync(Uri uri, int maximum, CancellationToken token, bool allowPageRefusal = false)
    {
        var original = uri;
        for (var redirect = 0; redirect <= 5; redirect++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if ((int)response.StatusCode is >= 300 and < 400)
            {
                if (response.Headers.Location is null || !Uri.TryCreate(uri, response.Headers.Location, out var next) || !SafeCandidate(next, original))
                    throw new ValidationException("The website redirected to an unsafe address.");
                uri = next;
                continue;
            }
            if (response.StatusCode != HttpStatusCode.OK)
            {
                if (allowPageRefusal) return (uri, "", []);
                throw new ValidationException("The website did not provide this resource.");
            }
            if (response.Content.Headers.ContentLength > maximum) throw new ValidationException("The website resource exceeds its size bound.");
            using var input = await response.Content.ReadAsStreamAsync(token);
            using var output = new MemoryStream();
            var buffer = new byte[32768];
            int count;
            while ((count = await input.ReadAsync(buffer, token)) > 0)
            {
                if (output.Length + count > maximum) throw new ValidationException("The website resource exceeds its size bound.");
                output.Write(buffer, 0, count);
            }
            return (uri, response.Content.Headers.ContentType?.MediaType ?? "", output.ToArray());
        }
        throw new ValidationException("Too many website redirects.");
    }

    private static bool SafeCandidate(Uri candidate, Uri origin)
    {
        try { _ = Identity.Website(candidate.AbsoluteUri); return origin.Scheme != "https" || candidate.Scheme == "https"; }
        catch (ValidationException) { return false; }
    }

    private static string Format(string mediaType, byte[] bytes)
    {
        if (bytes.AsSpan().StartsWith(new byte[] { 0, 0, 1, 0 })) return ".ico";
        if (bytes.AsSpan().StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return ".png";
        if (bytes.Length > 2 && bytes[0] == 255 && bytes[1] == 216) return ".jpg";
        if (bytes.AsSpan().StartsWith("GIF87a"u8) || bytes.AsSpan().StartsWith("GIF89a"u8)) return ".gif";
        if (bytes.AsSpan().StartsWith("BM"u8)) return ".bmp";
        if (mediaType.Equals("image/svg+xml", StringComparison.OrdinalIgnoreCase)) return ".svg";
        throw new ValidationException("The resource is not a supported icon image.");
    }

    public void Dispose() => client.Dispose();
}