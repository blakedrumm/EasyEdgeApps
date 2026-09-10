#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$FixtureRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixturePath = [IO.Path]::GetFullPath($FixtureRoot)
if (-not $fixturePath.StartsWith((Join-Path $repository 'artifacts\dotnet-test-'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Use an owned synthetic fixture root.' }
$stageClock = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $repository 'EasyEdgeApps.ps1')
Write-Host ('CHECK: Legacy script loaded in {0} ms.' -f $stageClock.ElapsedMilliseconds)
$encoding = New-Object Text.UTF8Encoding($false, $true)
$testPassword = ConvertTo-SecureString ('Synthetic interop ' + [char]0xe9 + ' ' + [char]0xd83d + [char]0xde00 + ' 123!') -AsPlainText -Force
try {
    $inputEnvelope = ConvertFrom-EeaJson ([IO.File]::ReadAllText((Join-Path $fixturePath 'input.encrypted.json'), $encoding))
    $stageClock.Restart()
    $openedKit = Unprotect-EeaKit -Envelope $inputEnvelope -Password $testPassword
    Write-Host ('CHECK: Legacy decrypt completed in {0} ms.' -f $stageClock.ElapsedMilliseconds)
    [IO.File]::WriteAllText((Join-Path $fixturePath 'opened.json'), ($openedKit | ConvertTo-Json -Depth 12 -Compress), $encoding)
    $plainKit = ConvertFrom-EeaJson ([IO.File]::ReadAllText((Join-Path $fixturePath 'input.json'), $encoding))
    $stageClock.Restart()
    $outputEnvelope = Protect-EeaKit -Kit $plainKit -Password $testPassword -PasswordConfirmation $testPassword
    Write-Host ('CHECK: Legacy encrypt completed in {0} ms.' -f $stageClock.ElapsedMilliseconds)
    [IO.File]::WriteAllText((Join-Path $fixturePath 'output.encrypted.json'), ($outputEnvelope | ConvertTo-Json -Depth 12 -Compress), $encoding)
    Write-Host ('PASS: Bidirectional synthetic App Kit interoperability on PowerShell ' + $PSVersionTable.PSVersion)
}
finally { $testPassword.Dispose() }