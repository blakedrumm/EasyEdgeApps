#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')

function Assert-Json {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-JsonRejected {
    param([scriptblock]$Operation)
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Json $rejected 'Malformed or ambiguous JSON must be rejected.'
}

$value = ConvertFrom-EeaJson '{"Notes":"2026-09-07T12:30:00Z","LiteralDate":"/Date(0)/","Empty":"","Items":[null,true,false,1,2147483648,1.5,"a"],"Single":[1],"None":[],"Object":{},"space key":"value","PSTypeName":"data, not a type"}'
Assert-Json ($value.Notes -is [string] -and $value.Notes -ceq '2026-09-07T12:30:00Z' -and $value.LiteralDate -ceq '/Date(0)/') 'All JSON strings must remain exact strings in both hosts.'
Assert-Json ($value.Empty -ceq '' -and $value.Single -is [Array] -and $value.Single.Count -eq 1 -and $value.None -is [Array] -and $value.None.Count -eq 0) 'Preserve empty strings and single/empty arrays.'
Assert-Json ($null -eq $value.Items[0] -and $value.Items[1] -is [bool] -and $value.Items[2] -ceq $false -and $value.Items[3] -is [int] -and $value.Items[4] -is [long] -and $value.Items[5] -is [double]) 'Preserve scalar types without coercion.'
Assert-Json ($value.'space key' -ceq 'value' -and $null -ne $value.PSObject.Properties['PSTypeName']) 'Field names must remain data, including PowerShell-looking names.'
$punctuation = ConvertFrom-EeaJson '{"Notes":"literal ,} and ,] stay readable","Escaped":"quote: \",}"}'
Assert-Json ($punctuation.Notes -ceq 'literal ,} and ,] stay readable' -and $punctuation.Escaped -ceq 'quote: ",}') 'Syntax checks must not interpret punctuation inside JSON strings.'
$numbers = ConvertFrom-EeaJson '{"Zero":-0,"Fraction":0.5,"Negative":-12,"Exponent":1e+2,"Small":1E-2}'
Assert-Json ($numbers.Zero -eq 0 -and $numbers.Fraction -eq 0.5 -and $numbers.Negative -eq -12 -and $numbers.Exponent -eq 100 -and $numbers.Small -eq 0.01) 'Accept the standard JSON integer, fraction, and exponent forms.'
$literal = "First`r`nSecond`t" + [char]0xe9 + ' <>&' + [char]0x1f
$encoded = [pscustomobject]@{ Notes = $literal } | ConvertTo-Json -Compress
Assert-Json ((ConvertFrom-EeaJson $encoded).Notes -ceq $literal) 'The standard parser must preserve escaped Unicode and control characters for later domain validation.'
foreach ($invalid in @('{"Name":"one","Name":"two"}', '{"Name":"one","name":"two"}', '{"__type":"Untrusted:#Type","Name":"one"}', '{"Name":true,}', '{/*comment*/"Name":"one"}', '{"Name":NaN}', '{"Name":1} {"Name":2}', '{"Name":"unfinished}', '[')) {
    Assert-JsonRejected { ConvertFrom-EeaJson $invalid }
}
foreach ($invalid in @('{"Value":01}', '{"Value":-01}', '{"Value":1.}', '{"Value":1.e2}', '{"Value":.5}', '{"Value":+1}', '{"Value":0x10}', '{"Name":"one","\u004eame":"two"}', '{"Name":"one","\u006eame":"two"}', '{"PSObject":{"Properties":[]},"Name":"one"}', '{"PSBase":null,"Name":"one"}')) {
    Assert-JsonRejected { ConvertFrom-EeaJson $invalid }
}
Assert-JsonRejected { ConvertFrom-EeaJson (('[' * 40) + '0' + (']' * 40)) }
Assert-JsonRejected { ConvertFrom-EeaJson ('{"Items":[' + (('0,' * 5000) + '0') + ']}') }
Assert-JsonRejected { ConvertFrom-EeaJson ('{"Items":[' + (('"",' * 5000) + '""') + ']}') }
$largerFixture = ConvertFrom-EeaJson ('{"Items":[' + (('0,' * 5000) + '0') + ']}') -MaximumValues 10000
Assert-Json ($largerFixture.Items.Count -eq 5001) 'Edge metadata can explicitly use a larger bounded value count.'
Write-Host 'PASS: Stable JSON string/scalar/array types, duplicate fields, type metadata, malformed JSON, depth limits, and pre-allocation value-count bounds.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.JsonTests.' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Data'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }
$secret = ConvertTo-SecureString 'Synthetic JSON test passphrase!' -AsPlainText -Force
try {
    $null = Install-EeaApp -AppName 'Date notes' -Website 'https://example.com/' -Notes '2026-09-07T12:30:00Z' -Context $context -Confirm:$false
    Assert-Json ((Read-EeaManifest $context 'Date notes').Notes -ceq '2026-09-07T12:30:00Z') 'Saved helper notes must retain date-shaped text.'
    $kit = New-EeaKit -KitName 'Notes portability' -Notes '/Date(0)/' -Context $context
    $kitFile = Join-Path $testRoot 'Notes.eeakit.json'
    $null = Write-EeaKit -Kit $kit -Path $kitFile -Confirm:$false
    $restored = Read-EeaKit $kitFile
    Assert-Json ($restored.Notes -ceq '/Date(0)/' -and $restored.Apps[0].Notes -ceq '2026-09-07T12:30:00Z') 'Standard App Kits must preserve date-shaped notes.'
    $envelope = Protect-EeaKit -Kit $kit -Password $secret -PasswordConfirmation $secret
    $restored = Unprotect-EeaKit -Envelope $envelope -Password $secret
    Assert-Json ($restored.Notes -ceq '/Date(0)/' -and $restored.Apps[0].Notes -ceq '2026-09-07T12:30:00Z') 'Encrypted App Kits must preserve the same note strings.'
    Write-Host "PASS: Manifest, standard kit, and encrypted kit note preservation on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    $secret.Dispose()
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}