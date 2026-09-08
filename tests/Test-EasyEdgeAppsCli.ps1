#requires -Version 5.1

[CmdletBinding()]
param([string]$CommandCase = 'All', [string]$TestDirectory, [string]$FixturePath, [string]$FavoritesRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$applicationPath = Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1'
. $applicationPath

function Assert-Cli {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-CliContext {
    param([string]$Directory)
    return [pscustomobject]@{ Root = (Join-Path $Directory 'Data'); Desktop = (Join-Path $Directory 'Desktop'); Programs = (Join-Path $Directory 'Programs') }
}

if ($CommandCase -ne 'All') {
    Assert-Cli (-not [string]::IsNullOrWhiteSpace($TestDirectory)) 'A test-only context is required.'
    $script:CliContext = New-CliContext $TestDirectory
    function Get-EeaContext { return $script:CliContext }
    $parseTokens = $null
    $parseErrors = $null
    $syntaxTree = [Management.Automation.Language.Parser]::ParseFile($applicationPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-Cli ($parseErrors.Count -eq 0 -and $syntaxTree.EndBlock.Statements[-1] -is [Management.Automation.Language.IfStatementAst]) 'The public command dispatcher must be identifiable without modifying source.'
    $parameterAttributes = @($syntaxTree.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
    $dispatcher = [scriptblock]::Create($parameterAttributes + "`n" + $syntaxTree.ParamBlock.Extent.Text + "`n" + $syntaxTree.EndBlock.Statements[-1].Extent.Text)
    $secret = ConvertTo-SecureString 'Synthetic CLI test passphrase!' -AsPlainText -Force
    $incorrect = ConvertTo-SecureString 'Different synthetic passphrase!' -AsPlainText -Force
    try {
        $commandOptions = switch ($CommandCase) {
            Install { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; Notes = 'Synthetic CLI notes.'; Confirm = $false; Quiet = $true } }
            ImplicitInstall { @{ Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; Confirm = $false; Quiet = $true } }
            InstallWhatIf { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/'; WhatIf = $true } }
            List { @{ Action = 'List' } }
            ExportPlain { @{ Action = 'ExportKit'; Path = $FixturePath; KitName = 'CLI websites'; AppNames = @('CLI website'); Confirm = $false } }
            ExportProtected { @{ Action = 'ExportKit'; Path = $FixturePath; Protected = $true; Password = $secret; PasswordConfirmation = $secret; Confirm = $false } }
            ExportMissing { @{ Action = 'ExportKit'; Path = $FixturePath; Protected = $true; Confirm = $false } }
            Fallback { @{ Action = 'ExportKit'; Path = $FixturePath; Password = $secret; Confirm = $false } }
            ImportPreview { @{ Action = 'ImportKit'; Path = $FixturePath; Preview = $true } }
            ImportWhatIf { @{ Action = 'ImportKit'; Path = $FixturePath; WhatIf = $true } }
            ImportApply { @{ Action = 'ImportKit'; Path = $FixturePath; Confirm = $false } }
            ImportProtected { @{ Action = 'ImportKit'; Path = $FixturePath; Password = $secret; Confirm = $false } }
            UnlockMissing { @{ Action = 'ImportKit'; Path = $FixturePath; Confirm = $false } }
            UnlockWrong { @{ Action = 'ImportKit'; Path = $FixturePath; Password = $incorrect; Confirm = $false } }
            NoPrompt { @{ Action = 'ImportKit'; Path = $FixturePath } }
            BadOption { @{ Action = 'ImportKit'; Path = $FixturePath; Protected = $true; Confirm = $false } }
            Check { @{ Action = 'Check'; Name = 'CLI website' } }
            RepairPreview { @{ Action = 'Repair'; AppNames = @('CLI website'); Preview = $true } }
            RepairWhatIf { @{ Action = 'Repair'; Name = 'CLI website'; WhatIf = $true } }
            Repair { @{ Action = 'Repair'; Name = 'CLI website'; Confirm = $false } }
            FavoritesList { @{ Action = 'ListFavorites'; EdgeUserDataPath = $FavoritesRoot; EdgeProfile = 'Default' } }
            FavoritesPreview { @{ Action = 'ImportFavorites'; EdgeUserDataPath = $FavoritesRoot; EdgeProfile = 'Default'; AppNames = @('Favorite one'); Preview = $true } }
            FavoritesApply { @{ Action = 'ImportFavorites'; EdgeUserDataPath = $FavoritesRoot; EdgeProfile = 'Default'; Confirm = $false } }
            RemoveWhatIf { @{ Action = 'Remove'; Name = 'CLI website'; WhatIf = $true } }
            Remove { @{ Action = 'Remove'; Name = 'CLI website'; Confirm = $false; Quiet = $true } }
            default { throw 'Unknown CLI test case.' }
        }
        & $dispatcher @commandOptions | ConvertTo-Json -Depth 8 -Compress
    }
    finally { $secret.Dispose(); $incorrect.Dispose() }
    exit 0
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.CliTests.' + [Guid]::NewGuid().ToString('N'))
$hostExecutable = (Get-Process -Id $PID).Path

function Invoke-CliCase {
    param([string]$CaseName, [string]$Directory, [string]$KitFile, [string]$EdgeRoot, [int]$ExpectedExit = 0)
    $options = @('-NoLogo', '-NoProfile', '-STA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-CommandCase', $CaseName, '-TestDirectory', $Directory)
    if ($KitFile) { $options += @('-FixturePath', $KitFile) }
    if ($EdgeRoot) { $options += @('-FavoritesRoot', $EdgeRoot) }
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $commandOutput = @(& $hostExecutable @options 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    Assert-Cli ($exitCode -eq $ExpectedExit) ("$CaseName returned $exitCode instead of $ExpectedExit. " + ($commandOutput -join "`n"))
    $outputText = $commandOutput -join "`n"
    Assert-Cli (-not $outputText.Contains('Synthetic CLI test passphrase!') -and -not $outputText.Contains('Different synthetic passphrase!')) 'Passwords must not appear in CLI output.'
    return $outputText
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $sourceDirectory = Join-Path $testRoot 'Source'
    $destinationDirectory = Join-Path $testRoot 'Destination'
    $source = New-CliContext $sourceDirectory
    $destination = New-CliContext $destinationDirectory
    $standardFile = Join-Path $testRoot 'Standard.eeakit.json'
    $encryptedFile = Join-Path $testRoot 'Encrypted.eeakit.json'
    $null = Invoke-CliCase InstallWhatIf $sourceDirectory
    Assert-Cli (-not [IO.Directory]::Exists($sourceDirectory)) 'CLI WhatIf must not create folders.'
    $null = Invoke-CliCase Install $sourceDirectory
    Assert-Cli ((Read-EeaManifest $source 'CLI website').Notes -ceq 'Synthetic CLI notes.') 'The old install command must save optional notes.'
    Assert-Cli ((Invoke-CliCase List $sourceDirectory).Contains('CLI website')) 'List must retain its public output.'
    $null = Invoke-CliCase ExportPlain $sourceDirectory $standardFile
    $null = Invoke-CliCase ExportProtected $sourceDirectory $encryptedFile
    Assert-Cli ((Read-EeaKitDocument $encryptedFile).Product -eq 'EasyEdgeApps.EncryptedKit') 'Protected export must not silently fall back to readable JSON.'
    $missingFile = Join-Path $testRoot 'Missing password.eeakit.json'
    $null = Invoke-CliCase ExportMissing $sourceDirectory $missingFile -ExpectedExit 1
    $null = Invoke-CliCase Fallback $sourceDirectory $missingFile -ExpectedExit 1
    Assert-Cli (-not [IO.File]::Exists($missingFile)) 'Invalid export parameters must leave no output.'
    Write-Host 'PASS: CLI install/list compatibility, WhatIf, notes, readable/encrypted export, and missing-password handling.'

    Assert-Cli ((Invoke-CliCase ImportPreview $destinationDirectory $standardFile).Contains('Add')) 'Import preview must return structured changes.'
    $null = Invoke-CliCase ImportWhatIf $destinationDirectory $standardFile
    $null = Invoke-CliCase NoPrompt $destinationDirectory $standardFile -ExpectedExit 1
    $null = Invoke-CliCase UnlockMissing $destinationDirectory $encryptedFile -ExpectedExit 1
    $null = Invoke-CliCase UnlockWrong $destinationDirectory $encryptedFile -ExpectedExit 1
    $null = Invoke-CliCase BadOption $destinationDirectory $standardFile -ExpectedExit 1
    Assert-Cli (-not [IO.Directory]::Exists($destinationDirectory)) 'Preview, WhatIf, missing approval, authentication failure, and unsupported options must not install.'
    $null = Invoke-CliCase ImportProtected $destinationDirectory $encryptedFile
    Assert-Cli ((Invoke-CliCase ImportApply $destinationDirectory $encryptedFile -ExpectedExit 1).Contains('needs a password')) 'Import must never reuse or store a previous password.'
    Assert-Cli ((Invoke-CliCase ImportApply $destinationDirectory $standardFile).Contains('Unchanged')) 'Repeated CLI import must be unchanged.'
    Write-Host 'PASS: CLI previews, explicit consent in noninteractive hosts, password failures, safe option validation, protected import, and idempotence.'

    Assert-Cli ((Invoke-CliCase Check $destinationDirectory).Contains('Healthy')) 'Check must return structured diagnostics.'
    $installedPaths = Get-EeaPaths $destination 'CLI website'
    [IO.File]::Delete($installedPaths.Desktop)
    Assert-Cli ((Invoke-CliCase RepairPreview $destinationDirectory).Contains('Repairable')) 'Repair preview must report missing files.'
    $null = Invoke-CliCase RepairWhatIf $destinationDirectory
    Assert-Cli (-not [IO.File]::Exists($installedPaths.Desktop)) 'CLI repair WhatIf must preserve missing files.'
    Assert-Cli ((Invoke-CliCase Repair $destinationDirectory).Contains('Repaired')) 'Approved CLI repair must report its outcome.'
    Assert-Cli ([IO.File]::Exists($installedPaths.Desktop)) 'Approved CLI repair must restore the shortcut.'
    $null = Invoke-CliCase RemoveWhatIf $destinationDirectory
    Assert-Cli ([IO.File]::Exists($installedPaths.Manifest)) 'Removal WhatIf must preserve settings.'
    $null = Invoke-CliCase Remove $destinationDirectory
    Assert-Cli (-not [IO.File]::Exists($installedPaths.Manifest)) 'The old Remove command must keep working.'
    $implicitDirectory = Join-Path $testRoot 'Implicit'
    $null = Invoke-CliCase ImplicitInstall $implicitDirectory
    Assert-Cli ($null -ne (Read-EeaManifest (New-CliContext $implicitDirectory) 'CLI website')) 'Name and URL must continue to imply Install.'
    Write-Host 'PASS: CLI Check, repair preview/WhatIf/approval, removal compatibility, and implicit Install.'

    $edgeRoot = Join-Path $testRoot 'Edge'
    [void][IO.Directory]::CreateDirectory((Join-Path $edgeRoot 'Default'))
    $bookmarkFile = Join-Path $edgeRoot 'Default\Bookmarks'
    [IO.File]::WriteAllText($bookmarkFile, '{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"url","name":"Favorite one","url":"https://example.org/one"},{"type":"url","name":"Favorite two","url":"https://example.org/two"},{"type":"url","name":"Unavailable","url":"http://example.org/old"}]}}}')
    $favoritesDirectory = Join-Path $testRoot 'Favorites'
    $bookmarkHash = (Get-FileHash -LiteralPath $bookmarkFile).Hash
    Assert-Cli ((Invoke-CliCase FavoritesList $favoritesDirectory -EdgeRoot $edgeRoot).Contains('Unavailable')) 'ListFavorites must include unsupported rows with availability information.'
    $favoritePreview = Invoke-CliCase FavoritesPreview $favoritesDirectory -EdgeRoot $edgeRoot
    Assert-Cli ($favoritePreview.Contains('Favorite one') -and -not $favoritePreview.Contains('Favorite two')) 'CLI selections must limit the preview.'
    Assert-Cli (-not [IO.Directory]::Exists($favoritesDirectory)) 'Listing and previewing favorites must be read-only.'
    $null = Invoke-CliCase FavoritesApply $favoritesDirectory -EdgeRoot $edgeRoot
    Assert-Cli (@(Get-EeaApps -Context (New-CliContext $favoritesDirectory)).Count -eq 2) 'CLI Favorites import must add only available HTTPS websites.'
    Assert-Cli ((Invoke-CliCase FavoritesApply $favoritesDirectory -EdgeRoot $edgeRoot).Contains('No new HTTPS favorites')) 'Repeated Favorites import must be idempotent.'
    Assert-Cli ((Get-FileHash -LiteralPath $bookmarkFile).Hash -ceq $bookmarkHash) 'CLI Favorites import must preserve Edge data.'
    Write-Host "PASS: Public parameter binding and command dispatch with isolated known-folder dependencies on PowerShell $($PSVersionTable.PSVersion)."
}
finally { if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }