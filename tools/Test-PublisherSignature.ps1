#requires -Version 5.1

[CmdletBinding()]
param([string[]]$Path, [string]$ExpectedThumbprint)

function Test-EeaPublisherSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Path,
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string]$ExpectedThumbprint
    )

    $results = New-Object 'Collections.Generic.List[object]'
    foreach ($artifact in $Path) {
        if (-not [IO.File]::Exists($artifact)) { throw 'A release artifact is missing; no trusted publisher signature was verified.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $artifact
        if ($signature.Status.ToString() -cne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ine $ExpectedThumbprint -or $null -eq $signature.TimeStamperCertificate) {
            throw 'A release artifact lacks the expected trusted publisher signature and timestamp. Do not describe this release as publisher-authenticated.'
        }
        $results.Add([pscustomobject]@{ Name = [IO.Path]::GetFileName($artifact); Status = 'Valid'; Thumbprint = $signature.SignerCertificate.Thumbprint; Timestamped = $true })
    }
    return $results.ToArray()
}

if ($MyInvocation.InvocationName -ne '.') { Test-EeaPublisherSignature -Path $Path -ExpectedThumbprint $ExpectedThumbprint }