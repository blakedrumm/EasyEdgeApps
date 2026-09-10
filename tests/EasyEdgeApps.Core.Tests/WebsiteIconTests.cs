using System.Net;
using System.Net.Http.Headers;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Core.Tests;

public sealed class WebsiteIconTests
{
    internal static byte[] ValidIcon()
    {
        var icon = new byte[70];
        icon[2] = icon[4] = icon[6] = icon[7] = icon[10] = icon[26] = icon[34] = 1;
        icon[12] = icon[36] = 32; icon[14] = 48; icon[18] = 22; icon[22] = 40; icon[30] = 2; icon[42] = 4; icon[65] = 255;
        return icon;
    }

    [Fact]
    public async Task RejectedDecoderCandidateTriesNextIconAndKeepsTheResolvedWebsite()
    {
        var requested = new List<string>();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            var uri = request.RequestUri!.AbsoluteUri;
            requested.Add(uri);
            if (requested.Count == 1)
            {
                var redirect = new HttpResponseMessage(HttpStatusCode.Redirect);
                redirect.Headers.Location = new("https://example.com/app/");
                return redirect;
            }
            if (requested.Count == 2) return new(HttpStatusCode.OK) { Content = new StringContent("<link rel='icon' href='broken.png'><link rel='icon' href='good.png'>") };
            return new(HttpStatusCode.OK) { Content = new ByteArrayContent([137, 80, 78, 71, 13, 10, 26, 10]) };
        }));
        var converted = new List<string>();
        var result = await client.FetchAsync("example.com", (image, token) =>
        {
            converted.Add(image.Source);
            token.ThrowIfCancellationRequested();
            if (image.Source.EndsWith("broken.png", StringComparison.Ordinal)) throw new ValidationException("Synthetic decoder rejection.");
            return Task.FromResult(ValidIcon());
        }, default);
        Assert.Equal("https://example.com/app/", result.Website);
        Assert.Equal("https://example.com/app/good.png", result.Source);
        Assert.Equal(".ico", result.Format);
        Assert.Equal(ValidIcon(), result.Bytes);
        Assert.Equal(2, converted.Count);
        Assert.Equal(4, requested.Count);
    }

    [Fact]
    public async Task DecoderCancellationStopsBeforeTryingAnotherCandidate()
    {
        var calls = 0;
        using var cancellation = new CancellationTokenSource();
        using var client = new WebsiteIconClient(new Handler(_ => ++calls == 1
            ? new(HttpStatusCode.OK) { Content = new StringContent("<link rel='icon' href='first.ico'><link rel='icon' href='second.ico'>") }
            : new(HttpStatusCode.OK) { Content = new ByteArrayContent(ValidIcon()) }));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.FetchAsync("example.com", (_, token) =>
        {
            cancellation.Cancel();
            token.ThrowIfCancellationRequested();
            return Task.FromResult(ValidIcon());
        }, cancellation.Token));
        Assert.Equal(2, calls);
    }

    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(respond(request)); }
    }

    private sealed class UnreadableContent : HttpContent
    {
        public bool BodyRead { get; private set; }
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        { BodyRead = true; throw new InvalidOperationException("The address probe must not read a body."); }
    }

    [Theory]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.MethodNotAllowed)]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.Redirect)]
    public async Task AddressProbeRetainsHttpsOnEveryHttpResponseWithoutReadingOrFollowing(HttpStatusCode status)
    {
        var requested = new List<string>();
        var body = new UnreadableContent();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            requested.Add(request.RequestUri!.AbsoluteUri);
            Assert.Equal(HttpMethod.Head, request.Method);
            Assert.Null(request.Headers.Authorization); Assert.Null(request.Headers.Referrer);
            Assert.False(request.Headers.Contains("Cookie"));
            var response = new HttpResponseMessage(status) { Content = body };
            response.Headers.Location = new Uri("http://example.com/redirected");
            return response;
        }));
        var resolved = await client.ResolveAsync(" example.com/private ", default);
        Assert.Equal(new ResolvedWebsite("https://example.com/private", false), resolved);
        Assert.Equal(new[] { "https://example.com/private" }, requested);
        Assert.False(body.BodyRead);
    }

    [Theory]
    [InlineData(HttpRequestError.ConnectionError)]
    [InlineData(HttpRequestError.NameResolutionError)]
    public async Task AddressProbeAllowsHttpOnlyAfterSchemeLessConnectionFailure(HttpRequestError error)
    {
        var requested = new List<string>();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            requested.Add(request.RequestUri!.AbsoluteUri);
            Assert.Equal(HttpMethod.Head, request.Method);
            if (requested.Count == 1) throw new HttpRequestException(error, "synthetic connection failure");
            return new(HttpStatusCode.Forbidden);
        }));
        Assert.Equal(new ResolvedWebsite("http://example.com/", true), await client.ResolveAsync("example.com", default));
        Assert.Equal(new[] { "https://example.com/", "http://example.com/" }, requested);
    }

    [Fact]
    public async Task AddressProbeDoesNotFetchExplicitUrlsOrRetryTlsAndCancellation()
    {
        var calls = 0;
        using var client = new WebsiteIconClient(new Handler(_ =>
        {
            calls++;
            throw new HttpRequestException(HttpRequestError.SecureConnectionError, "synthetic TLS rejection");
        }));
        Assert.Equal(new ResolvedWebsite("https://example.com/", false), await client.ResolveAsync(" HTTPS://example.com ", default));
        Assert.Equal(new ResolvedWebsite("http://example.com/", false), await client.ResolveAsync("http://example.com", default));
        Assert.Equal(0, calls);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.ResolveAsync("example.com", new CancellationToken(true)));
        Assert.Equal(0, calls);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.ResolveAsync("example.com", default));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task DeclaredIconUsesHtmlBaseWithoutCookiesCredentialsOrReferrer()
    {
        var requested = new List<string>();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            requested.Add(request.RequestUri!.AbsoluteUri);
            Assert.Null(request.Headers.Authorization); Assert.Null(request.Headers.Referrer);
            Assert.False(request.Headers.Contains("Cookie"));
            if (requested.Count == 1) return new(HttpStatusCode.OK) { Content = new StringContent("<html><base href='/assets/'><link rel='shortcut icon' href='logo.ico?a=1&amp;b=2'></html>") };
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([0, 0, 1, 0, 1, 0, 0, 0]) };
            response.Content.Headers.ContentType = new MediaTypeHeaderValue("image/x-icon");
            return response;
        }));
        var image = await client.FetchAsync("example.com", default);
        Assert.Equal(".ico", image.Format);
        Assert.Equal(new[] { "https://example.com/", "https://example.com/assets/logo.ico?a=1&b=2" }, requested);
    }

    [Fact]
    public async Task HttpsDowngradeAndCredentialRedirectsAreNotFollowed()
    {
        foreach (var unsafeAddress in new[] { "http://example.com/", "https://user:password@example.com/", "file:///C:/private" })
        {
            var calls = 0;
            using var client = new WebsiteIconClient(new Handler(_ =>
            {
                calls++; var response = new HttpResponseMessage(HttpStatusCode.Redirect); response.Headers.Location = new Uri(unsafeAddress); return response;
            }));
            await Assert.ThrowsAsync<ValidationException>(() => client.FetchAsync("https://example.com/", default));
            Assert.Equal(1, calls);
        }
    }

    [Fact]
    public async Task CancellationAndOversizedHtmlStopBeforeImageRequests()
    {
        var calls = 0;
        using var client = new WebsiteIconClient(new Handler(_ => { calls++; return new(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[1024 * 1024 + 1]) }; }));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.FetchAsync("example.com", new CancellationToken(true)));
        Assert.Equal(0, calls);
        await Assert.ThrowsAsync<ValidationException>(() => client.FetchAsync("example.com", default));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task RefusedPageStillTriesItsOriginFaviconWithoutDowngrading()
    {
        var requested = new List<string>();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            requested.Add(request.RequestUri!.AbsoluteUri);
            if (requested.Count == 1) return new(HttpStatusCode.Forbidden);
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([0, 0, 1, 0, 1, 0, 0, 0]) };
            response.Content.Headers.ContentType = new MediaTypeHeaderValue("image/x-icon");
            return response;
        }));
        var image = await client.FetchAsync("https://example.com/refused", default);
        Assert.Equal(".ico", image.Format);
        Assert.Equal(new[] { "https://example.com/refused", "https://example.com/favicon.ico" }, requested);
    }

    [Fact]
    public async Task CertificateFailureNeverUsesHttpForSchemeLessInput()
    {
        var requested = new List<string>();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            requested.Add(request.RequestUri!.AbsoluteUri);
            throw new HttpRequestException(HttpRequestError.SecureConnectionError, "synthetic TLS rejection");
        }));
        await Assert.ThrowsAsync<HttpRequestException>(() => client.FetchAsync("example.com", default));
        Assert.Equal(new[] { "https://example.com/" }, requested);
    }

    [Theory]
    [InlineData(" https://example.com/ ")]
    [InlineData("\tHTTPS://example.com/\r\n")]
    public async Task WhitespaceDoesNotMakeAnExplicitHttpsIconRequestEligibleForDowngrade(string website)
    {
        var requested = new List<string>();
        using var client = new WebsiteIconClient(new Handler(request =>
        {
            requested.Add(request.RequestUri!.AbsoluteUri);
            throw new HttpRequestException(HttpRequestError.ConnectionError, "synthetic connection failure");
        }));
        await Assert.ThrowsAsync<HttpRequestException>(() => client.FetchAsync(website, default));
        Assert.Equal(new[] { "https://example.com/" }, requested);
    }
}