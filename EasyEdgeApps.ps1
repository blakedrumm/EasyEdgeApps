#requires -Version 5.1

<#
.SYNOPSIS
Creates easy-to-find, per-user Microsoft Edge website shortcuts on Windows 11.
.DESCRIPTION
Run without parameters for the setup window. Use Install, List, Remove, or Open
for command-line use. No administrator rights, external modules, downloads,
browser policy changes, or persistent execution-policy changes are required.
.EXAMPLE
.\EasyEdgeApps.ps1
.EXAMPLE
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/'
.EXAMPLE
.\EasyEdgeApps.ps1 -Action Remove -Name 'My Mail' -WhatIf
.LINK
https://github.com/blakedrumm/EasyEdgeApps
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Setup', 'Install', 'List', 'Remove', 'Open')]
    [string]$Action = 'Setup',
    [string]$Name,
    [string]$Url,
    [string]$IconPath,
    [switch]$NoDesktop,
    [switch]$NoStartMenu,
    [switch]$Launch,
    [switch]$Quiet
)

function ConvertTo-EeaName {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $cleanName = $Value.Trim().Normalize([Text.NormalizationForm]::FormC)
    if ($cleanName.Length -lt 1 -or $cleanName.Length -gt 60) {
        throw 'Choose a name between 1 and 60 characters long.'
    }
    if ($cleanName -match '[<>:"/\\|?*\p{Cc}\p{Cf}\p{Zl}\p{Zp}]' -or $cleanName.EndsWith('.')) {
        throw 'Choose a name without slashes, quotes, special file characters, or a final dot.'
    }
    if ($cleanName -match '^(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\..*)?$') {
        throw 'That name is reserved by Windows. Please choose another name.'
    }
    return $cleanName
}

function ConvertTo-EeaWebsite {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $websiteText = $Value.Trim()
    $websiteUri = $null
    if ($websiteText.Length -gt 2048 -or $websiteText -notmatch '^https://' -or
        $websiteText -match '[\s\p{Cc}\p{Cf}"\\]' -or
        -not [Uri]::TryCreate($websiteText, [UriKind]::Absolute, [ref]$websiteUri)) {
        throw 'Enter a complete website address starting with https://, without spaces or quotes.'
    }
    if ($websiteUri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($websiteUri.Host) -or
        $websiteUri.UserInfo.Length -gt 0 -or -not $websiteUri.IsWellFormedOriginalString()) {
        throw 'Use an https:// website address without a username or password in the address.'
    }
    $builder = New-Object UriBuilder($websiteUri)
    $builder.Host = $websiteUri.IdnHost
    return $builder.Uri.AbsoluteUri
}

function Get-EeaId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AppName)

    $canonicalName = (ConvertTo-EeaName $AppName).ToUpperInvariant()
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalName))
        return [BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
    }
}

function Get-EeaArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Website)

    return '--app="{0}" --start-maximized' -f (ConvertTo-EeaWebsite $Website)
}

function Write-EeaShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Icon
    )

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $Target
        $shortcut.Arguments = $Arguments
        $shortcut.Description = $Description
        $shortcut.WorkingDirectory = [IO.Path]::GetDirectoryName($Target)
        $shortcut.IconLocation = $Icon
        $shortcut.WindowStyle = 3
        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Read-EeaShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) { throw 'The shortcut could not be found.' }
    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return [pscustomobject]@{
            TargetPath = $shortcut.TargetPath
            Arguments = $shortcut.Arguments
            Description = $shortcut.Description
            IconLocation = $shortcut.IconLocation
            WorkingDirectory = $shortcut.WorkingDirectory
        }
    }
    finally {
        if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) }
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
}

function Get-EeaContext {
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') { throw 'Easy Edge Apps needs Windows and Microsoft Edge.' }
    $folderOption = [Environment+SpecialFolderOption]::DoNotVerify
    return [pscustomobject]@{
        Root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData', $folderOption)) 'EasyEdgeApps'
        Desktop = [Environment]::GetFolderPath('DesktopDirectory', $folderOption)
        Programs = Join-Path ([Environment]::GetFolderPath('Programs', $folderOption)) 'Easy Edge Apps'
    }
}

function Find-EeaEdge {
    [CmdletBinding()]
    param()

    $candidates = New-Object 'Collections.Generic.List[string]'
    foreach ($registryPath in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )) {
        $registryKey = Get-Item -LiteralPath $registryPath -ErrorAction SilentlyContinue
        if ($null -ne $registryKey) {
            try {
                $registeredPath = [string]$registryKey.GetValue('')
                if ($registeredPath) { $candidates.Add([Environment]::ExpandEnvironmentVariables($registeredPath).Trim('"')) }
            }
            finally { $registryKey.Close() }
        }
    }
    foreach ($baseDirectory in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if ($baseDirectory) { $candidates.Add((Join-Path $baseDirectory 'Microsoft\Edge\Application\msedge.exe')) }
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::GetFileName($candidate) -ieq 'msedge.exe' -and [IO.File]::Exists($candidate)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'Microsoft Edge could not be found. Ask your helper to install or repair Edge, then try again.'
}

