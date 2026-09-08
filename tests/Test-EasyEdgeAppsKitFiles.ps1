#requires -Version 5.1

[CmdletBinding()]
param([ValidateSet('All', 'WriteInterop', 'ReadInterop')][string]$Mode = 'All', [string]$InteropPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')

function Assert-KitFile {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-KitFileRejected {
    param([scriptblock]$Operation, [string]$Message = '*')
    $failure = $null
    try { & $Operation | Out-Null } catch { $failure = $_ }
    Assert-KitFile ($null -ne $failure) 'The operation should have been rejected.'
    Assert-KitFile ($failure.Exception.Message -like $Message) ('Unexpected error: ' + $failure.Exception.Message)
}

function Assert-FixtureKit {
    param($Kit)
    Assert-KitFile ($Kit.Name -ceq 'Portable websites' -and $Kit.Notes -ceq 'Private kit notes, test data only.') 'Kit name and notes must round-trip.'
    Assert-KitFile ($Kit.Apps.Count -eq 1 -and $Kit.Apps[0].Name -ceq 'Portable News' -and $Kit.Apps[0].Notes -ceq 'Private app notes, test data only.') 'The complete app payload must round-trip.'
    Assert-KitFile ($Kit.Apps[0].Url -ceq 'https://example.com/?view=large#/home' -and $Kit.Apps[0].Desktop -and -not $Kit.Apps[0].StartMenu) 'Preserve URL and placement across hosts.'
}

$kit = ConvertTo-EeaKit ([pscustomobject]@{
    Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = 'Portable websites'; Notes = 'Private kit notes, test data only.'
    Apps = @([pscustomobject]@{ Name = 'Portable News'; Url = 'https://example.com/?view=large#/home'; Desktop = $true; StartMenu = $false; Notes = 'Private app notes, test data only.'; Icon = [pscustomobject]@{ Kind = 'Generated'; Version = 1 } })
})
$password = ConvertTo-SecureString ('Interop test ' + [char]0xe9 + ' passphrase 123!') -AsPlainText -Force
$wrongPassword = ConvertTo-SecureString 'Not the right test passphrase!' -AsPlainText -Force
$testRoot = $null
try {
    if ($Mode -eq 'WriteInterop') {
        $null = Write-EeaKit -Kit $kit -Path $InteropPath -Protected -Password $password -PasswordConfirmation $password -Confirm:$false
        Write-Host "PASS: Encrypted kit written with PowerShell $($PSVersionTable.PSVersion)."
        return
    }
    if ($Mode -eq 'ReadInterop') {
        Assert-FixtureKit (Read-EeaKit -Path $InteropPath -Password $password)
        Write-Host "PASS: Cross-host encrypted kit read with PowerShell $($PSVersionTable.PSVersion)."
        return
    }
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.KitFileTests.' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($testRoot)
    $plainPath = Join-Path $testRoot 'Standard.eeakit.json'
    $protectedPath = Join-Path $testRoot 'Protected.eeakit.json'
    $null = Write-EeaKit -Kit $kit -Path $plainPath -Confirm:$false
    Assert-FixtureKit (Read-EeaKit $plainPath)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = Write-EeaKit -Kit $kit -Path $protectedPath -Protected -Password $password -PasswordConfirmation $password -Confirm:$false
    $timer.Stop()
    Assert-FixtureKit (Read-EeaKit -Path $protectedPath -Password $password)
    $envelopeText = [IO.File]::ReadAllText($protectedPath)
    foreach ($privateText in @('Portable websites', 'Portable News', 'example.com', 'Private kit notes', 'Private app notes')) {
        Assert-KitFile (-not $envelopeText.Contains($privateText)) 'The complete kit payload must be encrypted.'
    }
    Assert-KitFile (@(Get-ChildItem -LiteralPath $testRoot -Force -File).Count -eq 2) 'No plaintext temporary kit files should remain.'
    Write-Host ('PASS: Standard/encrypted file round-trips; full payload protection; encrypted export took {0:N2} seconds.' -f $timer.Elapsed.TotalSeconds)

    $envelope = Read-EeaKitDocument $protectedPath
    $second = Protect-EeaKit -Kit $kit -Password $password -PasswordConfirmation $password
    Assert-KitFile ($second.Salt -cne $envelope.Salt -and $second.Iv -cne $envelope.Iv -and $second.Ciphertext -cne $envelope.Ciphertext) 'Repeated exports require fresh salt, IV, and ciphertext.'
    Assert-KitFileRejected { Read-EeaKit -Path $protectedPath -Password $wrongPassword } 'Incorrect password or damaged kit.'
    Assert-KitFileRejected { Read-EeaKit -Path $protectedPath } '*needs a password*'
    Assert-KitFileRejected { Protect-EeaKit -Kit $kit -Password $password -PasswordConfirmation $wrongPassword } 'The passwords do not match.'
    Assert-KitFileRejected { Write-EeaKit -Kit $kit -Path (Join-Path $testRoot 'No fallback.eeakit.json') -Password $password -Confirm:$false } '*Plaintext fallback is not allowed*'
    Write-Host 'PASS: Randomized exports, wrong passwords, explicit noninteractive handling, confirmation mismatch, and no plaintext fallback.'

    foreach ($field in @('Salt', 'Iv', 'Ciphertext', 'Tag')) {
        $changed = $envelope | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bytes = [Convert]::FromBase64String($changed.$field)
        $bytes[0] = $bytes[0] -bxor 1
        $changed.$field = [Convert]::ToBase64String($bytes)
        Assert-KitFileRejected { Unprotect-EeaKit -Envelope $changed -Password $password } 'Incorrect password or damaged kit.'
    }
    $changed = $envelope | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $changed.Iterations = 600001
    Assert-KitFileRejected { Unprotect-EeaKit -Envelope $changed -Password $password } 'Incorrect password or damaged kit.'
    foreach ($mutation in @(
        { param($candidate) $candidate.SchemaVersion = 2 },
        { param($candidate) $candidate.SchemaVersion = '1' },
        { param($candidate) $candidate.Algorithm = 'A256GCM' },
        { param($candidate) $candidate.Algorithm = @('A256CBC-HS512') },
        { param($candidate) $candidate.Kdf = 'SHA1' },
        { param($candidate) $candidate.Iterations = 2147483647 },
        { param($candidate) $candidate.Iterations = 1 },
        { param($candidate) $candidate.Salt = 'A' * 100 },
        { param($candidate) $candidate.Tag = [Convert]::ToBase64String((New-Object byte[] 31)) },
        { param($candidate) $candidate.Ciphertext = [Convert]::ToBase64String((New-Object byte[] 17)) },
        { param($candidate) $candidate.PSObject.Properties.Remove('Iv') }
    )) {
        $changed = $envelope | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        & $mutation $changed
        Assert-KitFileRejected { Unprotect-EeaKit -Envelope $changed -Password $password }
    }
    Write-Host 'PASS: Authenticated envelope metadata and ciphertext; strict versions, algorithms, KDF limits, field lengths, and truncation rejection.'

    $hash = (Get-FileHash -LiteralPath $plainPath).Hash
    Assert-KitFileRejected { Write-EeaKit -Kit $kit -Path $plainPath -Confirm:$false } '*already exists*'
    $null = Write-EeaKit -Kit $kit -Path $plainPath -Replace -WhatIf
    $whatIfPath = Join-Path $testRoot 'Preview.eeakit.json'
    $null = Write-EeaKit -Kit $kit -Path $whatIfPath -Protected -WhatIf
    Assert-KitFile (-not [IO.File]::Exists($whatIfPath) -and (Get-FileHash -LiteralPath $plainPath).Hash -ceq $hash) 'WhatIf must not write or prompt for a password.'
    $script:OriginalExportWriter = ${function:Write-EeaAtomicFile}
    try {
        function Write-EeaAtomicFile { param([string]$Source, [string]$Destination) throw 'Injected export write failure.' }
        Assert-KitFileRejected { Write-EeaKit -Kit $kit -Path $plainPath -Replace -Confirm:$false } '*Injected export write failure*'
        Assert-KitFile ((Get-FileHash -LiteralPath $plainPath).Hash -ceq $hash) 'Replacement failure must preserve the original export.'
        Assert-KitFile (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp' -Force).Count -eq 0) 'Clean up only owned staging files on failure.'
    }
    finally { Set-Item -Path Function:Write-EeaAtomicFile -Value $script:OriginalExportWriter }
    $null = Write-EeaKit -Kit $kit -Path $plainPath -Replace -Confirm:$false
    Assert-FixtureKit (Read-EeaKit $plainPath)
    $invalidPath = Join-Path $testRoot 'Invalid.eeakit.json'
    [IO.File]::WriteAllText($invalidPath, '{not valid JSON')
    Assert-KitFileRejected { Read-EeaKit $invalidPath } 'The App Kit is not valid UTF-8 JSON.'
    $oversized = [IO.File]::Create($invalidPath)
    try { $oversized.SetLength(24MB + 1) } finally { $oversized.Dispose() }
    Assert-KitFileRejected { Read-EeaKit $invalidPath } '*no larger than 24 MB*'
    Write-Host 'PASS: Read-only previews, explicit replacement, write failure preservation, cleanup, malformed JSON, and file size limits.'

    $customIconPath = Join-Path $testRoot 'portable.ico'
    New-EeaIcon -Path $customIconPath -AppName 'Portable icon'
    $customBytes = [IO.File]::ReadAllBytes($customIconPath)
    $customKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
    $customKit.Apps[0].Icon = [pscustomobject]@{ Kind = 'Embedded'; Data = [Convert]::ToBase64String($customBytes); Sha256 = (Get-EeaByteHash $customBytes) }
    $customKitPath = Join-Path $testRoot 'Custom icons.eeakit.json'
    $exportOutput = @(Write-EeaKit -Kit $customKit -Path $customKitPath -Protected -Password $password -PasswordConfirmation $password -Confirm:$false -Verbose *>&1) | Out-String
    foreach ($privateText in @('example.com', 'Private kit notes', 'Private app notes', $customKit.Apps[0].Icon.Data)) {
        Assert-KitFile (-not $exportOutput.Contains($privateText) -and -not [IO.File]::ReadAllText($customKitPath).Contains($privateText)) 'Export output and encrypted files must not disclose payload data.'
    }
    [IO.File]::Delete($customIconPath)
    $restoredKit = Read-EeaKit -Path $customKitPath -Password $password
    $restoredContext = [pscustomobject]@{ Root = (Join-Path $testRoot 'Restored\Data'); Desktop = (Join-Path $testRoot 'Restored\Desktop'); Programs = (Join-Path $testRoot 'Restored\Programs') }
    Assert-KitFile (Import-EeaKit -Kit $restoredKit -Context $restoredContext -Confirm:$false).Completed 'Encrypted custom-icon kits must install without the source icon.'
    $restoredPaths = Get-EeaPaths $restoredContext 'Portable News'
    Assert-KitFile ((Read-EeaManifest $restoredContext 'Portable News').IconHash -ceq (Get-EeaByteHash $customBytes)) 'Encrypted custom icons must retain their exact bytes.'
    $snapshot = Get-EeaAppSnapshot -Paths $restoredPaths -EdgePath (Find-EeaEdge)
    Assert-KitFileRejected { Import-EeaKit -Kit (Read-EeaKit -Path $customKitPath -Password $wrongPassword) -Context $restoredContext -Confirm:$false } 'Incorrect password or damaged kit.'

    $metadata = Get-EeaEnvelopeData $envelope
    $payloadKey = Get-EeaKitKey -Password $password -Salt $metadata.Salt -Iterations $envelope.Iterations
    try {
        $invalidKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
        $invalidKit.Apps[0].Url = 'javascript:void(0)'
        $unexpectedFieldKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
        $unexpectedFieldKit.Apps[0] | Add-Member -NotePropertyName Path -NotePropertyValue 'C:\Untrusted\destination.lnk'
        $duplicateKit = ConvertFrom-EeaJson ($kit | ConvertTo-Json -Depth 8)
        $duplicateKit.Apps = @($duplicateKit.Apps[0], $duplicateKit.Apps[0])
        foreach ($invalidPayload in @('{broken JSON', ($invalidKit | ConvertTo-Json -Depth 8), ($unexpectedFieldKit | ConvertTo-Json -Depth 8), ($duplicateKit | ConvertTo-Json -Depth 8))) {
            $payloadBytes = [Text.Encoding]::UTF8.GetBytes($invalidPayload)
            try { $invalidEncrypted = Protect-EeaBytes -Key $payloadKey -InitializationVector $metadata.InitializationVector -AssociatedData $metadata.AssociatedData -Plaintext $payloadBytes }
            finally { [Array]::Clear($payloadBytes, 0, $payloadBytes.Length) }
            $invalidEnvelope = ConvertFrom-EeaJson ($envelope | ConvertTo-Json -Depth 8)
            $invalidEnvelope.Ciphertext = [Convert]::ToBase64String($invalidEncrypted.Ciphertext)
            $invalidEnvelope.Tag = [Convert]::ToBase64String($invalidEncrypted.Tag)
            Assert-KitFileRejected { Import-EeaKit -Kit (Unprotect-EeaKit -Envelope $invalidEnvelope -Password $password) -Context $restoredContext -Confirm:$false }
        }
    }
    finally { [Array]::Clear($payloadKey, 0, $payloadKey.Length) }
    Assert-KitFile ((Get-EeaAppSnapshot -Paths $restoredPaths -EdgePath (Find-EeaEdge)) -ceq $snapshot) 'Wrong passwords and invalid authenticated payloads must not change an existing installation.'
    Write-Host 'PASS: Encrypted custom-icon portability, private export output, and rejected authenticated malformed or unsafe payloads without installation changes.'

    $script:OriginalProtectedWriter = ${function:Write-EeaAtomicFile}
    $script:ObservedEncryptedStage = $false
    $protectedHash = (Get-FileHash -LiteralPath $protectedPath).Hash
    try {
        function Write-EeaAtomicFile {
            param([string]$Source, [string]$Destination)
            $stagedText = [IO.File]::ReadAllText($Source)
            Assert-KitFile ((ConvertFrom-EeaJson $stagedText).Product -ceq 'EasyEdgeApps.EncryptedKit' -and -not $stagedText.Contains('example.com')) 'Protected-export staging must contain only the encrypted representation.'
            $script:ObservedEncryptedStage = $true
            throw 'Injected protected export failure.'
        }
        Assert-KitFileRejected { Write-EeaKit -Kit $kit -Path $protectedPath -Protected -Password $password -PasswordConfirmation $password -Replace -Confirm:$false } 'Injected protected export failure.'
        Assert-KitFile ($script:ObservedEncryptedStage -and (Get-FileHash -LiteralPath $protectedPath).Hash -ceq $protectedHash) 'A failed protected replacement must preserve the original file.'
        Assert-KitFile (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp' -Force).Count -eq 0) 'Protected-export failure must clean up its encrypted staging file.'
    }
    finally { Set-Item -Path Function:Write-EeaAtomicFile -Value $script:OriginalProtectedWriter }
    Write-Host 'PASS: Protected staging contains no plaintext payload and replacement failures preserve the previous encrypted kit.'

    $otherHost = if ($PSVersionTable.PSVersion.Major -eq 5) { 'pwsh.exe' } else { 'powershell.exe' }
    if ($null -eq (Get-Command $otherHost -ErrorAction SilentlyContinue)) { throw "Cross-host interoperability requires $otherHost." }
    & $otherHost -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Mode ReadInterop -InteropPath $protectedPath
    Assert-KitFile ($LASTEXITCODE -eq 0) 'The other PowerShell host must read this host''s encrypted kit.'
    $crossPath = Join-Path $testRoot 'Cross host.eeakit.json'
    & $otherHost -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Mode WriteInterop -InteropPath $crossPath
    Assert-KitFile ($LASTEXITCODE -eq 0) 'The other PowerShell host must export an encrypted kit.'
    Assert-FixtureKit (Read-EeaKit -Path $crossPath -Password $password)
    Write-Host "PASS: Bidirectional encrypted-kit interoperability and file tests on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    $password.Dispose()
    $wrongPassword.Dispose()
    if ($testRoot -and (Test-Path -LiteralPath $testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}