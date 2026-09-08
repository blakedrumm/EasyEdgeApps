#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

if (-not ('EasyEdgeAppsWebsiteIconTests.Handler' -as [type])) {
    $references = @([Net.Http.HttpClient].Assembly.Location)
    if ([IO.File]::Exists((Join-Path $PSHOME 'ref\System.Net.Http.dll'))) {
        $references = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object { $_.FullName })
    }
    Add-Type -ReferencedAssemblies $references -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
namespace EasyEdgeAppsWebsiteIconTests {
    public sealed class Handler : HttpMessageHandler {
        public readonly Queue<HttpResponseMessage> Responses = new Queue<HttpResponseMessage>();
        public readonly List<string> Requests = new List<string>();
        public readonly List<string> Methods = new List<string>();
        public readonly ManualResetEventSlim RequestStarted = new ManualResetEventSlim();
        public Exception NextFailure;
        public bool SawCredentials;
        public bool WaitForCancellation;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
            cancellation.ThrowIfCancellationRequested();
            Requests.Add(request.RequestUri.AbsoluteUri);
            Methods.Add(request.Method.Method);
            SawCredentials |= request.Headers.Contains("Authorization") || request.Headers.Contains("Cookie") || request.Headers.Contains("Referer");
            RequestStarted.Set();
            if (NextFailure != null) { Exception failure = NextFailure; NextFailure = null; return Task.FromException<HttpResponseMessage>(failure); }
            if (WaitForCancellation) return CompleteOnCancellation(cancellation);
            if (Responses.Count == 0) throw new HttpRequestException("No fixture response was queued.");
            return Task.FromResult(Responses.Dequeue());
        }
        private async Task<HttpResponseMessage> CompleteOnCancellation(CancellationToken cancellation) {
            var completion = new TaskCompletionSource<HttpResponseMessage>();
            using (cancellation.Register(() => completion.TrySetCanceled())) {
                return await completion.Task.ConfigureAwait(false);
            }
        }
        protected override void Dispose(bool disposing) {
            if (disposing) {
                while (Responses.Count > 0) Responses.Dequeue().Dispose();
                RequestStarted.Dispose();
            }
            base.Dispose(disposing);
        }
    }
    public sealed class NonSeekableStream : MemoryStream {
        public NonSeekableStream(byte[] bytes) : base(bytes) { }
        public override bool CanSeek { get { return false; } }
    }
    public sealed class InterruptedStream : MemoryStream {
        private readonly CancellationTokenSource source;
        private readonly bool failRead;
        public int BytesRead;
        public bool IsDisposed;
        public string[] TemporaryFiles;
        public InterruptedStream(byte[] bytes, CancellationTokenSource source, bool failRead) : base(bytes) {
            this.source = source;
            this.failRead = failRead;
        }
        public override bool CanSeek { get { return false; } }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellation) {
            if (BytesRead == 0) {
                BytesRead = base.Read(buffer, offset, Math.Min(count, 32));
                return Task.FromResult(BytesRead);
            }
            TemporaryFiles = Directory.GetFiles(Path.GetTempPath(), "EasyEdgeApps.Icon.*.tmp");
            if (failRead) return Task.FromException<int>(new IOException("Synthetic interrupted response body."));
            source.Cancel();
            return Task.FromCanceled<int>(cancellation);
        }
        protected override void Dispose(bool disposing) {
            IsDisposed = true;
            base.Dispose(disposing);
        }
    }
}
'@
}

function Assert-WebsiteIcon {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-WebsiteIconRejected {
    param([byte[]]$Bytes)
    $rejected = $false
    try { $null = ConvertTo-EeaWebsiteIcon $Bytes }
    catch { $rejected = $true }
    Assert-WebsiteIcon $rejected 'Unsupported or malformed website image data must be rejected.'
}

function New-WebsiteIconResponse {
    param([byte[]]$Bytes, [string]$ContentType = 'image/png', [int]$Status = 200, [string]$Location, [switch]$Streaming)
    $response = New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]$Status)
    if ($Streaming) {
        $stream = New-Object EasyEdgeAppsWebsiteIconTests.NonSeekableStream(,$Bytes)
        $response.Content = New-Object Net.Http.StreamContent($stream)
    }
    else { $response.Content = New-Object Net.Http.ByteArrayContent(,$Bytes) }
    $response.Content.Headers.ContentType = New-Object Net.Http.Headers.MediaTypeHeaderValue($ContentType)
    if ($Location) { $response.Headers.Location = New-Object Uri($Location, [UriKind]::RelativeOrAbsolute) }
    return $response
}