function Get-EeaPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$AppName)

    $cleanName = ConvertTo-EeaName $AppName
    $appId = Get-EeaId $cleanName
    $appsRoot = Join-Path $Context.Root 'Apps'
    $appDirectory = Join-Path $appsRoot $appId
    return [pscustomobject]@{
        Id = $appId
        AppsRoot = $appsRoot
        Directory = $appDirectory
        Manifest = Join-Path $appDirectory 'app.json'
        Icon = Join-Path $appDirectory 'icon.ico'
        Desktop = Join-Path $Context.Desktop ($cleanName + '.lnk')
        StartMenu = Join-Path $Context.Programs ($cleanName + '.lnk')
    }
}

function Assert-EeaSafePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentPath = [IO.Path]::GetFullPath($Path)
    while ($currentPath) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $linkProperty = $item.PSObject.Properties['LinkType']
            if ($null -ne $linkProperty -and $linkProperty.Value -in @('SymbolicLink', 'Junction')) {
                throw 'A setup location is a symbolic link or junction. Nothing was changed; ask your helper to check the folder.'
            }
        }
        $currentPath = [IO.Path]::GetDirectoryName($currentPath)
    }
}

function Assert-EeaReady {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    Assert-EeaSafePath $Context.Root
    $pendingPath = Join-Path $Context.Root '.pending'
    if (Test-Path -LiteralPath $pendingPath) {
        Assert-EeaSafePath $pendingPath
        $completionPath = Join-Path $pendingPath 'complete.txt'
        if (-not [IO.File]::Exists($completionPath) -or [IO.File]::ReadAllText($completionPath) -cne 'EasyEdgeApps:complete:1') {
            throw "An earlier change needs recovery. Nothing was changed. Ask your helper to check $($Context.Root)\.pending and the README recovery section."
        }
    }
}

function Read-EeaManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$AppName)

    $paths = Get-EeaPaths $Context $AppName
    Assert-EeaSafePath $paths.Manifest
    if (-not [IO.File]::Exists($paths.Manifest)) { return $null }
    try {
        if ((Get-Item -LiteralPath $paths.Manifest -Force).Length -gt 32768) { throw 'Settings are too large.' }
        $state = [IO.File]::ReadAllText($paths.Manifest, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        foreach ($propertyName in @('Product', 'SchemaVersion', 'Id', 'Name', 'Url', 'Desktop', 'StartMenu', 'EdgePath', 'IconHash')) {
            if ($null -eq $state.PSObject.Properties[$propertyName]) { throw 'A required setting is missing.' }
        }
        if ($state.Product -cne 'EasyEdgeApps' -or $state.SchemaVersion -ne 1 -or
            $state.Id -cne $paths.Id -or (Get-EeaId $state.Name) -cne $paths.Id -or
            $state.Name -cne (ConvertTo-EeaName $state.Name) -or
            $state.Url -cne (ConvertTo-EeaWebsite $state.Url) -or
            $state.Desktop -isnot [bool] -or $state.StartMenu -isnot [bool] -or
            (-not $state.Desktop -and -not $state.StartMenu) -or
            -not [IO.Path]::IsPathRooted($state.EdgePath) -or
            [IO.Path]::GetFileName($state.EdgePath) -ine 'msedge.exe' -or
            $state.IconHash -cnotmatch '^[a-f0-9]{64}$') {
            throw 'Settings do not match this app.'
        }
        return $state
    }
    catch {
        throw 'The saved settings for this website are damaged or were changed outside Easy Edge Apps. Nothing was changed; ask your helper to check them.'
    }
}

function Get-EeaApps {
    [CmdletBinding()]
    param($Context = (Get-EeaContext))

    Assert-EeaReady $Context
    $appsRoot = Join-Path $Context.Root 'Apps'
    Assert-EeaSafePath $appsRoot
    if (-not [IO.Directory]::Exists($appsRoot)) { return }
    foreach ($directory in @(Get-ChildItem -LiteralPath $appsRoot -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        if ($directory.Name -cnotmatch '^[a-f0-9]{64}$') { continue }
        $manifestPath = Join-Path $directory.FullName 'app.json'
        Assert-EeaSafePath $manifestPath
        if (-not [IO.File]::Exists($manifestPath)) { continue }
        try {
            if ((Get-Item -LiteralPath $manifestPath -Force).Length -gt 32768) { throw 'Settings are too large.' }
            $summary = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $summary.PSObject.Properties['Name'] -or (Get-EeaId $summary.Name) -cne $directory.Name) {
                throw 'Settings identity does not match its folder.'
            }
            Read-EeaManifest $Context $summary.Name
        }
        catch {
            throw 'A saved website has damaged settings. Nothing was changed; ask your helper to check the Apps folder in EasyEdgeApps.'
        }
    }
}

function Test-EeaOwnedShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$Paths)

    Assert-EeaSafePath $Path
    if (-not [IO.File]::Exists($Path)) { return $false }
    $shortcut = Read-EeaShortcut $Path
    return ($shortcut.Description -ceq ('EasyEdgeApps:' + $State.Id) -and
        $shortcut.Arguments -ceq (Get-EeaArguments $State.Url) -and
        [StringComparer]::OrdinalIgnoreCase.Equals($shortcut.TargetPath, $State.EdgePath) -and
        [StringComparer]::OrdinalIgnoreCase.Equals($shortcut.IconLocation, ($Paths.Icon + ',0')))
}

