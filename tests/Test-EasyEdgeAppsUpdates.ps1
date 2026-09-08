#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
Add-Type -AssemblyName System.Net.Http
$references = @([Net.Http.HttpClient].Assembly.Location)
if ([IO.File]::Exists((Join-Path $PSHOME 'ref\System.Net.Http.dll'))) {
    $references = @(Get-ChildItem -LiteralPath (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object { $_.FullName })
}
Add-Type -ReferencedAssemblies $references -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
namespace EasyEdgeAppsUpdateTests {
    public sealed class Handler : HttpMessageHandler {
        public string Json;
        public string Address;
        public string Redirect;
        public int RequestCount;
        public HttpStatusCode Status = HttpStatusCode.OK;
        public bool SawCredentials;
        public bool WaitForCancellation;
        public readonly ManualResetEventSlim Started = new ManualResetEventSlim();
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) {
            cancellation.ThrowIfCancellationRequested();
            RequestCount++;
            Address = request.RequestUri.AbsoluteUri;
            SawCredentials |= request.Headers.Contains("Authorization") || request.Headers.Contains("Cookie") || request.Headers.Contains("Referer");
            Started.Set();
            if (WaitForCancellation) return CancelledResponse(cancellation);
            var response = new HttpResponseMessage(Status) { Content = new StringContent(Json) };
            if (Redirect != null) response.Headers.Location = new Uri(Redirect, UriKind.RelativeOrAbsolute);
            return Task.FromResult(response);
        }
        private async Task<HttpResponseMessage> CancelledResponse(CancellationToken cancellation) {
            var completion = new TaskCompletionSource<HttpResponseMessage>();
            using (cancellation.Register(() => completion.TrySetCanceled())) {
                return await completion.Task.ConfigureAwait(false);
            }
        }
        protected override void Dispose(bool disposing) {
            if (disposing) Started.Dispose();
            base.Dispose(disposing);
        }
    }
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.UpdateTests.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{ Root = $testRoot }

function Assert-Update {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-UpdateRejected {
    param([scriptblock]$Operation)
    $rejected = $false
    try { $null = & $Operation }
    catch { $rejected = $true }
    Assert-Update $rejected 'Untrusted or unsuccessful update information must be rejected.'
}

function New-UpdateRelease {
    param([string]$Version = '1.4.0')
    return [pscustomobject]@{ tag_name = ('v' + $Version); html_url = ('https://github.com/blakedrumm/EasyEdgeApps/releases/tag/v' + $Version); draft = $false; prerelease = $false }
}

$handler = New-Object EasyEdgeAppsUpdateTests.Handler
$client = New-Object Net.Http.HttpClient($handler)
$request = $null
try {
    foreach ($versionText in @('1.2.0', '1.3.0', '1.4.0', '2.0.0')) {
        $info = ConvertTo-EeaUpdateInfo (New-UpdateRelease $versionText) -CurrentVersion ([version]'1.3.0')
        Assert-Update ($info.UpdateAvailable -eq ([version]$versionText -gt [version]'1.3.0')) 'Version comparison must detect only newer stable releases.'
    }
    foreach ($mutation in @(
        { param($release) $release.draft = $true },
        { param($release) $release.prerelease = $true },
        { param($release) $release.draft = 'false' },
        { param($release) $release.tag_name = 'v1.4.0-preview' },
        { param($release) $release.tag_name = 'v999.0.0' },
        { param($release) $release.tag_name = 'v01.4.0' },
        { param($release) $release.tag_name += "`n"; $release.html_url += "`n" },
        { param($release) $release.html_url = 'https://other.example/download' },
        { param($release) $release.html_url += '?redirect=other' }
    )) {
        $release = New-UpdateRelease
        & $mutation $release
        Assert-UpdateRejected { ConvertTo-EeaUpdateInfo $release }
    }
    $handler.Json = New-UpdateRelease | ConvertTo-Json -Compress
    $info = Get-EeaUpdate -Client $client
    Assert-Update ($info.UpdateAvailable -and $handler.Address -ceq 'https://api.github.com/repos/blakedrumm/EasyEdgeApps/releases/latest' -and -not $handler.SawCredentials) 'Update checks must use only the fixed endpoint without browser credentials.'
    $request = Start-EeaUpdateRequest -Client $client
    $results = @($request.PowerShell.EndInvoke($request.AsyncResult))
    Assert-Update (-not $request.PowerShell.HadErrors -and $results.Count -eq 1 -and $results[0].LatestVersion -ceq '1.4.0') 'The real background worker must return validated update information.'
    $request.PowerShell.Dispose()
    $request.Cancellation.Dispose()
    $request = $null
    foreach ($redirectStatus in @(301, 302, 303, 307, 308)) {
        foreach ($redirectAddress in @('https://other.example/update', '/repos/blakedrumm/Other/releases/latest')) {
            $handler.Status = [Enum]::ToObject([Net.HttpStatusCode], $redirectStatus)
            $handler.Redirect = $redirectAddress
            $requestCount = $handler.RequestCount
            Assert-UpdateRejected { Get-EeaUpdate -Client $client }
            Assert-Update ($handler.RequestCount -eq $requestCount + 1 -and $handler.Address -ceq 'https://api.github.com/repos/blakedrumm/EasyEdgeApps/releases/latest') 'Update redirects must be rejected before contacting any redirect target.'
        }
    }
    $handler.Redirect = $null
    $handler.Status = [Net.HttpStatusCode]::Forbidden
    Assert-UpdateRejected { Get-EeaUpdate -Client $client }
    $handler.Status = [Net.HttpStatusCode]::OK
    $handler.Json = ' ' * 65537
    Assert-UpdateRejected { Get-EeaUpdate -Client $client }
    $handler.WaitForCancellation = $true
    $handler.Started.Reset()
    $request = Start-EeaUpdateRequest -Client $client
    Assert-Update ($handler.Started.Wait(5000)) 'The update request must run outside the caller thread.'
    $request.Cancellation.Cancel()
    Assert-UpdateRejected { $request.PowerShell.EndInvoke($request.AsyncResult) }
    Assert-Update (Test-EeaUpdateCheckDue -Context $context) 'A missing update timestamp must be due without creating files.'
    Assert-Update (-not [IO.Directory]::Exists($testRoot)) 'Version checks and scheduling reads must not install or persist data.'
    $now = [DateTime]::UtcNow
    Set-EeaUpdateCheckTime -Context $context -UtcNow $now
    Assert-Update (-not (Test-EeaUpdateCheckDue -Context $context -UtcNow $now.AddHours(23))) 'Automatic checks must not repeat within a day.'
    Assert-Update (Test-EeaUpdateCheckDue -Context $context -UtcNow $now.AddHours(24)) 'An enabled automatic check must become due after a day.'
    Assert-Update (Test-EeaUpdateCheckDue -Context $context -UtcNow $now.AddHours(-1)) 'Future or invalid timestamps must not suppress updates indefinitely.'
    Write-Host ('PASS: Trusted stable release parsing, fixed endpoint without redirects, background checks, cancellation, response bounds, and daily scheduling on PowerShell ' + $PSVersionTable.PSVersion + '.')
}
finally {
    if ($null -ne $request) { $request.Cancellation.Cancel(); $request.PowerShell.Dispose(); $request.Cancellation.Dispose() }
    $client.Dispose()
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}