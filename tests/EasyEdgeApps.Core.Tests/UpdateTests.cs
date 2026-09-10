using System.Net;
using System.Text;
using EasyEdgeApps.Core;

namespace EasyEdgeApps.Core.Tests;

public sealed class UpdateTests
{
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(respond(request)); }
    }

    [Theory]
    [InlineData("42")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{\"name\":\"EasyEdgeApps-2.0.0-x64.msi\",\"browser_download_url\":\"https://github.com/blakedrumm/EasyEdgeApps/releases/download/v2.0.0/EasyEdgeApps-2.0.0-x64.msi\"}")]
    [InlineData("{\"name\":\"EasyEdgeApps-2.0.0-x64.msi\",\"browser_download_url\":\"https://github.com/blakedrumm/EasyEdgeApps/releases/download/v2.0.0/EasyEdgeApps-2.0.0-x64.msi\",\"size\":\"10\"}")]
    [InlineData("{\"name\":\"EasyEdgeApps-2.0.0-x64.msi\",\"browser_download_url\":\"https://github.com/blakedrumm/EasyEdgeApps/releases/download/v2.0.0/EasyEdgeApps-2.0.0-x64.msi\",\"size\":null}")]
    public async Task MalformedReleaseAssetsFailAsValidation(string asset)
    {
        var json = "{\"tag_name\":\"v2.0.0\",\"html_url\":\"https://github.com/blakedrumm/EasyEdgeApps/releases/tag/v2.0.0\",\"draft\":false,\"prerelease\":false,\"assets\":[" + asset + "]}";
        var calls = 0;
        using var client = new UpdateClient(new Handler(_ =>
        {
            calls++;
            return new(HttpStatusCode.OK) { Content = new StringContent(json) };
        }));

        await Assert.ThrowsAsync<ValidationException>(() => client.CheckAsync(default));

        Assert.Equal(1, calls);
    }

    [Theory]
    [InlineData(302)]
    [InlineData(403)]
    [InlineData(500)]
    public async Task UpdateChecksRejectNonSuccessAndRedirects(int status)
    {
        using var client = new UpdateClient(new Handler(request =>
        {
            Assert.Equal(UpdateClient.LatestEndpoint, request.RequestUri!.AbsoluteUri);
            Assert.Null(request.Headers.Authorization); Assert.Null(request.Headers.Referrer);
            return new((HttpStatusCode)status) { Content = new StringContent("{}") };
        }));
        await Assert.ThrowsAsync<ValidationException>(() => client.CheckAsync(default));
    }

    [Theory]
    [InlineData("https://evil.example/release", false)]
    [InlineData("https://github.com/blakedrumm/EasyEdgeApps/releases/tag/v2.0.0", true)]
    public async Task ForeignOrPrereleaseMetadataIsRejected(string page, bool prerelease)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(new { tag_name = "v2.0.0", html_url = page, draft = false, prerelease });
        using var client = new UpdateClient(new Handler(_ => new(HttpStatusCode.OK) { Content = new StringContent(json) }));
        await Assert.ThrowsAsync<ValidationException>(() => client.CheckAsync(default));
    }

    [Fact]
    public async Task TrustedStableCheckDoesNotDownloadAutomatically()
    {
        var calls = 0;
        using var client = new UpdateClient(new Handler(_ =>
        {
            calls++;
            return new(HttpStatusCode.OK) { Content = new StringContent("{\"tag_name\":\"v2.0.0\",\"html_url\":\"https://github.com/blakedrumm/EasyEdgeApps/releases/tag/v2.0.0\",\"draft\":false,\"prerelease\":false,\"assets\":[]}") };
        }));
        Assert.Equal("v2.0.0", (await client.CheckAsync(default)).Tag);
        Assert.Equal(1, calls);
    }
}