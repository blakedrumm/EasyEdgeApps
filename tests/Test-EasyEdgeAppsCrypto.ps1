#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')

function ConvertFrom-TestHex {
    param([string]$Hex)
    $compact = $Hex -replace '\s', ''
    $bytes = New-Object byte[] ($compact.Length / 2)
    for ($byteIndex = 0; $byteIndex -lt $bytes.Length; $byteIndex++) { $bytes[$byteIndex] = [Convert]::ToByte($compact.Substring($byteIndex * 2, 2), 16) }
    return ,$bytes
}

function Assert-Crypto {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-CryptoRejected {
    param([scriptblock]$Operation, [string]$Message = '*')
    $failure = $null
    try { & $Operation | Out-Null } catch { $failure = $_ }
    Assert-Crypto ($null -ne $failure) 'The cryptographic input should have been rejected.'
    Assert-Crypto ($failure.Exception.Message -like $Message) ('Unexpected error: ' + $failure.Exception.Message)
}

$key = [byte[]](0..63)
$iv = ConvertFrom-TestHex '1af38c2dc2b96ffdd86694092341bc04'
$associated = [Text.Encoding]::ASCII.GetBytes('The second principle of Auguste Kerckhoffs')
$plaintext = [Text.Encoding]::ASCII.GetBytes('A cipher system must not be required to be secret, and it must be able to fall into the hands of the enemy without inconvenience')
$expectedCiphertext = ConvertFrom-TestHex @'
4affaaadb78c31c5da4b1b590d10ffbd3dd8d5d302423526912da037ecbcc7bd
822c301dd67c373bccb584ad3e9279c2e6d12a1374b77f077553df829410446b
36ebd97066296ae6427ea75c2e0846a11a09ccf5370dc80bfecbad28c73f09b3
a3b75e662a2594410ae496b2e2e6609e31e6e02cc837f053d21f37ff4f51950b
be2638d09dd7a4930930806d0703b1f6
'@
$expectedTag = ConvertFrom-TestHex '4dd3b4c088a7f45c216839645b2012bf2e6269a8c56a816dbc1b267761955bc5'
$encryptedVector = Protect-EeaBytes -Key $key -InitializationVector $iv -AssociatedData $associated -Plaintext $plaintext
Assert-Crypto ([Convert]::ToBase64String($encryptedVector.Ciphertext) -ceq [Convert]::ToBase64String($expectedCiphertext)) 'Ciphertext must match RFC 7518 Appendix B.3.'
Assert-Crypto ([Convert]::ToBase64String($encryptedVector.Tag) -ceq [Convert]::ToBase64String($expectedTag)) 'The truncated HMAC and AAD length must match RFC 7518 Appendix B.3.'
$recovered = Unprotect-EeaBytes -Key $key -InitializationVector $iv -AssociatedData $associated -Ciphertext $expectedCiphertext -Tag $expectedTag
Assert-Crypto ([Convert]::ToBase64String($recovered) -ceq [Convert]::ToBase64String($plaintext)) 'Decrypt the published vector.'
Write-Host 'PASS: RFC 7518 Appendix B.3 ciphertext, authentication tag, and decryption known-answer tests.'

for ($byteIndex = 0; $byteIndex -lt 32; $byteIndex++) {
    $changed = [byte[]]$expectedTag.Clone()
    $changed[$byteIndex] = $changed[$byteIndex] -bxor 1
    Assert-CryptoRejected { Unprotect-EeaBytes -Key $key -InitializationVector $iv -AssociatedData $associated -Ciphertext $expectedCiphertext -Tag $changed } 'Incorrect password or damaged kit.'
}
foreach ($field in @('InitializationVector', 'AssociatedData', 'Ciphertext')) {
    $parameters = @{ Key = $key; InitializationVector = $iv.Clone(); AssociatedData = $associated.Clone(); Ciphertext = $expectedCiphertext.Clone(); Tag = $expectedTag }
    $parameters[$field][0] = $parameters[$field][0] -bxor 1
    Assert-CryptoRejected { Unprotect-EeaBytes @parameters } 'Incorrect password or damaged kit.'
}
$method = [EasyEdgeApps.CryptoSupportV1].GetMethod('TagsEqual')
$flags = $method.GetMethodImplementationFlags()
Assert-Crypto (($flags -band [Reflection.MethodImplAttributes]::NoInlining) -ne 0 -and ($flags -band [Reflection.MethodImplAttributes]::NoOptimization) -ne 0) 'Authentication comparison must retain its no-inline and no-optimization guards.'
Assert-Crypto (-not [EasyEdgeApps.CryptoSupportV1]::TagsEqual($expectedTag, (New-Object byte[] 31))) 'Public authentication-tag length is fixed at 32.'
Write-Host 'PASS: All authentication-tag bytes, IV, ciphertext, and associated data are authenticated.'

$password = ConvertTo-SecureString 'A test-only passphrase 123!' -AsPlainText -Force
$different = ConvertTo-SecureString 'A different test phrase 123!' -AsPlainText -Force
try {
    Assert-EeaExportPassword -Password $password -Confirmation $password
    Assert-CryptoRejected { Assert-EeaExportPassword -Password $password -Confirmation $different } 'The passwords do not match.'
    Assert-CryptoRejected { Assert-EeaExportPassword -Password $password } '*Confirm the export password*'
    Assert-CryptoRejected { Get-EeaKitKey -Password $password -Salt (New-Object byte[] 16) -Iterations 1 }
    Assert-CryptoRejected { Get-EeaKitKey -Password $password -Salt (New-Object byte[] 16) -Iterations 2147483647 }
    Assert-CryptoRejected { ConvertFrom-EeaPassword }
    $unicodePassword = New-Object Security.SecureString
    try {
        foreach ($character in ('Testing ' + [char]0xe9 + [char]0xd83d + [char]0xde00).ToCharArray()) { $unicodePassword.AppendChar($character) }
        $passwordBytes = ConvertFrom-EeaPassword $unicodePassword
        Assert-Crypto ([Text.Encoding]::UTF8.GetString($passwordBytes) -ceq ('Testing ' + [char]0xe9 + [char]0xd83d + [char]0xde00)) 'Passwords must use full UTF-8, without trimming or normalization.'
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
    }
    finally { $unicodePassword.Dispose() }
}
finally { $password.Dispose(); $different.Dispose() }
Write-Host "PASS: Password conversion, confirmation, bounded KDF parameters, and cryptographic primitives on PowerShell $($PSVersionTable.PSVersion)."