function Assert-EeaOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths, $State, [bool]$Desktop, [bool]$StartMenu)

    foreach ($slot in @('Desktop', 'StartMenu')) {
        $previouslyOwned = $null -ne $State -and [bool]$State.$slot
        $requested = if ($slot -eq 'Desktop') { $Desktop } else { $StartMenu }
        if (-not $previouslyOwned -and -not $requested) { continue }
        $shortcutPath = $Paths.$slot
        Assert-EeaSafePath $shortcutPath
        if ($shortcutPath.Length -gt 240) { throw 'The shortcut location is too long. Choose a shorter website name or ask your helper to check the folder.' }
        if (Test-Path -LiteralPath $shortcutPath) {
            if (-not $previouslyOwned -or -not (Test-EeaOwnedShortcut $shortcutPath $State $Paths)) {
                throw 'A shortcut with this name already exists or was changed outside Easy Edge Apps. Choose another name, or ask your helper to move that shortcut first.'
            }
        }
    }
    Assert-EeaSafePath $Paths.Icon
    if (Test-Path -LiteralPath $Paths.Icon) {
        if ($null -eq $State -or -not [IO.File]::Exists($Paths.Icon) -or
            (Get-FileHash -LiteralPath $Paths.Icon -Algorithm SHA256).Hash.ToLowerInvariant() -cne $State.IconHash) {
            throw 'The saved icon was changed outside Easy Edge Apps. Nothing was changed; ask your helper to check it.'
        }
    }
}

function New-EeaIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$AppName)

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $bitmap = New-Object Drawing.Bitmap(256, 256)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $font = New-Object Drawing.Font('Segoe UI', 144, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $format = New-Object Drawing.StringFormat
    $writer = $null
    try {
        $palette = @('#126C65', '#2859A0', '#A03558', '#654F96')
        $paletteIndex = [Convert]::ToInt32((Get-EeaId $AppName).Substring(0, 2), 16) % $palette.Count
        $graphics.Clear([Drawing.ColorTranslator]::FromHtml($palette[$paletteIndex]))
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $format.Alignment = [Drawing.StringAlignment]::Center
        $format.LineAlignment = [Drawing.StringAlignment]::Center
        $letter = [Globalization.StringInfo]::GetNextTextElement($AppName).ToUpperInvariant()
        $graphics.DrawString($letter, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, 256, 248)), $format)
        $graphics.Flush()
        $pixelBytes = New-Object byte[] (256 * 256 * 4)
        $maskBytes = New-Object byte[] (32 * 256)
        $bitmapData = $bitmap.LockBits((New-Object Drawing.Rectangle(0, 0, 256, 256)), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            for ($pixelRow = 0; $pixelRow -lt 256; $pixelRow++) {
                $rowPointer = [IntPtr]::Add($bitmapData.Scan0, $pixelRow * $bitmapData.Stride)
                [Runtime.InteropServices.Marshal]::Copy($rowPointer, $pixelBytes, (255 - $pixelRow) * 1024, 1024)
            }
        }
        finally { $bitmap.UnlockBits($bitmapData) }
        $writer = New-Object IO.BinaryWriter([IO.File]::Create($Path))
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32](40 + $pixelBytes.Length + $maskBytes.Length))
        $writer.Write([uint32]22)
        $writer.Write([uint32]40)
        $writer.Write([int32]256)
        $writer.Write([int32]512)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]0)
        $writer.Write([uint32]($pixelBytes.Length + $maskBytes.Length))
        $writer.Write([int32]0)
        $writer.Write([int32]0)
        $writer.Write([uint32]0)
        $writer.Write([uint32]0)
        $writer.Write($pixelBytes)
        $writer.Write($maskBytes)
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        $format.Dispose()
        $font.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Read-EeaCustomIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    if ([IO.Path]::GetExtension($resolvedPath) -ine '.ico' -or
        (Get-Item -LiteralPath $resolvedPath -Force).Length -gt 1048576) {
        throw 'Choose a local .ico picture no larger than 1 MB.'
    }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $iconStream = [IO.File]::OpenRead($resolvedPath)
    $icon = $null
    try {
        $icon = New-Object Drawing.Icon($iconStream)
        $iconStream.Position = 0
        $bytes = New-Object byte[] $iconStream.Length
        $bytesRead = $iconStream.Read($bytes, 0, $bytes.Length)
        if ($bytesRead -ne $bytes.Length) { throw 'The icon could not be read completely.' }
        return ,$bytes
    }
    finally {
        if ($null -ne $icon) { $icon.Dispose() }
        $iconStream.Dispose()
    }
}

function Write-EeaAtomicFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)

    Assert-EeaSafePath $Destination
    $siblingPath = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.EasyEdgeApps.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::Copy($Source, $siblingPath, $false)
        if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($siblingPath, $Destination, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($siblingPath, $Destination) }
    }
    finally {
        if ([IO.File]::Exists($siblingPath)) { [IO.File]::Delete($siblingPath) }
    }
}