function Test-WebsiteAddressResolution {
    $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
    $client = New-Object Net.Http.HttpClient($handler)
    try {
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html' 403))
        $resolved = Resolve-EeaWebsite -Website 'site.example/path?q=1#section' -Client $client
        Assert-WebsiteIcon ($resolved -ceq 'https://site.example/path?q=1#section' -and $handler.Requests.Count -eq 1 -and $handler.Methods[0] -ceq 'HEAD') 'Missing schemes must probe HTTPS without downloading a page; an HTTPS error response still proves HTTPS support.'
        $handler.Requests.Clear()
        foreach ($explicit in @('https://site.example/', 'http://site.example/')) {
            Assert-WebsiteIcon ((Resolve-EeaWebsite -Website $explicit -Client $client) -ceq $explicit -and $handler.Requests.Count -eq 0) 'Explicit schemes must be preserved without probing or automatic downgrade.'
        }
        foreach ($port in @(8080, 443, 80)) {
            $handler.Requests.Clear()
            $handler.NextFailure = [Net.Http.HttpRequestException]::new('Synthetic connection refusal.', [Net.Sockets.SocketException]::new(10061))
            $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html'))
            $schemeless = 'site.example:' + $port + '/path?q=1#section'
            $resolved = Resolve-EeaWebsite -Website $schemeless -Client $client
            Assert-WebsiteIcon ($resolved -ceq (ConvertTo-EeaWebsite ('http://' + $schemeless)) -and $handler.Requests.Count -eq 2 -and $handler.Requests[0].StartsWith('https://') -and $handler.Requests[1].StartsWith('http://')) 'A schemeless address must fall back to HTTP after HTTPS connection failure while preserving its explicit port, path, query, and fragment.'
        }
        foreach ($failureCase in @(
            [Net.Http.HttpRequestException]::new('Synthetic TLS certificate failure.', [Security.Authentication.AuthenticationException]::new('Untrusted certificate.'))
            [Net.WebException]::new('Synthetic certificate failure.', [Net.WebExceptionStatus]::TrustFailure)
            [Net.WebException]::new('Synthetic TLS failure.', [Net.WebExceptionStatus]::SecureChannelFailure)
            [InvalidOperationException]::new('Synthetic client configuration error.')
            [ObjectDisposedException]::new('Synthetic disposed client.')
            [Net.Http.HttpRequestException]::new('Synthetic unknown request failure.')
        )) {
            $handler.Requests.Clear()
            $handler.NextFailure = $failureCase
            $rejected = $false
            try { $null = Resolve-EeaWebsite -Website 'site.example' -Client $client }
            catch { $rejected = $true }
            Assert-WebsiteIcon ($rejected -and $handler.Requests.Count -eq 1) 'TLS, authentication, configuration, and unknown request failures must not silently downgrade to HTTP.'
        }
        foreach ($failureCase in @(
            [Net.WebException]::new('Synthetic name resolution failure.', [Net.WebExceptionStatus]::NameResolutionFailure)
            [Net.WebException]::new('Synthetic connection timeout.', [Net.WebExceptionStatus]::Timeout)
        )) {
            $handler.Requests.Clear()
            $handler.NextFailure = $failureCase
            $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html'))
            $resolved = Resolve-EeaWebsite -Website 'site.example' -Client $client
            Assert-WebsiteIcon ($resolved -ceq 'http://site.example/' -and $handler.Requests.Count -eq 2) 'Recognized transport failures must permit HTTP fallback in both supported hosts.'
        }
        foreach ($invalid in @('', 'javascript:alert(1)', 'file:///C:/private', '//site.example', 'user:secret@site.example', 'site.example/unsafe path')) {
            $handler.Requests.Clear()
            $rejected = $false
            try { $null = Resolve-EeaWebsite -Website $invalid -Client $client }
            catch { $rejected = $true }
            Assert-WebsiteIcon ($rejected -and $handler.Requests.Count -eq 0) 'Invalid or credential-bearing addresses must fail before any scheme probe.'
        }
        $cancellation = New-Object Threading.CancellationTokenSource
        try {
            $cancellation.Cancel()
            $rejected = $false
            try { $null = Resolve-EeaWebsite -Website 'site.example' -Client $client -CancellationToken $cancellation.Token }
            catch { $rejected = $true }
            Assert-WebsiteIcon ($rejected -and $handler.Requests.Count -eq 0) 'Cancelled resolution must not probe either scheme.'
        }
        finally { $cancellation.Dispose() }
        Assert-WebsiteIcon (-not $handler.SawCredentials) 'Scheme probes must not send browser credentials, authentication, or referrers.'
        Write-Host 'PASS: HTTPS-first address resolution, HTTP fallback, explicit-scheme preservation, certificate-failure protection, and cancellation.'
    }
    finally { $client.Dispose() }
}

function Test-WebsiteIconInterruptedDownloads {
    param([byte[]]$PngBytes)
    foreach ($failRead in @($false, $true)) {
        $initialFiles = @([IO.Directory]::GetFiles([IO.Path]::GetTempPath(), 'EasyEdgeApps.Icon.*.tmp'))
        $cancellation = New-Object Threading.CancellationTokenSource
        $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
        $client = New-Object Net.Http.HttpClient($handler)
        $body = [EasyEdgeAppsWebsiteIconTests.InterruptedStream]::new($PngBytes, $cancellation, $failRead)
        try {
            $response = New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::OK)
            $response.Content = New-Object Net.Http.StreamContent($body)
            $handler.Responses.Enqueue($response)
            $rejected = $false
            try { $null = Get-EeaWebsiteResponse -Client $client -Website 'https://site.example/partial.png' -StreamToFile -CancellationToken $cancellation.Token }
            catch { $rejected = $true }
            Assert-WebsiteIcon ($rejected -and $body.BytesRead -gt 0 -and $body.IsDisposed) 'Cancellation and read failures after the first chunk must abort and close the response body.'
            $partialFiles = @($body.TemporaryFiles | Where-Object { $_ -notin $initialFiles })
            Assert-WebsiteIcon ($partialFiles.Count -eq 1) 'The interrupted transfer must have created one temporary image file before failing.'
            foreach ($temporaryPath in $partialFiles) {
                Assert-WebsiteIcon (-not [IO.File]::Exists($temporaryPath)) 'Interrupted image transfers must delete their partially written temporary file.'
            }
        }
        finally { $client.Dispose(); $body.Dispose(); $cancellation.Dispose() }
    }
    Write-Host 'PASS: Mid-body cancellation and read failures close response streams and delete partial image downloads.'
}

