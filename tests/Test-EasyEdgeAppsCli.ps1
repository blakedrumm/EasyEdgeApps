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
    $global:EeaCliTestContext = New-CliContext $TestDirectory
    function Get-EeaContext { return $global:EeaCliTestContext }
    $parseTokens = $null
    $parseErrors = $null
    $syntaxTree = [Management.Automation.Language.Parser]::ParseFile($applicationPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-Cli ($parseErrors.Count -eq 0 -and $syntaxTree.EndBlock.Statements[-1] -is [Management.Automation.Language.IfStatementAst]) 'The public command dispatcher must be identifiable without modifying source.'
    $parameterAttributes = @($syntaxTree.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
    $dispatcherPath = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.CliDispatcher.' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $secret = ConvertTo-SecureString 'Synthetic CLI test passphrase!' -AsPlainText -Force
    $incorrect = ConvertTo-SecureString 'Different synthetic passphrase!' -AsPlainText -Force
    $commandExitCode = 0
    $secretFile = $null
    try {
        [IO.File]::WriteAllText($dispatcherPath, ($parameterAttributes + "`n" + $syntaxTree.ParamBlock.Extent.Text + "`n" + $syntaxTree.EndBlock.Statements[-1].Extent.Text), (New-Object Text.UTF8Encoding($false)))
        if ($CommandCase -in @('UnattendedProtectedExport', 'UnattendedProtectedImport')) {
            $secretFile = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.CliSecret.' + [Guid]::NewGuid().ToString('N') + '.dpapi')
            $secret | ConvertFrom-SecureString | Set-Content -LiteralPath $secretFile -Encoding ASCII
            Assert-Cli (-not [IO.File]::ReadAllText($secretFile).Contains('Synthetic CLI test passphrase!')) 'Caller-managed Windows password storage must not contain plaintext.'
            $restoredSecret = ConvertTo-SecureString -String ((Get-Content -LiteralPath $secretFile -Raw).Trim())
            $secret.Dispose()
            $secret = $restoredSecret
        }
        if ($CommandCase -in @('UnattendedOpen', 'UnattendedInstall', 'OpenWithProfile', 'OpenFreshSession')) {
            $global:EeaCliTestLaunch = $null
            function Start-Process {
                [CmdletBinding()]
                param([string]$FilePath, [string]$ArgumentList)
                $global:EeaCliTestLaunch = [pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList }
            }
        }
        $commandOptions = switch ($CommandCase) {
            Install { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; Notes = 'Synthetic CLI notes.'; Confirm = $false; Quiet = $true } }
            InstallWithProfile { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; EdgeProfile = 'Profile 1'; Unattended = $true } }
            ClearProfile { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; EdgeProfile = ''; Unattended = $true } }
            InvalidProfile { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/'; EdgeProfile = 'Profile 1" --injected'; Unattended = $true } }
            OpenWithProfile { @{ Action = 'Open'; Name = 'CLI website'; Unattended = $true } }
            InstallFreshSession { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; EdgeProfile = 'Profile 1'; SessionMode = 'Fresh'; Unattended = $true } }
            InstallNormalSession { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; SessionMode = 'Normal'; Unattended = $true } }
            InvalidSessionMode { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/'; SessionMode = 'Unsafe'; Unattended = $true } }
            SessionModeOnOpen { @{ Action = 'Open'; Name = 'CLI website'; SessionMode = 'Fresh'; Unattended = $true } }
            OpenFreshSession { @{ Action = 'Open'; Name = 'CLI website'; Unattended = $true } }
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
            UnattendedImport { @{ Action = 'ImportKit'; Path = $FixturePath; Unattended = $true } }
            UnattendedWhatIf { @{ Action = 'ImportKit'; Path = $FixturePath; Unattended = $true; WhatIf = $true } }
            UnattendedInstall { @{ Action = 'Install'; Name = 'CLI website'; Url = 'https://example.com/cli?view=large#/home'; Launch = $true; Unattended = $true } }
            UnattendedOpen { @{ Action = 'Open'; Name = 'CLI website'; Unattended = $true } }
            UnattendedList { @{ Action = 'List'; Unattended = $true } }
            UnattendedExport { @{ Action = 'ExportKit'; Path = $FixturePath; Unattended = $true } }
            UnattendedReplace { @{ Action = 'ExportKit'; Path = $FixturePath; Replace = $true; Unattended = $true } }
            UnattendedProtectedExport { @{ Action = 'ExportKit'; Path = $FixturePath; Protected = $true; Password = $secret; PasswordConfirmation = $secret; Unattended = $true } }
            UnattendedProtectedImport { @{ Action = 'ImportKit'; Path = $FixturePath; Password = $secret; Unattended = $true } }
            UnattendedMissingPassword { @{ Action = 'ImportKit'; Path = $FixturePath; Unattended = $true } }
            UnattendedSelection { @{ Action = 'ImportKit'; Path = $FixturePath; AppNames = @('cli WEBSITE'); Unattended = $true } }
            UnattendedSelectionPreview { @{ Action = 'ImportKit'; Path = $FixturePath; AppNames = @('CLI website'); Preview = $true; Unattended = $true } }
            UnattendedUnknownSelection { @{ Action = 'ImportKit'; Path = $FixturePath; AppNames = @('Not in the kit'); Unattended = $true } }
            UnattendedEmptySelection { @{ Action = 'ImportKit'; Path = $FixturePath; AppNames = @(); Unattended = $true } }
            UnattendedCheck { @{ Action = 'Check'; Unattended = $true } }
            UnattendedRepair { @{ Action = 'Repair'; AppNames = @('CLI website'); Unattended = $true } }
            UnattendedRemove { @{ Action = 'Remove'; Name = 'CLI website'; Unattended = $true } }
            UnattendedFavorites { @{ Action = 'ImportFavorites'; EdgeUserDataPath = $FavoritesRoot; EdgeProfile = 'Default'; Unattended = $true } }
            UnattendedSetup { @{ Action = 'Setup'; Unattended = $true } }
            UnattendedConfirm { @{ Action = 'ImportKit'; Path = $FixturePath; Unattended = $true; Confirm = $true } }
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
        $global:LASTEXITCODE = if ($commandOptions.ContainsKey('Unattended')) { 47 } else { 0 }
        & $dispatcherPath @commandOptions | ConvertTo-Json -Depth 8 -Compress
        $commandExitCode = $LASTEXITCODE
        if ($CommandCase -ceq 'OpenFreshSession' -and $commandExitCode -eq 0) {
            $freshPaths = Get-EeaPaths $global:EeaCliTestContext 'CLI website'
            Assert-Cli ($null -ne $global:EeaCliTestLaunch -and $global:EeaCliTestLaunch.FilePath -ceq $freshPaths.Launcher -and -not $global:EeaCliTestLaunch.ArgumentList) 'Fresh-session Open must use the owned native launcher without forwarded arguments.'
        }
        if ($CommandCase -in @('UnattendedOpen', 'UnattendedInstall', 'OpenWithProfile') -and $commandExitCode -eq 0) {
            $expectedArguments = '--app="https://example.com/cli?view=large#/home" --start-maximized'
            if ($CommandCase -ceq 'OpenWithProfile') { $expectedArguments += ' --profile-directory="Profile 1"' }
            Assert-Cli ($null -ne $global:EeaCliTestLaunch -and $global:EeaCliTestLaunch.FilePath -ceq (Find-EeaEdge) -and $global:EeaCliTestLaunch.ArgumentList -ceq $expectedArguments) 'Explicit unattended browser commands must use the discovered Edge executable and validated app arguments.'
        }
    }
    finally {
        $secret.Dispose()
        $incorrect.Dispose()
        if ([IO.File]::Exists($dispatcherPath)) { [IO.File]::Delete($dispatcherPath) }
        if ($secretFile -and [IO.File]::Exists($secretFile)) { [IO.File]::Delete($secretFile) }
    }
    exit $commandExitCode
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