function Invoke-EeaTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][scriptblock]$Prepare)

    Assert-EeaReady $Context
    $pendingPath = Join-Path $Context.Root '.pending'
    if ([IO.Directory]::Exists($pendingPath)) {
        try { [IO.Directory]::Delete($pendingPath, $true) }
        catch { throw 'Windows is still using temporary files from the last completed change. Your saved websites are safe. Please try the change again later.' }
    }
    [void][IO.Directory]::CreateDirectory($pendingPath)
    $appliedSteps = New-Object 'Collections.Generic.List[object]'
    $createdDirectories = New-Object 'Collections.Generic.List[string]'
    $keepRecovery = $false
    try {
        $stagePath = Join-Path $pendingPath 'staged'
        [void][IO.Directory]::CreateDirectory($stagePath)
        $steps = @(& $Prepare $stagePath)
        $journal = New-Object 'Collections.Generic.List[object]'
        foreach ($step in $steps) {
            Assert-EeaSafePath $step.Path
            if ([IO.Directory]::Exists($step.Path)) { throw 'A folder is using a file location needed for this website.' }
            $backupPath = Join-Path $pendingPath ($journal.Count.ToString() + '.backup')
            $existed = [IO.File]::Exists($step.Path)
            if ($existed) { [IO.File]::Copy($step.Path, $backupPath, $false) }
            $journal.Add([pscustomobject]@{ Path = $step.Path; Source = $step.Source; Existed = $existed; Backup = $backupPath })
        }
        $journalJson = ConvertTo-Json -InputObject @($journal.ToArray()) -Depth 5
        [IO.File]::WriteAllText((Join-Path $pendingPath 'journal.json'), $journalJson, (New-Object Text.UTF8Encoding($false)))
        foreach ($entry in $journal) {
            $parentDirectory = [IO.Path]::GetDirectoryName($entry.Path)
            if (-not [IO.Directory]::Exists($parentDirectory)) {
                [void][IO.Directory]::CreateDirectory($parentDirectory)
                $createdDirectories.Add($parentDirectory)
            }
            if ($null -ne $entry.Source) { Write-EeaAtomicFile $entry.Source $entry.Path }
            elseif ($entry.Existed) { [IO.File]::Delete($entry.Path) }
            $appliedSteps.Add($entry)
        }
    }
    catch {
        $originalError = $_
        for ($stepIndex = $appliedSteps.Count - 1; $stepIndex -ge 0; $stepIndex--) {
            $entry = $appliedSteps[$stepIndex]
            try {
                if ($entry.Existed) { Write-EeaAtomicFile $entry.Backup $entry.Path }
                else { [IO.File]::Delete($entry.Path) }
            }
            catch { $keepRecovery = $true }
        }
        foreach ($directory in $createdDirectories) {
            if ([IO.Directory]::Exists($directory) -and [IO.Directory]::GetFileSystemEntries($directory).Length -eq 0) {
                [IO.Directory]::Delete($directory, $false)
            }
        }
        if ($keepRecovery) {
            throw "The change could not finish or be fully undone. Recovery copies are in $pendingPath. Ask your helper to check them before trying again."
        }
        throw $originalError
    }
    finally {
        if (-not $keepRecovery -and [IO.Directory]::Exists($pendingPath)) {
            Assert-EeaSafePath $pendingPath
            try { [IO.Directory]::Delete($pendingPath, $true) }
            catch [IO.IOException] {
                if ([IO.Directory]::Exists($pendingPath)) {
                    [IO.File]::WriteAllText((Join-Path $pendingPath 'complete.txt'), 'EasyEdgeApps:complete:1', [Text.Encoding]::ASCII)
                    Write-Warning 'Windows is still using temporary setup files. The completed change is safe; cleanup will be retried on the next change.'
                }
            }
        }
    }
}

function Invoke-EeaLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$Operation)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $mutexName = 'Local\EasyEdgeApps-' + $identity.User.Value }
    finally { $identity.Dispose() }
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another Easy Edge Apps change is in progress. Please try again when it has finished.' }
        & $Operation
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Install-EeaApp {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$Website,
        [string]$CustomIcon,
        [bool]$Desktop = $true,
        [bool]$StartMenu = $true,
        $Context = (Get-EeaContext)
    )

    $cleanName = ConvertTo-EeaName $AppName
    $cleanWebsite = ConvertTo-EeaWebsite $Website
    if (-not $Desktop -and -not $StartMenu) { throw 'Choose Desktop, Start menu, or both.' }
    $edgePath = Find-EeaEdge
    $paths = Get-EeaPaths $Context $cleanName
    $iconBytes = $null
    if ($CustomIcon) { $iconBytes = Read-EeaCustomIcon $CustomIcon }
    if (-not $PSCmdlet.ShouldProcess($cleanName, 'Create or update website shortcuts for the current Windows user')) { return }
    Invoke-EeaLocked {
        Assert-EeaReady $Context
        $previousState = Read-EeaManifest $Context $cleanName
        Assert-EeaOwnership -Paths $paths -State $previousState -Desktop $Desktop -StartMenu $StartMenu
        Invoke-EeaTransaction -Context $Context -Prepare {
            param($StagePath)
            $stagedIcon = Join-Path $StagePath 'icon.ico'
            if ($null -ne $iconBytes) { [IO.File]::WriteAllBytes($stagedIcon, $iconBytes) }
            elseif ($null -ne $previousState -and [IO.File]::Exists($paths.Icon)) { [IO.File]::Copy($paths.Icon, $stagedIcon) }
            else { New-EeaIcon -Path $stagedIcon -AppName $cleanName }
            $newState = [pscustomobject][ordered]@{
                Product = 'EasyEdgeApps'
                SchemaVersion = 1
                Id = $paths.Id
                Name = $cleanName
                Url = $cleanWebsite
                Desktop = $Desktop
                StartMenu = $StartMenu
                EdgePath = $edgePath
                IconHash = (Get-FileHash -LiteralPath $stagedIcon -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            [pscustomobject]@{ Path = $paths.Icon; Source = $stagedIcon }
            foreach ($slot in @('Desktop', 'StartMenu')) {
                $selected = if ($slot -eq 'Desktop') { $Desktop } else { $StartMenu }
                if ($selected) {
                    $stagedShortcut = Join-Path $StagePath ($slot + '.lnk')
                    Write-EeaShortcut -Path $stagedShortcut -Target $edgePath -Arguments (Get-EeaArguments $cleanWebsite) -Description ('EasyEdgeApps:' + $paths.Id) -Icon ($paths.Icon + ',0')
                    [pscustomobject]@{ Path = $paths.$slot; Source = $stagedShortcut }
                }
                elseif ($null -ne $previousState -and $previousState.$slot) {
                    [pscustomobject]@{ Path = $paths.$slot; Source = $null }
                }
            }
            $stagedManifest = Join-Path $StagePath 'app.json'
            [IO.File]::WriteAllText($stagedManifest, ($newState | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
            [pscustomobject]@{ Path = $paths.Manifest; Source = $stagedManifest }
        }
        Read-EeaManifest $Context $cleanName
    }
}

function Remove-EeaApp {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true)][string]$AppName, $Context = (Get-EeaContext))

    $cleanName = ConvertTo-EeaName $AppName
    if (-not $PSCmdlet.ShouldProcess($cleanName, 'Remove only Easy Edge Apps shortcuts and settings; keep all browser data')) { return }
    Invoke-EeaLocked {
        Assert-EeaReady $Context
        $state = Read-EeaManifest $Context $cleanName
        if ($null -eq $state) { return }
        $paths = Get-EeaPaths $Context $state.Name
        Assert-EeaOwnership -Paths $paths -State $state -Desktop $false -StartMenu $false
        Invoke-EeaTransaction -Context $Context -Prepare {
            param($StagePath)
            foreach ($slot in @('Desktop', 'StartMenu')) {
                if ($state.$slot) { [pscustomobject]@{ Path = $paths.$slot; Source = $null } }
            }
            [pscustomobject]@{ Path = $paths.Icon; Source = $null }
            [pscustomobject]@{ Path = $paths.Manifest; Source = $null }
        }
        foreach ($directory in @($paths.Directory, $paths.AppsRoot, $Context.Programs, $Context.Root)) {
            Assert-EeaSafePath $directory
            if ([IO.Directory]::Exists($directory) -and [IO.Directory]::GetFileSystemEntries($directory).Length -eq 0) {
                [IO.Directory]::Delete($directory, $false)
            }
        }
    }
}

function Start-EeaApp {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$AppName, $Context = (Get-EeaContext))

    Assert-EeaReady $Context
    $state = Read-EeaManifest $Context $AppName
    if ($null -eq $state) { throw 'This website has not been added yet.' }
    $edgePath = Find-EeaEdge
    if ($PSCmdlet.ShouldProcess($state.Name, 'Open website in Microsoft Edge')) {
        Start-Process -FilePath $edgePath -ArgumentList (Get-EeaArguments $state.Url) -ErrorAction Stop
    }
}

function Get-EeaIconPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $icon = New-Object Drawing.Icon($Path)
    $bitmap = New-Object Drawing.Bitmap(96, 96)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.DrawIcon($icon, (New-Object Drawing.Rectangle(0, 0, 96, 96)))
        return $bitmap
    }
    catch { $bitmap.Dispose(); throw }
    finally { $graphics.Dispose(); $icon.Dispose() }
}

function New-EeaButton {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.AutoSize = $true
    $button.MinimumSize = New-Object Drawing.Size(110, 40)
    $button.Padding = New-Object Windows.Forms.Padding(8, 2, 8, 2)
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $button.UseVisualStyleBackColor = $true
    return $button
}

function Reset-EeaEditor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $ui = $Form.Tag
    $ui.AppList.SelectedIndex = -1
    $ui.NameInput.ReadOnly = $false
    $ui.NameInput.Clear()
    $ui.UrlInput.Clear()
    $ui.DesktopCheck.Checked = $true
    $ui.StartMenuCheck.Checked = $true
    $ui.CustomIcon = $null
    $ui.IconLabel.Text = 'Automatic'
    if ($null -ne $ui.IconPreview.Image) { $ui.IconPreview.Image.Dispose(); $ui.IconPreview.Image = $null }
    $ui.SaveButton.Text = '&Add website'
    $ui.OpenButton.Enabled = $false
    $ui.RemoveButton.Enabled = $false
    [void]$ui.NameInput.Focus()
}

function Update-EeaForm {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [string]$SelectName)

    $ui = $Form.Tag
    $ui.AppList.BeginUpdate()
    try {
        $ui.AppList.Items.Clear()
        foreach ($app in @(Get-EeaApps -Context $ui.Context | Sort-Object Name)) { [void]$ui.AppList.Items.Add($app) }
        Reset-EeaEditor $Form
        if ($SelectName) {
            for ($itemIndex = 0; $itemIndex -lt $ui.AppList.Items.Count; $itemIndex++) {
                if ($ui.AppList.Items[$itemIndex].Name -ieq $SelectName) { $ui.AppList.SelectedIndex = $itemIndex; break }
            }
        }
    }
    finally { $ui.AppList.EndUpdate() }
}

function Show-EeaFormError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [Parameter(Mandatory = $true)]$Failure)

    $Form.Tag.StatusLabel.Text = $Failure.Exception.Message
    [void][Windows.Forms.MessageBox]::Show($Form, $Failure.Exception.Message, 'Could not finish', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
}

function Confirm-EeaChange {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [Parameter(Mandatory = $true)][string]$Message, [Parameter(Mandatory = $true)][string]$Title)

    $answer = [Windows.Forms.MessageBox]::Show($Form, $Message, $Title, [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Question, [Windows.Forms.MessageBoxDefaultButton]::Button2)
    return $answer -eq [Windows.Forms.DialogResult]::Yes
}