function Test-WebsiteIconLargeImage {
    $source = New-Object Drawing.Bitmap(2048, 1024, [Drawing.Imaging.PixelFormat]::Format32bppRgb)
    $encoded = New-Object IO.MemoryStream
    try {
        $data = $source.LockBits((New-Object Drawing.Rectangle(0, 0, $source.Width, $source.Height)), [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format32bppRgb)
        try {
            $pixels = New-Object byte[] ([Math]::Abs($data.Stride) * $source.Height)
            $random = New-Object Random(8147)
            $random.NextBytes($pixels)
            [Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length)
        }
        finally { $source.UnlockBits($data) }
        $source.Save($encoded, [Drawing.Imaging.ImageFormat]::Png)
        $largePng = $encoded.ToArray()
        Assert-WebsiteIcon ($largePng.Length -gt 1MB) 'The large-image fixture must exceed the former download limit.'
        $iconBytes = ConvertTo-EeaWebsiteIcon $largePng
        Assert-EeaIconData $iconBytes
        $iconStream = New-Object IO.MemoryStream(,$iconBytes)
        $icon = New-Object Drawing.Icon($iconStream)
        $bitmap = $icon.ToBitmap()
        try {
            Assert-WebsiteIcon ($bitmap.Width -eq 128 -and $bitmap.Height -eq 128 -and $iconBytes.Length -lt 1MB) 'Large source images must become small Windows-compatible icons.'
            Assert-WebsiteIcon ($bitmap.GetPixel(64, 64).A -eq 255 -and $bitmap.GetPixel(0, 0).A -eq 0) 'Downsampling must preserve source aspect ratio within a transparent icon canvas.'
        }
        finally { $bitmap.Dispose(); $icon.Dispose(); $iconStream.Dispose() }
        $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
        $client = New-Object Net.Http.HttpClient($handler)
        try {
            foreach ($streaming in @($false, $true)) {
                $handler.Requests.Clear()
                $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('<link rel=icon href="/large.png">')) 'text/html'))
                $handler.Responses.Enqueue((New-WebsiteIconResponse $largePng -Streaming:$streaming))
                $found = Get-EeaWebsiteIcon -Website 'https://site.example/' -Client $client
                Assert-EeaIconData $found.Bytes
                Assert-WebsiteIcon ($found.SourceUrl -ceq 'https://site.example/large.png' -and $handler.Requests.Count -eq 2) 'Large icon downloads must be resized whether or not a content length is supplied.'
            }
        }
        finally { $client.Dispose() }
        Write-Host 'PASS: Large image downloads, downsampling beyond 1024 pixels, aspect ratio, transparency, and compact ICO output.'
    }
    finally { $encoded.Dispose(); $source.Dispose() }
}

function Test-WebsiteIconSvg {
    $svgText = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="shade" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffcc00"/><stop offset="1" stop-color="#0044ff"/>
  </linearGradient></defs>
  <rect x="8" y="8" width="48" height="48" rx="4" fill="url(#shade)"/>
  <path d="M24 32L30 38L44 22" fill="none" stroke="white" stroke-width="3"/>
</svg>
'@
    $svgBytes = [Text.Encoding]::UTF8.GetBytes($svgText)
    $iconBytes = ConvertTo-EeaWebsiteIcon $svgBytes
    Assert-EeaIconData $iconBytes
    $iconStream = New-Object IO.MemoryStream(,$iconBytes)
    $icon = New-Object Drawing.Icon($iconStream)
    $bitmap = $icon.ToBitmap()
    try {
        Assert-WebsiteIcon ($bitmap.Width -eq 128 -and $bitmap.Height -eq 128 -and $bitmap.GetPixel(0, 0).A -eq 0) 'Static SVG icons must become Windows-compatible transparent 128-pixel ICOs.'
        Assert-WebsiteIcon ($bitmap.GetPixel(32, 28).R -gt $bitmap.GetPixel(32, 100).R + 40 -and $bitmap.GetPixel(32, 100).B -gt $bitmap.GetPixel(32, 28).B + 40) 'SVG conversion must render gradients and paths, not a placeholder image.'
    }
    finally { $bitmap.Dispose(); $icon.Dispose(); $iconStream.Dispose() }
    foreach ($unsafeSvg in @(
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///C:/private.png"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><use href="https://external.example/image.svg#shape"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><style>@import "https://external.example/style.css";</style></svg>',
        '<!DOCTYPE svg [<!ENTITY secret SYSTEM "file:///C:/private.txt">]><svg xmlns="http://www.w3.org/2000/svg">&secret;</svg>'
    )) { Assert-WebsiteIconRejected ([Text.Encoding]::UTF8.GetBytes($unsafeSvg)) }
    $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
    $client = New-Object Net.Http.HttpClient($handler)
    try {
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('<link rel="icon" href="/favicon.svg" type="image/svg+xml">')) 'text/html'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse $svgBytes 'image/svg+xml'))
        $found = Get-EeaWebsiteIcon -Website 'https://site.example/' -Client $client
        Assert-WebsiteIcon ($found.SourceUrl -ceq 'https://site.example/favicon.svg' -and $handler.Requests.Count -eq 2) 'A declared static SVG favicon must be discovered and converted locally.'
        Assert-EeaIconData $found.Bytes
    }
    finally { $client.Dispose() }
    Write-Host 'PASS: Static SVG discovery, native icon conversion, gradients, transparency, and rejection of scripts and external resources.'
}

