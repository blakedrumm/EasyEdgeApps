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
        public readonly ManualResetEventSlim RequestStarted = new ManualResetEventSlim();
        public bool SawCredentials;
        public bool WaitForCancellation;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
            cancellation.ThrowIfCancellationRequested();
            Requests.Add(request.RequestUri.AbsoluteUri);
            SawCredentials |= request.Headers.Contains("Authorization") || request.Headers.Contains("Cookie") || request.Headers.Contains("Referer");
            RequestStarted.Set();
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
    Assert-WebsiteIcon $rejected 'Unsupported, oversized, or malformed website image data must be rejected.'
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
    Assert-WebsiteIcon ($candidates.Count -eq 3 -and $candidates[0] -ceq 'https://site.example/assets/brand.png?rev=1&theme=light' -and $candidates[1] -ceq 'https://cdn.example/touch.png' -and $candidates[2] -ceq 'https://site.example/favicon.ico') 'Declared icons must respect base URLs, HTML attributes and entities, while rejecting active, insecure, or credential-bearing URLs.'
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
    $oversizedDimensions = [byte[]]$pngBytes.Clone()
    [Array]::Copy([byte[]]@(0, 0, 16, 0), 0, $oversizedDimensions, 16, 4)
    Assert-WebsiteIconRejected $oversizedDimensions
    Assert-WebsiteIconRejected (New-Object byte[] (1MB + 1))
    Assert-WebsiteIconRejected ([Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg"></svg>'))
    $brokenIcon = [byte[]]$pngOnlyIcon.Clone()
    [Array]::Copy([BitConverter]::GetBytes([uint32]($pngOnlyIcon.Length + 1)), 0, $brokenIcon, 18, 4)
    Assert-WebsiteIconRejected $brokenIcon
    Test-WebsiteIconLookup $pngBytes
    Test-WebsiteIconWorker $pngBytes
    Write-Host ('PASS: ICO, PNG, PNG-only ICO, native rendering, transparency, and bounded image validation on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally { $pngStream.Dispose(); $sourceGraphics.Dispose(); $sourceBitmap.Dispose() }