function New-EeaSetupForm {
    [CmdletBinding()]
    param($Context = (Get-EeaContext))

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'Open this script with powershell.exe -NoProfile -STA -File .\EasyEdgeApps.ps1 to use the setup window.'
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Easy Edge Apps'
    $form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(880, 620)
    $form.MinimumSize = New-Object Drawing.Size(800, 640)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = [Drawing.SystemColors]::Control
    $form.ForeColor = [Drawing.SystemColors]::ControlText
    $form.Icon = [Drawing.SystemIcons]::Application
    $form.Padding = New-Object Windows.Forms.Padding(20)

    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = [Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $form.Controls.Add($layout)

    $heading = New-Object Windows.Forms.Label
    $heading.Text = 'Easy Edge Apps'
    $heading.Font = New-Object Drawing.Font('Segoe UI', 20, [Drawing.FontStyle]::Bold)
    $heading.AutoSize = $true
    $heading.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 16)
    $layout.Controls.Add($heading, 0, 0)

    $content = New-Object Windows.Forms.TableLayoutPanel
    $content.Dock = [Windows.Forms.DockStyle]::Fill
    $content.ColumnCount = 2
    $content.RowCount = 1
    [void]$content.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 34)))
    [void]$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 66)))
    $layout.Controls.Add($content, 0, 1)

    $listPanel = New-Object Windows.Forms.TableLayoutPanel
    $listPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $listPanel.ColumnCount = 1
    $listPanel.RowCount = 3
    [void]$listPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $listPanel.Margin = New-Object Windows.Forms.Padding(0, 0, 16, 0)
    [void]$listPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$listPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$listPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $listLabel = New-Object Windows.Forms.Label
    $listLabel.Text = '&Websites'
    $listLabel.AutoSize = $true
    $listPanel.Controls.Add($listLabel, 0, 0)
    $appList = New-Object Windows.Forms.ListBox
    $appList.Dock = [Windows.Forms.DockStyle]::Fill
    $appList.IntegralHeight = $false
    $appList.DisplayMember = 'Name'
    $appList.HorizontalScrollbar = $true
    $appList.AccessibleName = 'Saved websites'
    $appList.TabIndex = 1
    $listPanel.Controls.Add($appList, 0, 1)
    $newButton = New-EeaButton '&New website'
    $newButton.TabIndex = 2
    $listPanel.Controls.Add($newButton, 0, 2)
    $content.Controls.Add($listPanel, 0, 0)

    $editorViewport = New-Object Windows.Forms.Panel
    $editorViewport.Dock = [Windows.Forms.DockStyle]::Fill
    $editorViewport.AutoScroll = $true
    $content.Controls.Add($editorViewport, 1, 0)
    $editor = New-Object Windows.Forms.TableLayoutPanel
    $editor.Dock = [Windows.Forms.DockStyle]::Top
    $editor.AutoSize = $true
    $editor.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $editor.ColumnCount = 1
    $editor.RowCount = 8
    [void]$editor.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    for ($rowIndex = 0; $rowIndex -lt 8; $rowIndex++) {
        [void]$editor.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    }
    $editorViewport.Controls.Add($editor)
    $nameLabel = New-Object Windows.Forms.Label
    $nameLabel.Text = '&Name'
    $nameLabel.AutoSize = $true
    $nameLabel.TabIndex = 0
    $editor.Controls.Add($nameLabel, 0, 0)
    $nameInput = New-Object Windows.Forms.TextBox
    $nameInput.Dock = [Windows.Forms.DockStyle]::Top
    $nameInput.MaxLength = 60
    $nameInput.AccessibleName = 'Website name'
    $nameInput.TabIndex = 1
    $nameInput.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $editor.Controls.Add($nameInput, 0, 1)
    $urlLabel = New-Object Windows.Forms.Label
    $urlLabel.Text = 'Website &address'
    $urlLabel.AutoSize = $true
    $urlLabel.TabIndex = 2
    $editor.Controls.Add($urlLabel, 0, 2)
    $urlInput = New-Object Windows.Forms.TextBox
    $urlInput.Dock = [Windows.Forms.DockStyle]::Top
    $urlInput.MaxLength = 2048
    $urlInput.AccessibleName = 'Website address starting with https'
    $urlInput.TabIndex = 3
    $urlInput.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $editor.Controls.Add($urlInput, 0, 3)

    $placement = New-Object Windows.Forms.FlowLayoutPanel
    $placement.AutoSize = $true
    $placement.Dock = [Windows.Forms.DockStyle]::Fill
    $placement.TabIndex = 4
    $desktopCheck = New-Object Windows.Forms.CheckBox
    $desktopCheck.Text = '&Desktop'
    $desktopCheck.AutoSize = $true
    $desktopCheck.Checked = $true
    $desktopCheck.Margin = New-Object Windows.Forms.Padding(0, 0, 20, 8)
    $startMenuCheck = New-Object Windows.Forms.CheckBox
    $startMenuCheck.Text = 'Start &menu'
    $startMenuCheck.AutoSize = $true
    $startMenuCheck.Checked = $true
    $placement.Controls.AddRange([Windows.Forms.Control[]]@($desktopCheck, $startMenuCheck))
    $editor.Controls.Add($placement, 0, 4)

    $iconPanel = New-Object Windows.Forms.FlowLayoutPanel
    $iconPanel.AutoSize = $true
    $iconPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $iconPanel.TabIndex = 5
    $iconPreview = New-Object Windows.Forms.PictureBox
    $iconPreview.Size = New-Object Drawing.Size(48, 48)
    $iconPreview.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $iconPreview.AccessibleName = 'Website icon'
    $iconPreview.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $iconButton = New-EeaButton 'Choose &icon...'
    $clearIconButton = New-EeaButton 'Use &saved icon'
    $iconPanel.Controls.AddRange([Windows.Forms.Control[]]@($iconPreview, $iconButton, $clearIconButton))
    $editor.Controls.Add($iconPanel, 0, 5)
    $iconLabel = New-Object Windows.Forms.Label
    $iconLabel.AutoSize = $true
    $iconLabel.Text = 'Automatic'
    $iconLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 16)
    $editor.Controls.Add($iconLabel, 0, 6)

    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Top
    $actions.TabIndex = 6
    $saveButton = New-EeaButton '&Add website'
    $openButton = New-EeaButton '&Open'
    $removeButton = New-EeaButton '&Remove...'
    $openButton.Enabled = $false
    $removeButton.Enabled = $false
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($saveButton, $openButton, $removeButton))
    $editor.Controls.Add($actions, 0, 7)

    $statusLabel = New-Object Windows.Forms.Label
    $statusLabel.AutoSize = $true
    $statusLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $statusLabel.AccessibleName = 'Status'
    $statusLabel.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 12)
    $statusLabel.Text = 'Ready'
    $layout.Controls.Add($statusLabel, 0, 2)
    $closeButton = New-EeaButton '&Close'
    $closeButton.Anchor = [Windows.Forms.AnchorStyles]::Right
    $closeButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $layout.Controls.Add($closeButton, 0, 3)
    $form.AcceptButton = $saveButton
    $form.CancelButton = $closeButton
    $form.Tag = [pscustomobject]@{
        Context = $Context; AppList = $appList; NameInput = $nameInput; UrlInput = $urlInput
        DesktopCheck = $desktopCheck; StartMenuCheck = $startMenuCheck; CustomIcon = $null
        IconPreview = $iconPreview; IconLabel = $iconLabel; StatusLabel = $statusLabel
        SaveButton = $saveButton; OpenButton = $openButton; RemoveButton = $removeButton
        NewButton = $newButton; CloseButton = $closeButton
        EditorViewport = $editorViewport
    }

    $appList.Add_SelectedIndexChanged({
        param($Sender, $EventArgs)
        if ($Sender.SelectedIndex -lt 0) { return }
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        $selected = $Sender.SelectedItem
        $ui.NameInput.Text = $selected.Name
        $ui.NameInput.ReadOnly = $true
        $ui.UrlInput.Text = $selected.Url
        $ui.DesktopCheck.Checked = $selected.Desktop
        $ui.StartMenuCheck.Checked = $selected.StartMenu
        $ui.CustomIcon = $null
        $ui.IconLabel.Text = 'Saved icon'
        $ui.SaveButton.Text = '&Save changes'
        $ui.OpenButton.Enabled = $true
        $ui.RemoveButton.Enabled = $true
        if ($null -ne $ui.IconPreview.Image) { $ui.IconPreview.Image.Dispose(); $ui.IconPreview.Image = $null }
        $paths = Get-EeaPaths $ui.Context $selected.Name
        if ([IO.File]::Exists($paths.Icon)) {
            try {
                $ui.IconPreview.Image = Get-EeaIconPreview $paths.Icon
            }
            catch { $ui.IconLabel.Text = 'Icon unavailable' }
        }
    })
    $newButton.Add_Click({ param($Sender, $EventArgs) Reset-EeaEditor $Sender.FindForm() })
    $iconButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Windows icons (*.ico)|*.ico'
        $dialog.Title = 'Choose a website icon'
        $dialog.CheckFileExists = $true
        try {
            if ($dialog.ShowDialog($ownerForm) -eq [Windows.Forms.DialogResult]::OK) {
                $null = Read-EeaCustomIcon $dialog.FileName
                $ownerForm.Tag.CustomIcon = $dialog.FileName
                $ownerForm.Tag.IconLabel.Text = [IO.Path]::GetFileName($dialog.FileName)
            }
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally { $dialog.Dispose() }
    })
    $clearIconButton.Add_Click({
        param($Sender, $EventArgs)
        $ui = $Sender.FindForm().Tag
        $ui.CustomIcon = $null
        $ui.IconLabel.Text = if ($ui.AppList.SelectedIndex -ge 0) { 'Saved icon' } else { 'Automatic' }
    })
    $saveButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        try {
            $cleanName = ConvertTo-EeaName $ui.NameInput.Text
            if ($ui.AppList.SelectedIndex -lt 0 -and $null -ne (Read-EeaManifest $ui.Context $cleanName)) {
                if (-not (Confirm-EeaChange $ownerForm ('Replace the address and shortcut settings for "' + $cleanName + '"?') 'Update existing website?')) { return }
            }
            $ownerForm.UseWaitCursor = $true
            $ui.SaveButton.Enabled = $false
            $ui.StatusLabel.Text = 'Saving...'
            $ui.StatusLabel.Refresh()
            $installed = Install-EeaApp -AppName $cleanName -Website $ui.UrlInput.Text -CustomIcon $ui.CustomIcon -Desktop $ui.DesktopCheck.Checked -StartMenu $ui.StartMenuCheck.Checked -Context $ui.Context -Confirm:$false
            Update-EeaForm -Form $ownerForm -SelectName $installed.Name
            $ui.StatusLabel.Text = 'Saved: ' + $installed.Name
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally { $ownerForm.UseWaitCursor = $false; $ui.SaveButton.Enabled = $true }
    })
    $openButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        try { Start-EeaApp -AppName $ownerForm.Tag.NameInput.Text -Context $ownerForm.Tag.Context -Confirm:$false }
        catch { Show-EeaFormError $ownerForm $_ }
    })
    $removeButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        if (-not (Confirm-EeaChange $ownerForm ('Remove the shortcuts for "' + $ui.NameInput.Text + '"? Your website account, passwords, and browser data will stay.') 'Remove website shortcuts?')) { return }
        try {
            $removedName = $ui.NameInput.Text
            Remove-EeaApp -AppName $removedName -Context $ui.Context -Confirm:$false
            Update-EeaForm $ownerForm
            $ui.StatusLabel.Text = 'Removed shortcuts: ' + $removedName
        }
        catch { Show-EeaFormError $ownerForm $_ }
    })
    $form.Add_FormClosed({
        param($Sender, $EventArgs)
        if ($null -ne $Sender.Tag.IconPreview.Image) { $Sender.Tag.IconPreview.Image.Dispose() }
    })
    try { Update-EeaForm $form }
    catch { $form.Dispose(); throw }
    return $form
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        if ($env:OS -ne 'Windows_NT') { throw 'Easy Edge Apps needs Windows and Microsoft Edge.' }
        if (-not $PSBoundParameters.ContainsKey('Action') -and $Name -and $Url) { $Action = 'Install' }
        switch ($Action) {
            'Setup' {
                if ($Quiet -or $Name -or $Url -or $IconPath -or $NoDesktop -or $NoStartMenu -or $Launch) {
                    throw 'Run without parameters for the setup window, or use -Action Install with -Name and -Url.'
                }
                if ($PSCmdlet.ShouldProcess('Easy Edge Apps', 'Open the setup window')) {
                    $setupForm = New-EeaSetupForm
                    try { [void]$setupForm.ShowDialog() }
                    finally { $setupForm.Dispose() }
                }
            }
            'Install' {
                if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Url)) {
                    throw 'Provide both -Name and -Url when using -Action Install.'
                }
                $installedApp = Install-EeaApp -AppName $Name -Website $Url -CustomIcon $IconPath -Desktop (-not $NoDesktop) -StartMenu (-not $NoStartMenu)
                if ($null -ne $installedApp) {
                    if (-not $Quiet) { Write-Host ('Saved website shortcuts: ' + $installedApp.Name) }
                    if ($Launch) { Start-EeaApp -AppName $installedApp.Name }
                }
            }
            'List' { Get-EeaApps | Select-Object Name, Url, Desktop, StartMenu }
            'Remove' {
                if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Provide -Name when using -Action Remove.' }
                Remove-EeaApp -AppName $Name
                if (-not $Quiet -and -not $WhatIfPreference) { Write-Host ('Removed managed shortcuts, if present: ' + $Name) }
            }
            'Open' {
                if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Provide -Name when using -Action Open.' }
                Start-EeaApp -AppName $Name
            }
        }
    }
    catch {
        if ($Action -eq 'Setup' -and -not $Quiet -and -not $WhatIfPreference) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Easy Edge Apps', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning)
            }
            catch { }
        }
        [Console]::Error.WriteLine('Easy Edge Apps: ' + $_.Exception.Message)
        exit 1
    }
}