function Test-WebsiteIconLookup {
    param([byte[]]$PngBytes)
    $html = @'
<!-- <link rel="icon" href="https://ignored.example/comment.png"> -->
<script>var example = '<link rel="icon" href="https://ignored.example/script.png">';</script>
<base href="/assets/">
<LINK HREF='brand.png?rev=1&amp;theme=light' REL='shortcut ICON'>
<link rel=apple-touch-icon href=//cdn.example/touch.png>
<link rel=icon type=image/svg+xml href="vector">
<link rel=icon href="http://insecure.example/icon.ico">
<link rel=icon href="file:///C:/private.ico">
<link rel=icon href="https://user:secret@credentials.example/icon.ico">
'@
    $candidates = @(Get-EeaWebsiteIconCandidates -PageUri 'https://site.example/account/view' -Html $html)
    Assert-WebsiteIcon ($candidates.Count -eq 4 -and $candidates[0] -ceq 'https://site.example/assets/brand.png?rev=1&theme=light' -and $candidates[1] -ceq 'https://cdn.example/touch.png' -and $candidates[2] -ceq 'https://site.example/assets/vector' -and $candidates[3] -ceq 'https://site.example/favicon.ico') 'Declared raster and SVG icons must respect base URLs, HTML attributes and entities, while rejecting active, insecure, or credential-bearing URLs.'
    $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
    $client = New-Object Net.Http.HttpClient($handler)
    try {
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('Not an icon'))))
        $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
        $found = Get-EeaWebsiteIcon -Website 'https://site.example/account/view' -Client $client
        Assert-EeaIconData $found.Bytes
        Assert-WebsiteIcon ($found.SourceUrl -ceq 'https://cdn.example/touch.png' -and $handler.Requests.Count -eq 3 -and -not $handler.SawCredentials) 'Lookup must try declared images safely without sending cookies, authentication, or a referrer.'
        $handler.Requests.Clear()
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html' 302 'https://final.example/welcome/'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('<link rel=icon href=site.png>')) 'text/html'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
        $redirected = Get-EeaWebsiteIcon -Website 'https://site.example/' -Client $client
        Assert-WebsiteIcon ($redirected.SourceUrl -ceq 'https://final.example/welcome/site.png' -and $handler.Requests.Count -eq 3) 'Relative icons must resolve against the final HTTPS page after redirects.'
        $handler.Requests.Clear()
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html' 403))
        $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
        $fallback = Get-EeaWebsiteIcon -Website 'https://site.example/private/page' -Client $client
        Assert-WebsiteIcon ($fallback.SourceUrl -ceq 'https://site.example/favicon.ico') 'An unavailable page must still allow the conventional favicon fallback.'
        $largePage = [Text.Encoding]::UTF8.GetBytes('<link rel=icon href="/large-page.png">' + (' ' * (512KB + 1024)))
        foreach ($streaming in @($false, $true)) {
            $handler.Requests.Clear()
            $handler.Responses.Enqueue((New-WebsiteIconResponse $largePage 'text/html' -Streaming:$streaming))
            $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
            $largePageIcon = Get-EeaWebsiteIcon -Website 'https://site.example/large' -Client $client
            Assert-WebsiteIcon ($largePageIcon.SourceUrl -ceq 'https://site.example/large-page.png' -and $handler.Requests.Count -eq 2) 'Large HTML pages must allow icon discovery from a bounded prefix without falling back to the wrong path.'
        }
        foreach ($target in @('http://insecure.example/icon.ico', 'file:///C:/private.ico', 'https://user:secret@credentials.example/icon.ico')) {
            $handler.Requests.Clear()
            $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html' 302 $target))
            $rejected = $false
            try { $null = Get-EeaWebsiteResponse -Client $client -Website 'https://site.example/' -MaximumBytes 1024 }
            catch { $rejected = $true }
            Assert-WebsiteIcon ($rejected -and $handler.Requests.Count -eq 1) 'An unsafe redirect must be rejected before contacting its destination.'
        }
        foreach ($streaming in @($false, $true)) {
            $handler.Responses.Enqueue((New-WebsiteIconResponse (New-Object byte[] 2048) -Streaming:$streaming))
            $rejected = $false
            try { $null = Get-EeaWebsiteResponse -Client $client -Website 'https://site.example/' -MaximumBytes 1024 }
            catch { $rejected = $true }
            Assert-WebsiteIcon $rejected 'Both declared and streamed response bodies must respect the byte limit.'
        }
        $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
        $download = Get-EeaWebsiteResponse -Client $client -Website 'https://site.example/icon.png' -StreamToFile
        $temporaryPath = $download.Stream.Name
        try {
            Assert-WebsiteIcon ($download.Stream -is [IO.FileStream] -and $download.Stream.CanSeek -and $download.Stream.Position -eq 0 -and $download.Stream.Length -eq $PngBytes.Length) 'Icon responses must be disk-backed and rewound for decoding.'
        }
        finally { $download.Stream.Dispose() }
        Assert-WebsiteIcon (-not [IO.File]::Exists($temporaryPath)) 'Disposing a downloaded icon must delete its temporary file.'
        $cancellation = New-Object Threading.CancellationTokenSource
        try {
            $handler.Requests.Clear()
            $cancellation.Cancel()
            $rejected = $false
            try { $null = Get-EeaWebsiteIcon -Website 'https://site.example/' -Client $client -CancellationToken $cancellation.Token }
            catch { $rejected = $true }
            Assert-WebsiteIcon ($rejected -and $handler.Requests.Count -eq 0) 'A cancelled lookup must not send requests.'
        }
        finally { $cancellation.Dispose() }
        Write-Host 'PASS: Declared icons, HTML entities and base URLs, redirects, fallback, credential-free requests, byte limits, and cancellation without live network access.'
    }
    finally { $client.Dispose() }
}