function Test-CliHelp {
    $quotedApplicationPath = "'" + $applicationPath.Replace("'", "''") + "'"
    foreach ($example in (Get-Help -Name $applicationPath -Full).examples.example) {
        $descriptionText = ($example.remarks | ForEach-Object { $_.Text }) -join ' '
        Assert-Cli (-not [regex]::IsMatch($descriptionText.Trim(), '[\r\n]')) 'Example descriptions must be single paragraphs so the host wraps them naturally.'
    }
    $exampleScenarios = @(
        "Set up a family member's everyday websites."
        'Review the available commands before making changes.'
        'Add a familiar mail shortcut for the current Windows user.'
        "Preview removal before changing a family member's setup."
        "Back up the current user's saved websites for a replacement computer."
        'Restore only My Mail from a previously reviewed, trusted App Kit.'
    )
    foreach ($helpArguments in @('--help', '-h', '-?', '-Help', '--help -Name ''Help test'' -Url ''https://example.com/'' -Unattended -Quiet', '-h -Action ImportKit -Unattended -Quiet', '-? -Action Repair -Unattended')) {
        $commandText = '$WhatIfPreference = $true' + "`n& " + $quotedApplicationPath + ' ' + $helpArguments + "`nif (-not `$?) { exit 1 }"
        $options = @('-NoLogo', '-NoProfile', '-STA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $commandText)
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $commandOutput = @(& $hostExecutable @options 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        $outputText = $commandOutput -join "`n"
        $normalizedText = [regex]::Replace($outputText, '\s+', ' ')
        Assert-Cli ($exitCode -eq 0) ("Help invocation '$helpArguments' returned $exitCode. " + $outputText)
        Assert-Cli ($normalizedText.Contains('Creates easy-to-find, per-user Microsoft Edge website shortcuts on Windows 11.')) ("Help invocation '$helpArguments' must display the application help. " + $outputText)
        Assert-Cli (-not $normalizedText.Contains('What if: Performing')) "Help invocation '$helpArguments' must not dispatch an operation."
        if (-not $helpArguments.StartsWith('-?')) {
            Assert-Cli (-not [regex]::IsMatch($outputText, '(?:\r?\n[\t ]*){3}')) "Help invocation '$helpArguments' must use at most one blank line between items."
            foreach ($scenario in $exampleScenarios) {
                Assert-Cli ($normalizedText.Contains($scenario)) "Help invocation '$helpArguments' must explain each example's scenario: $scenario"
            }
        }
    }
    Write-Host 'PASS: Help aliases display documented scenarios and compact custom formatting without setup, action validation, prompts, or writes.'
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    Test-CliHelp
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

    $profileDirectory = Join-Path $testRoot 'Profiles'
    $profileContext = New-CliContext $profileDirectory
    $null = Invoke-CliCase InvalidProfile $profileDirectory -ExpectedExit 1
    Assert-Cli (-not [IO.Directory]::Exists($profileDirectory)) 'An invalid profile identifier must fail before creating app data.'
    $null = Invoke-CliCase InstallWithProfile $profileDirectory
    Assert-Cli ((Get-EeaStateProfile (Read-EeaManifest $profileContext 'CLI website')) -ceq 'Profile 1') 'Install must forward the explicit profile through the public dispatcher.'
    $null = Invoke-CliCase OpenWithProfile $profileDirectory
    $null = Invoke-CliCase ClearProfile $profileDirectory
    Assert-Cli ((Get-EeaStateProfile (Read-EeaManifest $profileContext 'CLI website')) -ceq '') 'An explicitly empty profile must restore Edge-controlled selection.'
    $null = Invoke-CliCase UnattendedOpen $profileDirectory
    Write-Host 'PASS: Public profile override, saved-profile launch, explicit clearing, and unsafe-profile rejection.'

    $sessionDirectory = Join-Path $testRoot 'Fresh sessions'
    $sessionContext = New-CliContext $sessionDirectory
    $null = Invoke-CliCase InvalidSessionMode $sessionDirectory -ExpectedExit 1
    $null = Invoke-CliCase SessionModeOnOpen $sessionDirectory -ExpectedExit 1
    Assert-Cli (-not [IO.Directory]::Exists($sessionDirectory)) 'Invalid or misplaced session options must fail before creating app data.'
    $null = Invoke-CliCase InstallFreshSession $sessionDirectory
    Assert-Cli ((Get-EeaStateFreshSession (Read-EeaManifest $sessionContext 'CLI website'))) 'Install must forward the explicit fresh-session option.'
    $null = Invoke-CliCase OpenFreshSession $sessionDirectory
    $null = Invoke-CliCase Install $sessionDirectory
    Assert-Cli ((Get-EeaStateFreshSession (Read-EeaManifest $sessionContext 'CLI website'))) 'A subsequent Install without a session option must preserve fresh sessions.'
    $null = Invoke-CliCase InstallNormalSession $sessionDirectory
    Assert-Cli (-not (Get-EeaStateFreshSession (Read-EeaManifest $sessionContext 'CLI website'))) 'An explicit Normal option must restore persistent browsing.'
    $null = Invoke-CliCase OpenWithProfile $sessionDirectory
    Write-Host 'PASS: Public fresh-session opt-in, no-argument launch routing, preservation, explicit opt-out, and invalid-option rejection.'

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

    $unattendedDirectory = Join-Path $testRoot 'Unattended'
    $null = Invoke-CliCase UnattendedWhatIf $unattendedDirectory $standardFile
    $null = Invoke-CliCase UnattendedSetup $unattendedDirectory -ExpectedExit 1
    $null = Invoke-CliCase UnattendedConfirm $unattendedDirectory $standardFile -ExpectedExit 1
    Assert-Cli (-not [IO.Directory]::Exists($unattendedDirectory)) 'Unattended WhatIf and invalid unattended options must not create files or open setup.'
    $unattendedResult = ConvertFrom-EeaJson (Invoke-CliCase UnattendedImport $unattendedDirectory $standardFile)
    Assert-Cli ($unattendedResult.Status -ceq 'Added') 'Unattended import must explicitly approve changes and return clean pipeline results without host previews.'
    $unattendedInstall = ConvertFrom-EeaJson (Invoke-CliCase UnattendedInstall $unattendedDirectory)
    Assert-Cli ($unattendedInstall.Name -ceq 'CLI website' -and $unattendedInstall.Url -ceq 'https://example.com/cli?view=large#/home') 'Unattended install must return saved app data.'
    $null = Invoke-CliCase UnattendedOpen $unattendedDirectory
    Assert-Cli ((ConvertFrom-EeaJson (Invoke-CliCase UnattendedList $unattendedDirectory)).Name -ceq 'CLI website') 'Unattended listing must return clean data.'
    $automatedFile = Join-Path $testRoot 'Automated.eeakit.json'
    $exportResult = ConvertFrom-EeaJson (Invoke-CliCase UnattendedExport $unattendedDirectory $automatedFile)
    Assert-Cli ($exportResult.AppCount -eq 1 -and -not $exportResult.Protected) 'Unattended readable export must return its file outcome.'
    $automatedHash = (Get-FileHash -LiteralPath $automatedFile).Hash
    $null = Invoke-CliCase UnattendedExport $unattendedDirectory $automatedFile -ExpectedExit 1
    Assert-Cli ((Get-FileHash -LiteralPath $automatedFile).Hash -ceq $automatedHash) 'Unattended mode must not implicitly authorize replacing an export.'
    $null = Invoke-CliCase UnattendedReplace $unattendedDirectory $automatedFile
    $automatedProtectedFile = Join-Path $testRoot 'Automated protected.eeakit.json'
    $protectedResult = ConvertFrom-EeaJson (Invoke-CliCase UnattendedProtectedExport $unattendedDirectory $automatedProtectedFile)
    Assert-Cli $protectedResult.Protected 'Unattended protected export must use the provided SecureString without prompting.'
    $protectedDirectory = Join-Path $testRoot 'Unattended protected'
    $null = Invoke-CliCase UnattendedMissingPassword $protectedDirectory $automatedProtectedFile -ExpectedExit 1
    Assert-Cli (-not [IO.Directory]::Exists($protectedDirectory)) 'Unattended encrypted import must fail without a password and never open setup.'
    Assert-Cli ((ConvertFrom-EeaJson (Invoke-CliCase UnattendedProtectedImport $protectedDirectory $automatedProtectedFile)).Status -ceq 'Added') 'Unattended encrypted import must use the caller-provided SecureString.'
    $unattendedContext = New-CliContext $unattendedDirectory
    Assert-Cli ((ConvertFrom-EeaJson (Invoke-CliCase UnattendedCheck $unattendedDirectory)).Status -ceq 'Healthy') 'Unattended checks must return structured diagnoses.'
    [IO.File]::Delete((Get-EeaPaths $unattendedContext 'CLI website').Desktop)
    Assert-Cli ((ConvertFrom-EeaJson (Invoke-CliCase UnattendedRepair $unattendedDirectory)).Status -ceq 'Repaired') 'Unattended repair must explicitly approve only safe repairs.'
    $null = Invoke-CliCase UnattendedRemove $unattendedDirectory
    Assert-Cli ($null -eq (Read-EeaManifest $unattendedContext 'CLI website')) 'Unattended removal must remove only owned app files.'
    $conflictDirectory = Join-Path $testRoot 'Unattended conflict'
    $conflictContext = New-CliContext $conflictDirectory
    [void][IO.Directory]::CreateDirectory($conflictContext.Desktop)
    $foreignShortcut = (Get-EeaPaths $conflictContext 'CLI website').Desktop
    [IO.File]::WriteAllText($foreignShortcut, 'Synthetic unrelated shortcut')
    $conflictResult = ConvertFrom-EeaJson (Invoke-CliCase UnattendedImport $conflictDirectory $standardFile -ExpectedExit 1)
    Assert-Cli ($conflictResult.Status -ceq 'Conflict' -and -not [IO.Directory]::Exists($conflictContext.Root) -and [IO.File]::ReadAllText($foreignShortcut) -ceq 'Synthetic unrelated shortcut') 'Unattended approval must preserve unrelated files and report conflicts with a failing exit code.'
    Write-Host 'PASS: Unattended approval, clean results, WhatIf safety, and setup/confirmation conflict rejection.'

    $selectionKit = Read-EeaKit $standardFile
    $selectionKit.Apps += [pscustomobject]@{ Name = 'Unselected website'; Url = 'https://example.net/'; Desktop = $true; StartMenu = $true; Notes = ''; Icon = [pscustomobject]@{ Kind = 'Generated'; Version = 1 } }
    $selectionFile = Join-Path $testRoot 'Selection.eeakit.json'
    $null = Write-EeaKit -Kit $selectionKit -Path $selectionFile -Confirm:$false
    $selectionDirectory = Join-Path $testRoot 'Selection'
    $null = Invoke-CliCase UnattendedUnknownSelection $selectionDirectory $selectionFile -ExpectedExit 1
    $null = Invoke-CliCase UnattendedEmptySelection $selectionDirectory $selectionFile -ExpectedExit 1
    $selectedPreview = ConvertFrom-EeaJson (Invoke-CliCase UnattendedSelectionPreview $selectionDirectory $selectionFile)
    Assert-Cli ($selectedPreview.Name -ceq 'CLI website' -and -not [IO.Directory]::Exists($selectionDirectory)) 'Selected import previews and invalid selections must not create files.'
    $selectedResult = ConvertFrom-EeaJson (Invoke-CliCase UnattendedSelection $selectionDirectory $selectionFile)
    Assert-Cli ($selectedResult.Name -ceq 'CLI website' -and $selectedResult.Status -ceq 'Added') 'Kit import must match a selected name case-insensitively.'
    Assert-Cli (@(Get-EeaApps -Context (New-CliContext $selectionDirectory)).Count -eq 1) 'Unselected apps must not be imported.'
    Write-Host 'PASS: Named kit import, safe selections, Windows-protected password loading, unattended transfers, conflicts, launch routing, and explicit success exit codes.'

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
    $unattendedFavoritesDirectory = Join-Path $testRoot 'Unattended favorites'
    $favoritesResult = ConvertFrom-EeaJson (Invoke-CliCase UnattendedFavorites $unattendedFavoritesDirectory -EdgeRoot $edgeRoot)
    Assert-Cli ($favoritesResult.Count -eq 2 -and @($favoritesResult | Where-Object { $_.Status -cne 'Added' }).Count -eq 0) 'Unattended Favorites import must return per-app results without prompts or previews.'
    Assert-Cli ((Invoke-CliCase FavoritesApply $favoritesDirectory -EdgeRoot $edgeRoot).Contains('No new HTTPS favorites')) 'Repeated Favorites import must be idempotent.'
    Assert-Cli ((Get-FileHash -LiteralPath $bookmarkFile).Hash -ceq $bookmarkHash) 'CLI Favorites import must preserve Edge data.'
    Write-Host "PASS: Public parameter binding and command dispatch with isolated known-folder dependencies on PowerShell $($PSVersionTable.PSVersion)."
}
finally { if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force } }