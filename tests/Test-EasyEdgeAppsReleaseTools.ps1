#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\tools\Get-SupportInfo.ps1')
. (Join-Path $PSScriptRoot '..\tools\Test-PublisherSignature.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.ReleaseTools.' + [Guid]::NewGuid().ToString('N'))

function Assert-ReleaseTool {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $report = Get-EeaSupportInfo
    $fields = @('Product', 'Version', 'WindowsVersion', 'OperatingSystem64Bit', 'Process64Bit', 'PowerShellVersion', 'PowerShellEdition', 'InterfaceCulture', 'EdgeVersion', 'ManagerSignature')
    Assert-ReleaseTool (($report.PSObject.Properties.Name -join ',') -ceq ($fields -join ',')) 'Support information must contain only its explicit allowlist.'
    $json = $report | ConvertTo-Json
    Assert-ReleaseTool ($json -notmatch 'https?://|[a-zA-Z]:\\|blakedrumm|Cookies|Token|Password|MachineName|UserName') 'Support output must not disclose locations, identities, browser contents, or secrets.'
    [void][IO.Directory]::CreateDirectory($testRoot)
    $unsigned = Join-Path $testRoot 'unsigned.ps1'
    [IO.File]::WriteAllText($unsigned, "Write-Output 'Synthetic unsigned fixture'")
    $rejected = $false
    try { $null = Test-EeaPublisherSignature -Path $unsigned -ExpectedThumbprint ('A' * 40) }
    catch { $rejected = $_.Exception.Message -like '*trusted publisher signature*' }
    Assert-ReleaseTool $rejected 'The production signature gate must reject an actual unsigned artifact.'
    $script:SignatureFixture = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Thumbprint = ('A' * 40) }; TimeStamperCertificate = [pscustomobject]@{ Thumbprint = ('B' * 40) } }
    function Get-AuthenticodeSignature { param([string]$LiteralPath) return $script:SignatureFixture }
    $verified = Test-EeaPublisherSignature -Path $unsigned -ExpectedThumbprint ('A' * 40)
    Assert-ReleaseTool ($verified.Status -ceq 'Valid' -and $verified.Timestamped) 'The signature gate must accept the trusted matching timestamped verification result.'
    foreach ($invalid in @('HashMismatch', 'UnknownError', 'NotTrusted', 'UnexpectedSigner', 'NoTimestamp')) {
        $script:SignatureFixture.Status = if ($invalid -in @('UnexpectedSigner', 'NoTimestamp')) { 'Valid' } else { $invalid }
        $script:SignatureFixture.SignerCertificate.Thumbprint = if ($invalid -eq 'UnexpectedSigner') { 'C' * 40 } else { 'A' * 40 }
        $script:SignatureFixture.TimeStamperCertificate = if ($invalid -eq 'NoTimestamp') { $null } else { [pscustomobject]@{ Thumbprint = ('B' * 40) } }
        $rejected = $false
        try { $null = Test-EeaPublisherSignature -Path $unsigned -ExpectedThumbprint ('A' * 40) } catch { $rejected = $true }
        Assert-ReleaseTool $rejected 'Invalid trust, hash, signer, or timestamp must never satisfy the publisher gate.'
    }
    Write-Host 'PASS: Allowlisted local support information and fail-closed publisher-signature verification.'
}
finally { if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) } }