function Test-WebsiteIconFailureResults {
    foreach ($failureCode in @('Blocked', 'NotFound', 'Unsupported', 'Transport', 'Timeout', 'Mixed')) {
        foreach ($useWorker in @($false, $true)) {
            $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
            $client = New-Object Net.Http.HttpClient($handler)
            $request = $null
            try {
                if ($failureCode -eq 'Transport') { $handler.NextFailure = New-Object Net.Http.HttpRequestException('private-network-detail') }
                elseif ($failureCode -eq 'Timeout') { $handler.NextFailure = New-Object Threading.Tasks.TaskCanceledException('private-timeout-detail') }
                else {
                    $pageStatus = if ($failureCode -eq 'Blocked') { 403 } else { 200 }
                    $html = if ($failureCode -eq 'Mixed') { '<link rel=icon href="/invalid.png"><link rel=icon href="/blocked.ico">' } else { 'private-response-body' }
                    $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html' $pageStatus))
                }
                if ($failureCode -eq 'Mixed') {
                    $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('not an image'))))
                    $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html' 403))
                }
                $iconStatus = if ($failureCode -eq 'Blocked') { 403 } elseif ($failureCode -eq 'Unsupported') { 200 } else { 404 }
                $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('private-response-body')) 'text/html' $iconStatus))
                $expected = if ($failureCode -eq 'Mixed') { 'Blocked' } else { $failureCode }
                if ($useWorker) {
                    $request = Start-EeaWebsiteIconRequest -Website 'https://site.example/private' -Client $client
                    $result = @($request.PowerShell.EndInvoke($request.AsyncResult))
                    Assert-WebsiteIcon ($result.Count -eq 1 -and $request.PowerShell.Streams.Error.Count -eq 0 -and $request.PowerShell.InvocationStateInfo.State -eq 'Completed' -and $result[0].FailureCode -ceq $expected -and $null -eq $result[0].Bytes) 'The worker must return a stable failure category without leaking exceptions or replacing icon bytes.'
                }
                else {
                    $failure = $null
                    try { $null = Get-EeaWebsiteIcon -Website 'https://site.example/private' -Client $client }
                    catch { $failure = $_.Exception }
                    Assert-WebsiteIcon ($null -ne $failure -and (Get-EeaWebsiteIconFailureCode $failure) -ceq $expected) 'Direct lookup must preserve its throwing API and expose the same failure category as the worker.'
                }
                $message = Get-EeaWebsiteIconFailureMessage $expected
                Assert-WebsiteIcon (-not $message.Contains('private') -and -not $handler.SawCredentials -and $handler.Requests.Count -eq $(if ($failureCode -eq 'Mixed') { 4 } else { 2 })) 'Classified failures must remain credential-free, avoid guessed URLs, and suppress private response details.'
            }
            finally {
                if ($null -ne $request) { $request.PowerShell.Dispose(); $request.Cancellation.Dispose() }
                $client.Dispose()
            }
        }
    }
    Write-Host 'PASS: Direct and worker blocked, missing, unsupported, transport, timeout, and mixed-failure classification without private details or extra probes.'
}

function Test-WebsiteIconWorker {
    param([byte[]]$PngBytes)
    $handler = New-Object EasyEdgeAppsWebsiteIconTests.Handler
    $client = New-Object Net.Http.HttpClient($handler)
    $request = $null
    try {
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('<link rel=icon href="/brand.png">')) 'text/html'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
        $request = Start-EeaWebsiteIconRequest -Website 'https://site.example/' -Client $client
        $result = @($request.PowerShell.EndInvoke($request.AsyncResult))
        Assert-WebsiteIcon (-not $request.PowerShell.HadErrors -and $result.Count -eq 1 -and $result[0].SourceUrl -ceq 'https://site.example/brand.png') 'The real background runspace must load the current helpers and return the discovered icon.'
        Assert-EeaIconData $result[0].Bytes
        $request.PowerShell.Dispose()
        $request.Cancellation.Dispose()
        $request = $null
        $handler.Requests.Clear()
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html'))
        $request = Start-EeaWebsiteIconRequest -Website 'site.example/path' -ResolveOnly -Client $client
        $result = @($request.PowerShell.EndInvoke($request.AsyncResult))
        Assert-WebsiteIcon ($request.ResolveOnly -and $result.Count -eq 1 -and $result[0].Website -ceq 'https://site.example/path' -and $null -eq $result[0].Bytes -and $handler.Requests.Count -eq 1) 'A resolution-only worker must resolve a missing scheme without downloading any icon.'
        $request.PowerShell.Dispose()
        $request.Cancellation.Dispose()
        $request = $null
        $handler.Requests.Clear()
        $handler.NextFailure = [Net.Http.HttpRequestException]::new('Synthetic connection refusal.', [Net.Sockets.SocketException]::new(10061))
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([byte[]]@()) 'text/html'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse ([Text.Encoding]::UTF8.GetBytes('<link rel=icon href="/brand.png">')) 'text/html'))
        $handler.Responses.Enqueue((New-WebsiteIconResponse $PngBytes))
        $request = Start-EeaWebsiteIconRequest -Website 'site.example/path' -Client $client
        $result = @($request.PowerShell.EndInvoke($request.AsyncResult))
        Assert-WebsiteIcon ($result.Count -eq 1 -and $result[0].Website -ceq 'http://site.example/path' -and $result[0].SourceUrl -ceq 'http://site.example/brand.png' -and $handler.Requests.Count -eq 4) 'The real icon worker must carry an HTTP fallback through discovery and conversion without credentials.'
        $request.PowerShell.Dispose()
        $request.Cancellation.Dispose()
        $request = $null
        $handler.RequestStarted.Reset()
        $handler.Requests.Clear()
        $handler.WaitForCancellation = $true
        $request = Start-EeaWebsiteIconRequest -Website 'https://site.example/' -Client $client
        Assert-WebsiteIcon ($handler.RequestStarted.Wait(5000) -and -not $request.AsyncResult.IsCompleted) 'A pending network request must execute outside the caller thread.'
        $request.Cancellation.Cancel()
        $cancelled = $false
        try { $null = $request.PowerShell.EndInvoke($request.AsyncResult) }
        catch { $cancelled = $true }
        Assert-WebsiteIcon ($cancelled -and $handler.Requests.Count -eq 1) 'Cancelling an active background lookup must abort the request without starting fallback downloads.'
        Write-Host 'PASS: Real background runspace, current-source helper loading, icon results, and cancellation of an active request.'
    }
    finally {
        if ($null -ne $request) {
            $request.Cancellation.Cancel()
            $request.PowerShell.Dispose()
            $request.Cancellation.Dispose()
        }
        $client.Dispose()
    }
}

$sourceBitmap = New-Object Drawing.Bitmap(256, 256)
$sourceGraphics = [Drawing.Graphics]::FromImage($sourceBitmap)
$pngStream = New-Object IO.MemoryStream
try {
    $sourceGraphics.Clear([Drawing.Color]::Transparent)
    $sourceGraphics.FillRectangle([Drawing.Brushes]::Teal, 32, 32, 192, 192)
    $sourceBitmap.Save($pngStream, [Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $pngStream.ToArray()
    $pngIcon = ConvertTo-EeaWebsiteIcon $pngBytes
    Assert-WebsiteIcon ($pngIcon -is [byte[]] -and $pngIcon.Length -lt 1MB) 'PNG conversion must return bounded ICO bytes.'
    Assert-EeaIconData $pngIcon
    $convertedAgain = ConvertTo-EeaWebsiteIcon $pngIcon
    Assert-EeaIconData $convertedAgain
    foreach ($format in @([Drawing.Imaging.ImageFormat]::Jpeg, [Drawing.Imaging.ImageFormat]::Gif, [Drawing.Imaging.ImageFormat]::Bmp)) {
        $rasterStream = New-Object IO.MemoryStream
        try {
            $sourceBitmap.Save($rasterStream, $format)
            Assert-EeaIconData (ConvertTo-EeaWebsiteIcon $rasterStream.ToArray())
        }
        finally { $rasterStream.Dispose() }
    }
    $iconStream = New-Object IO.MemoryStream(,$pngIcon)
    $icon = New-Object Drawing.Icon($iconStream)
    $rendered = $icon.ToBitmap()
    try {
        Assert-WebsiteIcon ($rendered.Width -eq 128 -and $rendered.Height -eq 128) 'Retrieved icons must use a Windows-compatible 128-pixel bitmap frame.'
        Assert-WebsiteIcon ($rendered.GetPixel(64, 64).G -gt 90 -and $rendered.GetPixel(0, 0).A -eq 0) 'Icon conversion must preserve visible colors and transparent borders.'
    }
    finally { $rendered.Dispose(); $icon.Dispose(); $iconStream.Dispose() }
    $pngOnlyIcon = New-Object byte[] (22 + $pngBytes.Length)
    $pngOnlyIcon[2] = 1
    $pngOnlyIcon[4] = 1
    $pngOnlyIcon[10] = 1
    $pngOnlyIcon[12] = 32
    [Array]::Copy([BitConverter]::GetBytes([uint32]$pngBytes.Length), 0, $pngOnlyIcon, 14, 4)
    [Array]::Copy([BitConverter]::GetBytes([uint32]22), 0, $pngOnlyIcon, 18, 4)
    [Array]::Copy($pngBytes, 0, $pngOnlyIcon, 22, $pngBytes.Length)
    Assert-EeaIconData (ConvertTo-EeaWebsiteIcon $pngOnlyIcon)
    $invalidDimensions = [byte[]]$pngBytes.Clone()
    [Array]::Copy([byte[]]@(0, 0, 0, 0), 0, $invalidDimensions, 16, 4)
    Assert-WebsiteIconRejected $invalidDimensions
    Assert-WebsiteIconRejected (New-Object byte[] (1MB + 1))
    Assert-WebsiteIconRejected ([Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>'))
    $brokenIcon = [byte[]]$pngOnlyIcon.Clone()
    [Array]::Copy([BitConverter]::GetBytes([uint32]($pngOnlyIcon.Length + 1)), 0, $brokenIcon, 18, 4)
    Assert-WebsiteIconRejected $brokenIcon
    Test-WebsiteAddressResolution
    Test-WebsiteIconInterruptedDownloads $pngBytes
    Test-WebsiteIconLargeImage
    Test-WebsiteIconSvg
    Test-WebsiteIconLookup $pngBytes
    Test-WebsiteIconFailureResults
    Test-WebsiteIconWorker $pngBytes
    Write-Host ('PASS: ICO, PNG, PNG-only ICO, native rendering, transparency, and bounded image validation on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally { $pngStream.Dispose(); $sourceGraphics.Dispose(); $sourceBitmap.Dispose() }