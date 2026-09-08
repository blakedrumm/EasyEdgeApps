#requires -Version 5.1

<#
.SYNOPSIS
Creates easy-to-find, per-user Microsoft Edge website shortcuts on Windows 11.
.DESCRIPTION
Run without parameters for the setup window. Command-line actions also support
App Kits, Check, Repair, ListFavorites, and ImportFavorites.
No administrator rights, external modules, dependency downloads,
browser policy changes, or persistent execution-policy changes are required.
Setup can retrieve a website icon over HTTPS when explicitly requested.
.PARAMETER Help
Display command-line help without opening setup or performing an operation.
Accepts -Help, -h, and --help. PowerShell also provides the native -? help option.
.PARAMETER Unattended
Explicitly approve the selected command-line operation without setup dialogs or
confirmation prompts. Retains validation, ownership checks, and WhatIf. Routine
host messages are suppressed; results remain PowerShell objects. Success exits
with code 0, and errors, conflicts, or failed applications exit with code 1.
.PARAMETER AppNames
Select named apps for export, kit import, repair, or Favorites import. An explicit
empty selection is rejected. Omit this option to export all saved apps or import
all apps in a kit; repair still requires a selection.
.PARAMETER Quiet
Suppress routine messages and formatted previews, retaining result objects,
errors, warnings, and WhatIf output. Does not approve changes by itself.
.EXAMPLE
.\EasyEdgeApps.ps1
.EXAMPLE
.\EasyEdgeApps.ps1 --help
.EXAMPLE
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/'
.EXAMPLE
.\EasyEdgeApps.ps1 -Action Remove -Name 'My Mail' -WhatIf
.EXAMPLE
.\EasyEdgeApps.ps1 -Action ExportKit -Path '.\Family.eeakit.json' -Unattended
.EXAMPLE
.\EasyEdgeApps.ps1 -Action ImportKit -Path '.\Family.eeakit.json' -AppNames 'My Mail' -Unattended
.NOTES
Version: 1.2.0
.LINK
https://github.com/blakedrumm/EasyEdgeApps
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Setup', 'Install', 'List', 'Remove', 'Open', 'ExportKit', 'ImportKit', 'Check', 'Repair', 'ListFavorites', 'ImportFavorites', '--help')]
    [string]$Action = 'Setup',
    [string]$Name,
    [string]$Url,
    [string]$IconPath,
    [string]$Notes,
    [string]$Path,
    [string]$KitName = 'My websites',
    [ValidateNotNullOrEmpty()]
    [string[]]$AppNames,
    [string]$EdgeProfile,
    [string]$EdgeUserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
    [switch]$Protected,
    [Security.SecureString]$Password,
    [Security.SecureString]$PasswordConfirmation,
    [switch]$Preview,
    [switch]$Replace,
    [switch]$NoDesktop,
    [switch]$NoStartMenu,
    [switch]$Launch,
    [switch]$Unattended,
    [switch]$Quiet,
    [Alias('h', '-help')]
    [switch]$Help
)

function ConvertFrom-EeaJsonElement {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][Xml.XmlElement]$Element)

    if ($Element.HasAttribute('__type')) { throw 'JSON type metadata is not supported.' }
    switch ($Element.GetAttribute('type')) {
        'object' {
            $value = [pscustomobject]@{}
            foreach ($child in $Element.ChildNodes) {
                $propertyName = if ($child.NamespaceURI -ceq 'item') { $child.GetAttribute('item') } else { $child.LocalName }
                if ($null -ne $value.PSObject.Properties[$propertyName]) { throw 'Duplicate JSON field names are not supported.' }
                $propertyValue = ConvertFrom-EeaJsonElement $child
                $value.PSObject.Properties.Add((New-Object Management.Automation.PSNoteProperty($propertyName, $propertyValue)))
            }
            return $value
        }
        'array' {
            $values = New-Object 'Collections.Generic.List[object]'
            foreach ($child in $Element.ChildNodes) { $values.Add((ConvertFrom-EeaJsonElement $child)) }
            return ,$values.ToArray()
        }
        'string' { return [string]$Element.InnerText }
        'null' { return $null }
        'boolean' {
            if ($Element.InnerText -ceq 'true') { return $true }
            if ($Element.InnerText -ceq 'false') { return $false }
            throw 'Invalid JSON Boolean.'
        }
        'number' {
            if ($Element.InnerText -cnotmatch '\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z') { throw 'Invalid JSON number.' }
            $integer = 0L
            if ([long]::TryParse($Element.InnerText, [Globalization.NumberStyles]::AllowLeadingSign, [Globalization.CultureInfo]::InvariantCulture, [ref]$integer)) {
                if ($integer -ge [int]::MinValue -and $integer -le [int]::MaxValue) { return [int]$integer }
                return $integer
            }
            $number = 0.0
            if ([double]::TryParse($Element.InnerText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
                -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) { return $number }
            throw 'The JSON number is outside supported limits.'
        }
        default { throw 'Unsupported JSON value.' }
    }
}

function ConvertFrom-EeaJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateRange(4, 256)][int]$MaximumDepth = 16,
        [ValidateRange(1024, 250000)][int]$MaximumValues = 4096
    )

    if ($Text.Length -gt 24MB) { throw 'The JSON document exceeds the size limit.' }
    Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction Stop
    $quotas = New-Object Xml.XmlDictionaryReaderQuotas
    $quotas.MaxDepth = $MaximumDepth
    $quotas.MaxArrayLength = 24MB
    $quotas.MaxStringContentLength = 24MB
    $quotas.MaxNameTableCharCount = 1MB
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($Text)
    $reader = $null
    try {
        $reader = [Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($bytes, $quotas)
        $valueCount = 0
        while ($reader.Read()) {
            if ($reader.NodeType -eq [Xml.XmlNodeType]::Element) {
                $valueCount++
                if ($valueCount -gt $MaximumValues) { throw 'The JSON document contains too many values.' }
            }
        }
        $reader.Dispose()
        $reader = $null
        $syntaxToken = [regex]::Match($Text, '"(?>[^"\\]+|\\.)*"|,\s*[}\]]', [Text.RegularExpressions.RegexOptions]::Singleline, [TimeSpan]::FromSeconds(2))
        while ($syntaxToken.Success) {
            if ($Text[$syntaxToken.Index] -eq ',') { throw 'Trailing JSON commas are not supported.' }
            $syntaxToken = $syntaxToken.NextMatch()
        }
        $reader = [Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($bytes, $quotas)
        $document = New-Object Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        return ConvertFrom-EeaJsonElement $document.DocumentElement
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

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
    $canonicalWebsite = $builder.Uri.AbsoluteUri
    if ($canonicalWebsite.Length -gt 2048) { throw 'Use a website address that remains within 2048 characters after URL encoding.' }
    return $canonicalWebsite
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

function ConvertTo-EeaNotes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 4000 -or $Value -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\p{Cf}]') {
        throw 'Use plain-text helper notes of at most 4000 characters, without hidden control characters.'
    }
    return $Value
}

function Get-EeaByteHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
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

function Read-EeaEdgeJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-EeaSafePath $Path
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -lt 2 -or $stream.Length -gt 16MB) { throw 'The Edge data file is empty or too large.' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $readCount = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($readCount -eq 0) { throw 'Edge data changed while being read.' }
            $offset += $readCount
        }
        if ($stream.ReadByte() -ne -1) { throw 'Edge data changed while being read.' }
        $jsonText = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
        if ($jsonText.Length -gt 0 -and $jsonText[0] -eq [char]0xfeff) { $jsonText = $jsonText.Substring(1) }
        return ConvertFrom-EeaJson -Text $jsonText -MaximumDepth 256 -MaximumValues 250000
    }
    catch { throw 'The Edge data could not be read. Close Edge and try again. No favorites were changed.' }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-EeaEdgeProfiles {
    [CmdletBinding()]
    param([string]$UserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'))

    Assert-EeaSafePath $UserDataPath
    if (-not [IO.Directory]::Exists($UserDataPath)) { return }
    $profileInfo = $null
    $lastUsed = ''
    $localStatePath = Join-Path $UserDataPath 'Local State'
    if ([IO.File]::Exists($localStatePath)) {
        try {
            $localState = Read-EeaEdgeJson $localStatePath
            if ($null -ne $localState.PSObject.Properties['profile']) {
                if ($null -ne $localState.profile.PSObject.Properties['info_cache']) { $profileInfo = $localState.profile.info_cache }
                if ($null -ne $localState.profile.PSObject.Properties['last_used']) { $lastUsed = [string]$localState.profile.last_used }
            }
        }
        catch { Write-Warning 'Edge profile names are unavailable. Folder names will be shown instead.' }
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $UserDataPath -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        if ($directory.Name -cnotmatch '^(Default|Profile [0-9]+)$') { continue }
        if (-not [IO.File]::Exists((Join-Path $directory.FullName 'Bookmarks'))) { continue }
        $displayName = $directory.Name
        if ($null -ne $profileInfo -and $null -ne $profileInfo.PSObject.Properties[$directory.Name]) {
            $cachedProfile = $profileInfo.PSObject.Properties[$directory.Name].Value
            if ($null -ne $cachedProfile -and $null -ne $cachedProfile.PSObject.Properties['name'] -and $cachedProfile.name -is [string]) {
                $profileName = [regex]::Replace($cachedProfile.name, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ').Trim()
                if ($profileName.Length -gt 80) { $profileName = $profileName.Substring(0, 80) }
                if ($profileName) { $displayName = $profileName + ' (' + $directory.Name + ')' }
            }
        }
        [pscustomobject]@{ DirectoryName = $directory.Name; DisplayName = $displayName; IsLastUsed = ($directory.Name -ceq $lastUsed) }
    }
}

function ConvertTo-EeaFavoriteName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Title, [Parameter(Mandatory = $true)][string]$Website)

    $candidate = [regex]::Replace($Title.Normalize([Text.NormalizationForm]::FormC), '[<>:"/\\|?*\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ')
    $candidate = [regex]::Replace($candidate, '\s+', ' ').Trim().TrimEnd('.').Trim()
    if (-not $candidate) { $candidate = ([Uri]$Website).IdnHost }
    if ($candidate.Length -gt 60) {
        $candidate = $candidate.Substring(0, 60)
        if ([char]::IsHighSurrogate($candidate[$candidate.Length - 1])) { $candidate = $candidate.Substring(0, $candidate.Length - 1) }
        $candidate = $candidate.Trim().TrimEnd('.').Trim()
    }
    if ($candidate -match '^(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\..*)?$') { $candidate = 'Website ' + $candidate }
    return ConvertTo-EeaName $candidate
}

function Get-EeaEdgeFavorites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^(Default|Profile [0-9]+)$')][string]$ProfileDirectory,
        [string]$UserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')
    )

    $bookmarkPath = Join-Path (Join-Path $UserDataPath $ProfileDirectory) 'Bookmarks'
    $bookmarks = Read-EeaEdgeJson $bookmarkPath
    if ($null -eq $bookmarks -or $null -eq $bookmarks.PSObject.Properties['roots'] -or
        $null -eq $bookmarks.roots -or $null -eq $bookmarks.roots.PSObject.Properties['bookmark_bar']) {
        throw 'This Edge profile has no readable Favorites bar. No favorites were changed.'
    }
    $bar = $bookmarks.roots.bookmark_bar
    if ($null -eq $bar -or $null -eq $bar.PSObject.Properties['type'] -or $bar.type -cne 'folder') { throw 'This Edge profile has no readable Favorites bar.' }
    $pending = New-Object 'Collections.Generic.Stack[object]'
    $entries = New-Object 'Collections.Generic.List[object]'
    $pending.Push([pscustomobject]@{ Node = $bookmarks.roots.bookmark_bar; Folder = ''; Depth = 0 })
    $nodeCount = 0
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $node = $current.Node
        $nodeCount++
        if ($nodeCount -gt 10000 -or $current.Depth -gt 64) { throw 'This Favorites bar is too large or has too many nested folders.' }
        if ($null -eq $node -or $null -eq $node.PSObject.Properties['type']) { throw 'An Edge favorite is damaged. No favorites were changed.' }
        if ($node.type -ceq 'folder') {
            if ($null -eq $node.PSObject.Properties['children'] -or $node.children -isnot [Array]) { throw 'An Edge favorites folder is damaged. No favorites were changed.' }
            if ($node.children.Count + $pending.Count + $nodeCount -gt 10000) { throw 'This Favorites bar has too many items.' }
            $folder = $current.Folder
            if ($current.Depth -gt 0 -and $null -ne $node.PSObject.Properties['name'] -and $node.name -is [string]) {
                $folderName = [regex]::Replace($node.name, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ')
                if ($folderName.Length -gt 256) { $folderName = $folderName.Substring(0, 256) }
                $folder = if ($folder) { $folder + ' / ' + $folderName } else { $folderName }
                if ($folder.Length -gt 1024) { $folder = $folder.Substring(0, 1024) }
            }
            for ($childIndex = $node.children.Count - 1; $childIndex -ge 0; $childIndex--) {
                $pending.Push([pscustomobject]@{ Node = $node.children[$childIndex]; Folder = $folder; Depth = $current.Depth + 1 })
            }
        }
        else {
            $title = if ($null -ne $node.PSObject.Properties['name'] -and $node.name -is [string]) { $node.name } else { '' }
            $website = if ($null -ne $node.PSObject.Properties['url'] -and $node.url -is [string]) { $node.url } else { '' }
            $appName = $title
            $canImport = $false
            $reason = 'Only complete https:// website addresses can be added.'
            if ($node.type -ceq 'url') {
                try {
                    $website = ConvertTo-EeaWebsite $website
                    $appName = ConvertTo-EeaFavoriteName -Title $title -Website $website
                    $canImport = $true
                    $reason = 'Available'
                }
                catch { }
            }
            $title = [regex]::Replace($title, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ')
            if ($title.Length -gt 256) { $title = $title.Substring(0, 256) }
            if (-not $canImport) {
                $appName = $title
                if ($website.Length -gt 2048) { $website = $website.Substring(0, 2048) }
                $website = [regex]::Replace($website, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ')
            }
            $entries.Add([pscustomobject]@{
                Title = $title; Name = $appName; Url = $website; Folder = $current.Folder
                ProfileDirectory = $ProfileDirectory; CanImport = $canImport; Status = $reason
            })
        }
    }
    return $entries.ToArray()
}

function Get-EeaFavoriteChoices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileDirectory,
        [string]$UserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
        $Context = (Get-EeaContext)
    )

    $apps = @(Get-EeaApps -Context $Context)
    $usedNames = New-Object 'Collections.Generic.HashSet[string]'
    $savedUrls = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $listedUrls = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($app in $apps) { [void]$usedNames.Add($app.Id); [void]$savedUrls.Add($app.Url) }
    foreach ($favorite in @(Get-EeaEdgeFavorites -ProfileDirectory $ProfileDirectory -UserDataPath $UserDataPath)) {
        if ($favorite.CanImport) {
            if ($savedUrls.Contains($favorite.Url)) { $favorite.CanImport = $false; $favorite.Status = 'Already added' }
            elseif (-not $listedUrls.Add($favorite.Url)) { $favorite.CanImport = $false; $favorite.Status = 'Duplicate website in this Favorites bar' }
            else {
                $baseName = $favorite.Name
                $candidate = $baseName
                $suffixNumber = 1
                while ($true) {
                    $paths = Get-EeaPaths $Context $candidate
                    if (-not $usedNames.Contains($paths.Id) -and -not (Test-Path -LiteralPath $paths.Desktop) -and
                        -not (Test-Path -LiteralPath $paths.StartMenu) -and -not (Test-Path -LiteralPath $paths.Directory)) { break }
                    $suffixNumber++
                    if ($suffixNumber -gt 10000) { throw 'Too many websites share a shortcut name. Rename some favorites and try again.' }
                    $suffix = ' (' + $suffixNumber + ')'
                    $prefix = $baseName.Substring(0, [Math]::Min($baseName.Length, 60 - $suffix.Length))
                    if ([char]::IsHighSurrogate($prefix[$prefix.Length - 1])) { $prefix = $prefix.Substring(0, $prefix.Length - 1) }
                    $candidate = ConvertTo-EeaName ($prefix.TrimEnd() + $suffix)
                }
                $favorite.Name = $candidate
                [void]$usedNames.Add($paths.Id)
                if ($candidate -cne $baseName) { $favorite.Status = 'Available with a different shortcut name' }
            }
        }
        $favorite
    }
}

function New-EeaFavoritesKit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Favorites, [bool]$Desktop = $true, [bool]$StartMenu = $true)

    $apps = @(foreach ($favorite in $Favorites) {
        if ($favorite.CanImport -isnot [bool] -or -not $favorite.CanImport) { throw 'Choose only available HTTPS favorites.' }
        [pscustomobject]@{ Name = $favorite.Name; Url = $favorite.Url; Desktop = $Desktop; StartMenu = $StartMenu; Notes = ''; Icon = [pscustomobject]@{ Kind = 'Generated'; Version = 1 } }
    })
    return ConvertTo-EeaKit ([pscustomobject]@{ Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = 'Edge Favorites bar'; Notes = ''; Apps = $apps })
}

function Read-EeaManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$AppName)

    $paths = Get-EeaPaths $Context $AppName
    Assert-EeaSafePath $paths.Manifest
    if (-not [IO.File]::Exists($paths.Manifest)) { return $null }
    try {
        if ((Get-Item -LiteralPath $paths.Manifest -Force).Length -gt 32768) { throw 'Settings are too large.' }
        $state = ConvertFrom-EeaJson ([IO.File]::ReadAllText($paths.Manifest, [Text.Encoding]::UTF8))
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
        if ($null -ne $state.PSObject.Properties['Notes'] -and
            ($state.Notes -isnot [string] -or $state.Notes -cne (ConvertTo-EeaNotes $state.Notes))) { throw 'Invalid helper notes.' }
        if ($null -ne $state.PSObject.Properties['IconKind'] -and $state.IconKind -cnotin @('Generated', 'Custom')) { throw 'Invalid icon kind.' }
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
            $summary = ConvertFrom-EeaJson ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8))
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

function Assert-EeaIconData {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [switch]$StructureOnly)

    if ($Bytes.Length -lt 22 -or $Bytes.Length -gt 1MB -or
        [BitConverter]::ToUInt16($Bytes, 0) -ne 0 -or [BitConverter]::ToUInt16($Bytes, 2) -ne 1) {
        throw 'Choose a valid Windows .ico picture no larger than 1 MB.'
    }
    $imageCount = [BitConverter]::ToUInt16($Bytes, 4)
    if ($imageCount -lt 1 -or $imageCount -gt 32 -or 6 + 16 * $imageCount -gt $Bytes.Length) { throw 'Invalid icon directory.' }
    for ($imageIndex = 0; $imageIndex -lt $imageCount; $imageIndex++) {
        $entryOffset = 6 + 16 * $imageIndex
        $imageLength = [BitConverter]::ToUInt32($Bytes, $entryOffset + 8)
        $imageOffset = [BitConverter]::ToUInt32($Bytes, $entryOffset + 12)
        if ($imageLength -lt 40 -or $imageOffset -lt 6 + 16 * $imageCount -or
            [long]$imageOffset + $imageLength -gt $Bytes.Length) { throw 'Invalid icon image bounds.' }
        $width = if ($Bytes[$entryOffset] -eq 0) { 256 } else { [int]$Bytes[$entryOffset] }
        $height = if ($Bytes[$entryOffset + 1] -eq 0) { 256 } else { [int]$Bytes[$entryOffset + 1] }
        if ([BitConverter]::ToString($Bytes, $imageOffset, 8) -ceq '89-50-4E-47-0D-0A-1A-0A') {
            if ([BitConverter]::ToString($Bytes, $imageOffset + 8, 8) -cne '00-00-00-0D-49-48-44-52') { throw 'Invalid PNG icon header.' }
            $widthBytes = [byte[]]$Bytes[($imageOffset + 16)..($imageOffset + 19)]
            $heightBytes = [byte[]]$Bytes[($imageOffset + 20)..($imageOffset + 23)]
            if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($widthBytes); [Array]::Reverse($heightBytes) }
            if ([BitConverter]::ToUInt32($widthBytes, 0) -ne $width -or [BitConverter]::ToUInt32($heightBytes, 0) -ne $height) { throw 'Invalid PNG icon dimensions.' }
        }
        elseif ([BitConverter]::ToUInt32($Bytes, $imageOffset) -notin @(40, 108, 124) -or
            [BitConverter]::ToInt32($Bytes, $imageOffset + 4) -ne $width -or
            [BitConverter]::ToInt32($Bytes, $imageOffset + 8) -ne 2 * $height) { throw 'Invalid bitmap icon dimensions.' }
    }
    if ($StructureOnly) { return }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $stream = New-Object IO.MemoryStream(,$Bytes)
    $icon = $null
    $bitmap = $null
    $graphics = $null
    try {
        $icon = New-Object Drawing.Icon($stream)
        $bitmap = New-Object Drawing.Bitmap(32, 32)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.DrawIcon($icon, (New-Object Drawing.Rectangle(0, 0, 32, 32)))
    }
    catch { throw 'The icon could not be decoded on this computer. Choose another .ico picture.' }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $icon) { $icon.Dispose() }
        $stream.Dispose()
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
    $iconStream = [IO.File]::OpenRead($resolvedPath)
    try {
        if ($iconStream.Length -gt 1MB) { throw 'Choose a local .ico picture no larger than 1 MB.' }
        $bytes = New-Object byte[] $iconStream.Length
        $bytesRead = $iconStream.Read($bytes, 0, $bytes.Length)
        if ($bytesRead -ne $bytes.Length) { throw 'The icon could not be read completely.' }
        Assert-EeaIconData $bytes
        return ,$bytes
    }
    finally {
        $iconStream.Dispose()
    }
}

function ConvertTo-EeaWebsiteIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -lt 24 -or $Bytes.Length -gt 1MB) { throw 'The website icon must be an ICO or PNG image no larger than 1 MB.' }
    $imageBytes = $Bytes
    if ([BitConverter]::ToUInt32($Bytes, 0) -eq 65536) {
        Assert-EeaIconData $Bytes -StructureOnly
        $bestEntry = 6
        $bestArea = 0
        for ($entry = 6; $entry -lt 6 + 16 * [BitConverter]::ToUInt16($Bytes, 4); $entry += 16) {
            $width = if ($Bytes[$entry] -eq 0) { 256 } else { [int]$Bytes[$entry] }
            $height = if ($Bytes[$entry + 1] -eq 0) { 256 } else { [int]$Bytes[$entry + 1] }
            if ($width * $height -gt $bestArea) { $bestEntry = $entry; $bestArea = $width * $height }
        }
        $imageOffset = [int][BitConverter]::ToUInt32($Bytes, $bestEntry + 12)
        $imageLength = [int][BitConverter]::ToUInt32($Bytes, $bestEntry + 8)
        if ([BitConverter]::ToString($Bytes, $imageOffset, 8) -ceq '89-50-4E-47-0D-0A-1A-0A') {
            $imageBytes = New-Object byte[] $imageLength
            [Array]::Copy($Bytes, $imageOffset, $imageBytes, 0, $imageLength)
        }
        else {
            $imageBytes = New-Object byte[] (22 + $imageLength)
            [Array]::Copy($Bytes, 0, $imageBytes, 0, 6)
            $imageBytes[4] = 1
            $imageBytes[5] = 0
            [Array]::Copy($Bytes, $bestEntry, $imageBytes, 6, 16)
            [Array]::Copy([BitConverter]::GetBytes([uint32]22), 0, $imageBytes, 18, 4)
            [Array]::Copy($Bytes, $imageOffset, $imageBytes, 22, $imageLength)
        }
    }
    $isPng = [BitConverter]::ToString($imageBytes, 0, 8) -ceq '89-50-4E-47-0D-0A-1A-0A'
    if ($isPng) {
        if ([BitConverter]::ToString($imageBytes, 8, 8) -cne '00-00-00-0D-49-48-44-52') { throw 'Invalid website PNG header.' }
        foreach ($dimensionOffset in @(16, 20)) {
            $dimension = [byte[]]$imageBytes[$dimensionOffset..($dimensionOffset + 3)]
            if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($dimension) }
            $length = [BitConverter]::ToUInt32($dimension, 0)
            if ($length -lt 1 -or $length -gt 1024) { throw 'Website icon dimensions must be between 1 and 1024 pixels.' }
        }
    }
    else { Assert-EeaIconData $imageBytes }
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $inputStream = New-Object IO.MemoryStream(,$imageBytes)
    $outputStream = New-Object IO.MemoryStream
    $image = $null
    $icon = $null
    $bitmap = $null
    $graphics = $null
    $writer = $null
    try {
        if ($isPng) { $image = [Drawing.Image]::FromStream($inputStream, $false, $true) }
        else { $icon = New-Object Drawing.Icon($inputStream); $image = $icon.ToBitmap() }
        $bitmap = New-Object Drawing.Bitmap(128, 128, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $scale = [Math]::Min(128.0 / $image.Width, 128.0 / $image.Height)
        $width = [Math]::Max(1, [int]($image.Width * $scale))
        $height = [Math]::Max(1, [int]($image.Height * $scale))
        $graphics.DrawImage($image, (New-Object Drawing.Rectangle(([int]((128 - $width) / 2)), ([int]((128 - $height) / 2)), $width, $height)))
        $graphics.Flush()
        $pixelBytes = New-Object byte[] (128 * 128 * 4)
        $maskBytes = New-Object byte[] (16 * 128)
        $data = $bitmap.LockBits((New-Object Drawing.Rectangle(0, 0, 128, 128)), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            for ($row = 0; $row -lt 128; $row++) {
                [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $row * $data.Stride), $pixelBytes, (127 - $row) * 512, 512)
            }
        }
        finally { $bitmap.UnlockBits($data) }
        for ($pixel = 0; $pixel -lt 128 * 128; $pixel++) {
            if ($pixelBytes[$pixel * 4 + 3] -eq 0) {
                $maskOffset = [int][Math]::Floor($pixel / 8.0)
                $maskBytes[$maskOffset] = $maskBytes[$maskOffset] -bor (128 -shr ($pixel % 8))
            }
        }
        $writer = New-Object IO.BinaryWriter($outputStream)
        foreach ($value in @(0, 1, 1)) { $writer.Write([uint16]$value) }
        foreach ($value in @(128, 128, 0, 0)) { $writer.Write([byte]$value) }
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32](40 + $pixelBytes.Length + $maskBytes.Length))
        $writer.Write([uint32]22)
        $writer.Write([uint32]40)
        $writer.Write([int32]128)
        $writer.Write([int32]256)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]0)
        $writer.Write([uint32]($pixelBytes.Length + $maskBytes.Length))
        foreach ($value in @(0, 0, 0, 0)) { $writer.Write([uint32]$value) }
        $writer.Write($pixelBytes)
        $writer.Write($maskBytes)
        $writer.Flush()
        $result = $outputStream.ToArray()
        Assert-EeaIconData $result
        return ,$result
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $image) { $image.Dispose() }
        if ($null -ne $icon) { $icon.Dispose() }
        $inputStream.Dispose()
        $outputStream.Dispose()
    }
}

function Get-EeaWebsiteIconCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][uri]$PageUri, [AllowEmptyString()][string]$Html = '')

    $pageAddress = [uri](ConvertTo-EeaWebsite $PageUri.AbsoluteUri)
    if ($Html.Length -gt 512KB) { throw 'The website page exceeds the icon lookup limit.' }
    $tagPattern = '<!--.*?(?:-->|$)|<(script|style|textarea|title)\b[^>]*>.*?(?:</\1\s*>|$)|<(?<kind>base|link)\b(?<attributes>(?:"[^"]*"|''[^'']*''|[^''">])*)>'
    $attributePattern = '(?:^|\s+)(?<name>[^\s"''<>/=]+)(?:\s*=\s*(?:"(?<value>[^"]*)"|''(?<value>[^'']*)''|(?<value>[^\s"''=<>`]+)))?'
    $options = [Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline, CultureInvariant'
    $timeout = [TimeSpan]::FromMilliseconds(250)
    $tag = [regex]::Match($Html, $tagPattern, $options, $timeout)
    $links = New-Object 'Collections.Generic.List[string]'
    $baseAddress = $pageAddress
    $baseFound = $false
    $tagCount = 0
    while ($tag.Success -and $tagCount -lt 128) {
        $tagCount++
        if ($tag.Groups['kind'].Success) {
            $attributes = @{}
            foreach ($attribute in [regex]::Matches($tag.Groups['attributes'].Value, $attributePattern, $options, $timeout)) {
                $key = $attribute.Groups['name'].Value
                if (-not $attributes.ContainsKey($key)) { $attributes[$key] = [Net.WebUtility]::HtmlDecode($attribute.Groups['value'].Value) }
            }
            if ($attributes.ContainsKey('href')) {
                $href = $attributes['href'].Trim()
                if ($tag.Groups['kind'].Value -ieq 'base' -and -not $baseFound) {
                    $baseFound = $true
                    try { $baseAddress = [uri](ConvertTo-EeaWebsite (New-Object Uri($pageAddress, $href)).AbsoluteUri) }
                    catch { $baseAddress = $pageAddress }
                }
                elseif ($tag.Groups['kind'].Value -ieq 'link' -and $attributes.ContainsKey('rel')) {
                    $relations = $attributes['rel'] -split '\s+'
                    if (($relations -contains 'icon' -or $relations -contains 'apple-touch-icon' -or $relations -contains 'apple-touch-icon-precomposed') -and
                        $attributes['type'] -ine 'image/svg+xml' -and $href -notmatch '[\p{Cc}\p{Cf}\\]') {
                        $links.Add($href)
                    }
                }
            }
        }
        $tag = $tag.NextMatch()
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $candidates = New-Object 'Collections.Generic.List[string]'
    foreach ($href in $links) {
        try {
            $address = [uri](ConvertTo-EeaWebsite (New-Object Uri($baseAddress, $href)).AbsoluteUri)
            if ($address.AbsolutePath -match '\.(svg|gif|jpe?g|webp)$') { continue }
            if ($seen.Add($address.AbsoluteUri)) { $candidates.Add($address.AbsoluteUri) }
            if ($candidates.Count -ge 5) { break }
        }
        catch { continue }
    }
    $fallback = (New-Object Uri($pageAddress, '/favicon.ico')).AbsoluteUri
    if ($seen.Add($fallback)) { $candidates.Add($fallback) }
    return $candidates.ToArray()
}

function Get-EeaWebsiteResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Website,
        [Parameter(Mandatory = $true)][ValidateRange(1, 1048576)][int]$MaximumBytes,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )

    $address = [uri](ConvertTo-EeaWebsite $Website)
    $requestCancellation = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken, [Threading.CancellationToken]::None)
    $requestCancellation.CancelAfter(8000)
    try {
        for ($redirect = 0; $redirect -le 3; $redirect++) {
            $requestCancellation.Token.ThrowIfCancellationRequested()
            $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $address)
            $response = $null
            $stream = $null
            $buffer = New-Object IO.MemoryStream
            try {
                $response = $Client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $requestCancellation.Token).GetAwaiter().GetResult()
                if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                    if ($redirect -eq 3 -or $null -eq $response.Headers.Location) { throw 'Too many website redirects or a missing redirect address.' }
                    $address = [uri](ConvertTo-EeaWebsite (New-Object Uri($address, $response.Headers.Location)).AbsoluteUri)
                    continue
                }
                $null = $response.EnsureSuccessStatusCode()
                if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $MaximumBytes) { throw 'The website response exceeds the icon lookup size limit.' }
                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $chunk = New-Object byte[] 8192
                while ($true) {
                    $requestCancellation.Token.ThrowIfCancellationRequested()
                    $count = $stream.ReadAsync($chunk, 0, $chunk.Length, $requestCancellation.Token).GetAwaiter().GetResult()
                    if ($count -eq 0) { break }
                    if ($buffer.Length + $count -gt $MaximumBytes) { throw 'The website response exceeds the icon lookup size limit.' }
                    $buffer.Write($chunk, 0, $count)
                }
                $mediaType = ''
                $characterSet = ''
                if ($null -ne $response.Content.Headers.ContentType) {
                    $mediaType = $response.Content.Headers.ContentType.MediaType
                    $characterSet = $response.Content.Headers.ContentType.CharSet
                }
                return [pscustomobject]@{ Uri = $address; Bytes = $buffer.ToArray(); MediaType = $mediaType; CharacterSet = $characterSet }
            }
            finally {
                $buffer.Dispose()
                if ($null -ne $stream) { $stream.Dispose() }
                if ($null -ne $response) { $response.Dispose() }
                $request.Dispose()
            }
        }
    }
    finally { $requestCancellation.Dispose() }
}

function Get-EeaWebsiteIcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Website,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        $Client
    )

    $pageAddress = [uri](ConvertTo-EeaWebsite $Website)
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $ownsClient = $null -eq $Client
    if ($ownsClient) {
        $handler = New-Object Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $handler.UseDefaultCredentials = $false
        $handler.Credentials = $null
        $handler.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $handler.Proxy.Credentials = $null
        $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12
        $handler.AutomaticDecompression = [Net.DecompressionMethods]'GZip, Deflate'
        $handler.MaxResponseHeadersLength = 32
        $Client = New-Object Net.Http.HttpClient($handler)
        $Client.Timeout = [TimeSpan]::FromMilliseconds(-1)
        $Client.DefaultRequestHeaders.UserAgent.ParseAdd('EasyEdgeApps')
    }
    $lookupCancellation = [Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken, [Threading.CancellationToken]::None)
    $lookupCancellation.CancelAfter(20000)
    try {
        $candidates = @(Get-EeaWebsiteIconCandidates -PageUri $pageAddress)
        try {
            $page = Get-EeaWebsiteResponse -Client $Client -Website $pageAddress.AbsoluteUri -MaximumBytes 512KB -CancellationToken $lookupCancellation.Token
            $encoding = [Text.Encoding]::UTF8
            if ($page.CharacterSet) {
                try { $encoding = [Text.Encoding]::GetEncoding($page.CharacterSet.Trim('"')) }
                catch { $encoding = [Text.Encoding]::UTF8 }
            }
            if (-not $page.MediaType -or $page.MediaType -in @('text/html', 'application/xhtml+xml')) {
                $candidates = @(Get-EeaWebsiteIconCandidates -PageUri $page.Uri -Html $encoding.GetString($page.Bytes))
            }
        }
        catch { if ($lookupCancellation.IsCancellationRequested) { throw } }
        foreach ($candidate in $candidates) {
            try {
                $download = Get-EeaWebsiteResponse -Client $Client -Website $candidate -MaximumBytes 1MB -CancellationToken $lookupCancellation.Token
                $iconData = ConvertTo-EeaWebsiteIcon $download.Bytes
                return [pscustomobject]@{ Bytes = $iconData; SourceUrl = $download.Uri.AbsoluteUri }
            }
            catch { if ($lookupCancellation.IsCancellationRequested) { throw } }
        }
        throw 'No usable ICO or PNG website icon was found. Your current icon has not changed.'
    }
    catch {
        if ($CancellationToken.IsCancellationRequested) { throw (New-Object OperationCanceledException('Website icon lookup cancelled.')) }
        if ($lookupCancellation.IsCancellationRequested) { throw 'Website icon lookup timed out. Your current icon has not changed.' }
        throw
    }
    finally {
        $lookupCancellation.Dispose()
        if ($ownsClient) { $Client.Dispose() }
    }
}

function Start-EeaWebsiteIconRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Website, $Client)

    $address = ConvertTo-EeaWebsite $Website
    $cancellation = New-Object Threading.CancellationTokenSource
    $pipeline = [PowerShell]::Create()
    try {
        $definitions = foreach ($functionName in @('ConvertTo-EeaWebsite', 'Assert-EeaIconData', 'ConvertTo-EeaWebsiteIcon', 'Get-EeaWebsiteIconCandidates', 'Get-EeaWebsiteResponse', 'Get-EeaWebsiteIcon')) {
            'function ' + $functionName + " {`n" + (Get-Command $functionName -CommandType Function).Definition + "`n}"
        }
        $bootstrap = '$ErrorActionPreference = ''Stop''' + "`n" + ($definitions -join "`n") + "`n" + 'Get-EeaWebsiteIcon -Website $args[0] -CancellationToken $args[1] -Client $args[2]'
        [void]$pipeline.AddScript($bootstrap).AddArgument($address).AddArgument($cancellation.Token).AddArgument($Client)
        $pending = $pipeline.BeginInvoke()
        return [pscustomobject]@{ Website = $address; PowerShell = $pipeline; AsyncResult = $pending; Cancellation = $cancellation; Discard = $false }
    }
    catch { $pipeline.Dispose(); $cancellation.Dispose(); throw }
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
        [byte[]]$IconData,
        [switch]$GenerateIcon,
        [AllowEmptyString()][string]$Notes,
        [bool]$Desktop = $true,
        [bool]$StartMenu = $true,
        $Context = (Get-EeaContext)
    )

    $cleanName = ConvertTo-EeaName $AppName
    $cleanWebsite = ConvertTo-EeaWebsite $Website
    $notesProvided = $PSBoundParameters.ContainsKey('Notes')
    if ($notesProvided) { $Notes = ConvertTo-EeaNotes $Notes }
    if (@(@([bool]$CustomIcon, ($null -ne $IconData), [bool]$GenerateIcon) | Where-Object { $_ }).Count -gt 1) { throw 'Choose one icon source.' }
    if (-not $Desktop -and -not $StartMenu) { throw 'Choose Desktop, Start menu, or both.' }
    $edgePath = Find-EeaEdge
    $paths = Get-EeaPaths $Context $cleanName
    $iconBytes = $null
    if ($CustomIcon) { $iconBytes = Read-EeaCustomIcon $CustomIcon }
    elseif ($null -ne $IconData) { Assert-EeaIconData $IconData; $iconBytes = $IconData }
    if (-not $PSCmdlet.ShouldProcess($cleanName, 'Create or update website shortcuts for the current Windows user')) { return }
    Invoke-EeaLocked {
        Assert-EeaReady $Context
        $previousState = Read-EeaManifest $Context $cleanName
        Assert-EeaOwnership -Paths $paths -State $previousState -Desktop $Desktop -StartMenu $StartMenu
        $savedNotes = if ($notesProvided) { $Notes } elseif ($null -ne $previousState -and $null -ne $previousState.PSObject.Properties['Notes']) { $previousState.Notes } else { '' }
        Invoke-EeaTransaction -Context $Context -Prepare {
            param($StagePath)
            $stagedIcon = Join-Path $StagePath 'icon.ico'
            $iconKind = 'Generated'
            if ($null -ne $iconBytes) { [IO.File]::WriteAllBytes($stagedIcon, $iconBytes); $iconKind = 'Custom' }
            elseif (-not $GenerateIcon -and $null -ne $previousState -and [IO.File]::Exists($paths.Icon)) {
                [IO.File]::Copy($paths.Icon, $stagedIcon)
                $iconKind = if ($null -ne $previousState.PSObject.Properties['IconKind']) { $previousState.IconKind } else { 'Custom' }
            }
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
                IconKind = $iconKind
                Notes = $savedNotes
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

function Assert-EeaFields {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Value, [string[]]$Required, [string[]]$Optional = @())

    if ($Value -isnot [pscustomobject]) { throw 'An App Kit object has an invalid type.' }
    $fields = @($Value.PSObject.Properties.Name)
    foreach ($field in $Required) {
        if ($fields -cnotcontains $field) { throw 'A required App Kit field is missing.' }
    }
    foreach ($field in $fields) {
        if ($Required -cnotcontains $field -and $Optional -cnotcontains $field) { throw 'The App Kit contains an unsupported field.' }
    }
}

function ConvertFrom-EeaBase64 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][int]$MaximumBytes, [int]$ExactBytes = 0)

    if ($Value -isnot [string] -or $Value.Length -gt 4 * [Math]::Ceiling($MaximumBytes / 3.0) -or
        $Value -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') { throw 'An encoded App Kit field is invalid or too large.' }
    try { $bytes = [Convert]::FromBase64String($Value) }
    catch { throw 'An encoded App Kit field is invalid.' }
    if ($bytes.Length -gt $MaximumBytes -or ($ExactBytes -gt 0 -and $bytes.Length -ne $ExactBytes) -or
        [Convert]::ToBase64String($bytes) -cne $Value) { throw 'An encoded App Kit field has an invalid length or representation.' }
    return ,$bytes
}

function ConvertTo-EeaKit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Value)

    Assert-EeaFields $Value @('Product', 'SchemaVersion', 'Name', 'Apps') @('Notes')
    if ($Value.Product -isnot [string] -or $Value.Product -cne 'EasyEdgeApps.AppKit' -or ($Value.SchemaVersion -isnot [int] -and $Value.SchemaVersion -isnot [long]) -or
        $Value.SchemaVersion -ne 1 -or $Value.Name -isnot [string] -or $Value.Apps -isnot [Array] -or
        $Value.Apps.Count -lt 1 -or $Value.Apps.Count -gt 100) { throw 'Use a version 1 App Kit containing between 1 and 100 apps.' }
    $kitName = ConvertTo-EeaName $Value.Name
    $kitNotes = ''
    if ($null -ne $Value.PSObject.Properties['Notes']) {
        if ($Value.Notes -isnot [string]) { throw 'App Kit notes must be plain text.' }
        $kitNotes = ConvertTo-EeaNotes $Value.Notes
    }
    $identities = New-Object 'Collections.Generic.HashSet[string]'
    $apps = New-Object 'Collections.Generic.List[object]'
    $iconCharacters = 0L
    foreach ($app in $Value.Apps) {
        Assert-EeaFields $app @('Name', 'Url', 'Desktop', 'StartMenu', 'Icon') @('Notes')
        if ($app.Name -isnot [string] -or $app.Url -isnot [string] -or $app.Desktop -isnot [bool] -or $app.StartMenu -isnot [bool] -or
            (-not $app.Desktop -and -not $app.StartMenu)) { throw 'An App Kit name, website address, or shortcut placement is invalid.' }
        $cleanName = ConvertTo-EeaName $app.Name
        $cleanUrl = ConvertTo-EeaWebsite $app.Url
        if (-not $identities.Add((Get-EeaId $cleanName))) { throw 'The App Kit contains duplicate normalized app names.' }
        $appNotes = ''
        if ($null -ne $app.PSObject.Properties['Notes']) {
            if ($app.Notes -isnot [string]) { throw 'App helper notes must be plain text.' }
            $appNotes = ConvertTo-EeaNotes $app.Notes
        }
        if ($null -eq $app.Icon -or $null -eq $app.Icon.PSObject.Properties['Kind'] -or $app.Icon.Kind -isnot [string]) { throw 'Portable icon information is missing or invalid.' }
        if ($app.Icon.Kind -ceq 'Generated') {
            Assert-EeaFields $app.Icon @('Kind', 'Version')
            if (($app.Icon.Version -isnot [int] -and $app.Icon.Version -isnot [long]) -or $app.Icon.Version -ne 1) { throw 'Unsupported automatic icon version.' }
            $icon = [pscustomobject]@{ Kind = 'Generated'; Version = 1 }
        }
        elseif ($app.Icon.Kind -ceq 'Embedded') {
            Assert-EeaFields $app.Icon @('Kind', 'Data', 'Sha256')
            if ($app.Icon.Data -isnot [string] -or $app.Icon.Sha256 -isnot [string] -or $app.Icon.Sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid embedded icon fields.' }
            $iconCharacters += $app.Icon.Data.Length
            if ($iconCharacters -gt 16MB) { throw 'The App Kit payload exceeds 16 MB.' }
            $iconBytes = ConvertFrom-EeaBase64 $app.Icon.Data -MaximumBytes 1MB
            if ((Get-EeaByteHash $iconBytes) -cne $app.Icon.Sha256) { throw 'An embedded icon checksum does not match.' }
            Assert-EeaIconData $iconBytes
            $icon = [pscustomobject]@{ Kind = 'Embedded'; Data = $app.Icon.Data; Sha256 = $app.Icon.Sha256 }
        }
        else { throw 'Unsupported portable icon kind.' }
        $apps.Add([pscustomobject][ordered]@{ Name = $cleanName; Url = $cleanUrl; Desktop = $app.Desktop; StartMenu = $app.StartMenu; Notes = $appNotes; Icon = $icon })
    }
    $kit = [pscustomobject][ordered]@{ Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = $kitName; Notes = $kitNotes; Apps = $apps.ToArray() }
    if ([Text.Encoding]::UTF8.GetByteCount(($kit | ConvertTo-Json -Depth 8 -Compress)) -gt 16MB) { throw 'The App Kit payload exceeds 16 MB.' }
    return $kit
}

function ConvertTo-EeaKitApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)]$Context, [switch]$AutomaticIfMissing)

    $paths = Get-EeaPaths $Context $State.Name
    Assert-EeaSafePath $paths.Icon
    $generated = $null -ne $State.PSObject.Properties['IconKind'] -and $State.IconKind -ceq 'Generated'
    if (Test-Path -LiteralPath $paths.Icon) {
        $iconBytes = Read-EeaCustomIcon $paths.Icon
        if ((Get-EeaByteHash $iconBytes) -cne $State.IconHash) { throw 'The saved icon was changed outside Easy Edge Apps.' }
    }
    elseif (-not $generated -and -not $AutomaticIfMissing) { throw 'A saved custom icon is missing. Restore it or choose an automatic icon before exporting.' }
    else { $generated = $true }
    $icon = if ($generated) { [pscustomobject]@{ Kind = 'Generated'; Version = 1 } }
        else { [pscustomobject]@{ Kind = 'Embedded'; Data = [Convert]::ToBase64String($iconBytes); Sha256 = $State.IconHash } }
    $notes = if ($null -ne $State.PSObject.Properties['Notes']) { $State.Notes } else { '' }
    return [pscustomobject]@{ Name = $State.Name; Url = $State.Url; Desktop = $State.Desktop; StartMenu = $State.StartMenu; Notes = $notes; Icon = $icon }
}

function New-EeaKit {
    [CmdletBinding()]
    param([string]$KitName = 'My websites', [string]$Notes = '', [string[]]$AppNames, $Context = (Get-EeaContext))

    $apps = @(Get-EeaApps -Context $Context)
    if ($AppNames) {
        $selectedIds = @($AppNames | ForEach-Object { Get-EeaId $_ })
        foreach ($selectedId in $selectedIds) {
            if (@($apps | Where-Object { $_.Id -ceq $selectedId }).Count -ne 1) { throw 'A selected website is not saved.' }
        }
        $apps = @($apps | Where-Object { $selectedIds -ccontains $_.Id })
    }
    $portableApps = @($apps | ForEach-Object { ConvertTo-EeaKitApp -State $_ -Context $Context })
    return ConvertTo-EeaKit ([pscustomobject]@{ Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = $KitName; Notes = $Notes; Apps = $portableApps })
}

function Get-EeaChecks {
    [CmdletBinding()]
    param([string[]]$AppNames, $Context = (Get-EeaContext))

    try { Assert-EeaReady $Context }
    catch { return [pscustomobject]@{ Name = 'Setup recovery'; Id = ''; Status = 'Blocked'; CanRepair = $false; Issues = @($_.Exception.Message); State = $null } }
    $edgePath = $null
    $edgeIssue = ''
    try { $edgePath = Find-EeaEdge } catch { $edgeIssue = $_.Exception.Message }
    $entries = New-Object 'Collections.Generic.List[object]'
    if ($AppNames) {
        foreach ($appName in $AppNames) { $entries.Add([pscustomobject]@{ Name = (ConvertTo-EeaName $appName); Id = (Get-EeaId $appName); Invalid = $false }) }
    }
    else {
        $appsRoot = Join-Path $Context.Root 'Apps'
        try {
            Assert-EeaSafePath $appsRoot
            if ([IO.Directory]::Exists($appsRoot)) {
                foreach ($directory in @(Get-ChildItem -LiteralPath $appsRoot -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
                    if ($directory.Name -cnotmatch '^[a-f0-9]{64}$') { continue }
                    $candidate = [pscustomobject]@{ Name = ('Saved app ' + $directory.Name.Substring(0, 8)); Id = $directory.Name; Invalid = $true }
                    try {
                        $manifestPath = Join-Path $directory.FullName 'app.json'
                        Assert-EeaSafePath $manifestPath
                        if (-not [IO.File]::Exists($manifestPath) -or (Get-Item -LiteralPath $manifestPath -Force).Length -gt 32768) { throw 'Invalid settings.' }
                        $summary = ConvertFrom-EeaJson ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8))
                        if ($null -eq $summary.PSObject.Properties['Name'] -or $summary.Name -isnot [string] -or (Get-EeaId $summary.Name) -cne $directory.Name) { throw 'Invalid identity.' }
                        $candidate.Name = $summary.Name
                        $candidate.Invalid = $false
                    }
                    catch { }
                    $entries.Add($candidate)
                }
            }
        }
        catch { return [pscustomobject]@{ Name = 'Saved apps'; Id = ''; Status = 'Blocked'; CanRepair = $false; Issues = @('The saved apps folder cannot be safely read.'); State = $null } }
    }
    if ($entries.Count -eq 0 -and $edgeIssue) {
        return [pscustomobject]@{ Name = 'Microsoft Edge'; Id = ''; Status = 'Blocked'; CanRepair = $false; Issues = @($edgeIssue); State = $null }
    }
    foreach ($entry in $entries) {
        $issues = New-Object 'Collections.Generic.List[string]'
        $state = $null
        $status = 'Healthy'
        try {
            if ($entry.Invalid) { throw 'Saved settings are missing or damaged. Ask your helper to restore a trusted copy.' }
            $state = Read-EeaManifest $Context $entry.Name
            if ($null -eq $state) { throw 'This website has no valid saved settings.' }
            $paths = Get-EeaPaths $Context $state.Name
            Assert-EeaOwnership -Paths $paths -State $state -Desktop $state.Desktop -StartMenu $state.StartMenu
            foreach ($slot in @('Desktop', 'StartMenu')) {
                if ($state.$slot -and -not [IO.File]::Exists($paths.$slot)) { $issues.Add('Recreate missing ' + $slot + ' shortcut.') }
            }
            if (-not [IO.File]::Exists($paths.Icon)) { $issues.Add('Recreate missing icon as an automatic letter icon. Import a trusted kit to restore a custom icon.') }
            else { $null = Read-EeaCustomIcon $paths.Icon }
            if ($edgePath -and -not [StringComparer]::OrdinalIgnoreCase.Equals($state.EdgePath, $edgePath)) { $issues.Add('Update owned shortcuts to the current Edge executable.') }
            if ($issues.Count -gt 0) { $status = 'Repairable' }
        }
        catch { $status = 'Conflict'; $issues.Add($_.Exception.Message) }
        if ($edgeIssue) { $issues.Add($edgeIssue); if ($status -ne 'Conflict') { $status = 'Blocked' } }
        $snapshot = ''
        if ($status -in @('Healthy', 'Repairable')) {
            try { $snapshot = Get-EeaAppSnapshot -Paths $paths -EdgePath $edgePath }
            catch { $status = 'Conflict'; $issues.Add('The app files could not be safely checked.') }
        }
        [pscustomobject]@{ Name = $entry.Name; Id = $entry.Id; Status = $status; CanRepair = ($status -eq 'Repairable'); Issues = $issues.ToArray(); State = $state; Snapshot = $snapshot }
    }
}

function Get-EeaAppSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths, [Parameter(Mandatory = $true)][string]$EdgePath)

    $parts = New-Object 'Collections.Generic.List[string]'
    $parts.Add($EdgePath)
    foreach ($slot in @('Manifest', 'Icon', 'Desktop', 'StartMenu')) {
        $path = $Paths.$slot
        Assert-EeaSafePath $path
        $value = if ([IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash }
            elseif (Test-Path -LiteralPath $path) { 'Occupied' } else { 'Missing' }
        $parts.Add($slot + ':' + $value)
    }
    return Get-EeaByteHash ([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))
}

function Get-EeaKitPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Kit, [switch]$NewOnly, $Context = (Get-EeaContext))

    $validated = ConvertTo-EeaKit $Kit
    $setupIssue = ''
    $edgePath = ''
    try { Assert-EeaReady $Context; $edgePath = Find-EeaEdge } catch { $setupIssue = $_.Exception.Message }
    foreach ($app in $validated.Apps) {
        $action = 'Add'
        $detail = 'Create the selected shortcuts.'
        $currentUrl = ''
        $domainChanged = $false
        $snapshot = ''
        try {
            if ($setupIssue) { throw $setupIssue }
            $paths = Get-EeaPaths $Context $app.Name
            $state = Read-EeaManifest $Context $app.Name
            Assert-EeaOwnership -Paths $paths -State $state -Desktop $app.Desktop -StartMenu $app.StartMenu
            if ($null -ne $state) {
                if ($NewOnly) { throw 'A website with this name is now saved. Refresh Favorites before adding it.' }
                $currentUrl = $state.Url
                $domainChanged = -not [StringComparer]::OrdinalIgnoreCase.Equals(([Uri]$state.Url).IdnHost, ([Uri]$app.Url).IdnHost)
                $check = Get-EeaChecks -AppNames @($state.Name) -Context $Context
                if ($check.Status -in @('Conflict', 'Blocked')) { throw ($check.Issues -join ' ') }
                $oldNotes = if ($null -ne $state.PSObject.Properties['Notes']) { $state.Notes } else { '' }
                $sameIcon = if ($app.Icon.Kind -ceq 'Embedded') { $state.IconHash -ceq $app.Icon.Sha256 }
                    else { $null -ne $state.PSObject.Properties['IconKind'] -and $state.IconKind -ceq 'Generated' }
                $action = 'Update'
                $detail = if ($domainChanged) { 'DESTINATION DOMAIN CHANGES. Review both addresses before approving.' }
                    elseif ($state.Url -cne $app.Url) { 'Website address changes. Review both addresses before approving.' }
                    else { 'Update notes, icon, placement, or missing owned files.' }
                if ($state.Url -ceq $app.Url -and $state.Desktop -eq $app.Desktop -and $state.StartMenu -eq $app.StartMenu -and
                    $oldNotes -ceq $app.Notes -and $sameIcon -and $check.Status -eq 'Healthy') { $action = 'Unchanged'; $detail = 'Already matches this kit.' }
            }
            $snapshot = Get-EeaAppSnapshot -Paths $paths -EdgePath $edgePath
        }
        catch { $action = 'Conflict'; $detail = $_.Exception.Message }
        [pscustomobject]@{ Name = $app.Name; Action = $action; CurrentUrl = $currentUrl; Url = $app.Url; DomainChanged = $domainChanged; Detail = $detail; Snapshot = $snapshot; App = $app }
    }
}

function Import-EeaKit {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)]$Kit, [object[]]$ExpectedPreview, [switch]$NewOnly, $Context = (Get-EeaContext))

    $validated = ConvertTo-EeaKit $Kit
    $preview = @(Get-EeaKitPreview -Kit $validated -NewOnly:$NewOnly -Context $Context)
    if ($ExpectedPreview) {
        foreach ($row in $preview) {
            $expected = @($ExpectedPreview | Where-Object { (Get-EeaId $_.Name) -ceq (Get-EeaId $row.Name) })
            if ($expected.Count -ne 1 -or $expected[0].Snapshot -cne $row.Snapshot -or $expected[0].Action -cne $row.Action -or $expected[0].Url -cne $row.Url) {
                throw 'The setup changed after the preview. Refresh the preview before making changes.'
            }
        }
    }
    if (@($preview | Where-Object { $_.Action -eq 'Conflict' }).Count -gt 0) {
        return [pscustomobject]@{ Completed = $false; Results = @($preview | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Status = $(if ($_.Action -eq 'Conflict') { 'Conflict' } else { 'Not attempted' }); Detail = $_.Detail }
        }) }
    }
    $changeCount = @($preview | Where-Object { $_.Action -ne 'Unchanged' }).Count
    if ($changeCount -eq 0) {
        return [pscustomobject]@{ Completed = $true; Results = @($preview | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = 'Unchanged'; Detail = $_.Detail } }) }
    }
    if (-not $PSCmdlet.ShouldProcess($validated.Name, ('Apply ' + $changeCount + ' app changes after reviewing the import preview; completed apps remain if a later app fails'))) {
        return [pscustomobject]@{ Completed = $false; Results = @($preview | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = 'Not applied'; Detail = $_.Action + ': ' + $_.Detail } }) }
    }
    Invoke-EeaLocked {
        $freshPreview = @(Get-EeaKitPreview -Kit $validated -NewOnly:$NewOnly -Context $Context)
        for ($rowIndex = 0; $rowIndex -lt $preview.Count; $rowIndex++) {
            if ($freshPreview[$rowIndex].Action -cne $preview[$rowIndex].Action -or $freshPreview[$rowIndex].Snapshot -cne $preview[$rowIndex].Snapshot) {
                throw 'The setup changed after approval. Nothing was changed; refresh the preview.'
            }
        }
        $results = New-Object 'Collections.Generic.List[object]'
        $failed = $false
        foreach ($row in $freshPreview) {
            $status = 'Not attempted'
            $detail = 'An earlier app failed. Completed apps remain installed.'
            if (-not $failed) {
                if ($row.Action -eq 'Unchanged') { $status = 'Unchanged'; $detail = $row.Detail }
                else {
                    try {
                        $app = $row.App
                        $installParameters = @{ AppName = $app.Name; Website = $app.Url; Desktop = $app.Desktop; StartMenu = $app.StartMenu; Notes = $app.Notes; Context = $Context; Confirm = $false }
                        if ($app.Icon.Kind -ceq 'Embedded') { $installParameters.IconData = ConvertFrom-EeaBase64 $app.Icon.Data -MaximumBytes 1MB }
                        else { $installParameters.GenerateIcon = $true }
                        $null = Install-EeaApp @installParameters
                        $status = if ($row.Action -eq 'Add') { 'Added' } else { 'Updated' }
                        $detail = 'Shortcut setup saved. Website access and sign-in were not tested.'
                    }
                    catch { $failed = $true; $status = 'Failed'; $detail = $_.Exception.Message }
                }
            }
            $results.Add([pscustomobject]@{ Name = $row.Name; Status = $status; Detail = $detail })
        }
        [pscustomobject]@{ Completed = (-not $failed); Results = $results.ToArray() }
    }
}

function Repair-EeaApps {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$AppNames, [object[]]$ExpectedChecks, $Context = (Get-EeaContext))

    $checks = @(Get-EeaChecks -AppNames $AppNames -Context $Context)
    if (@($checks | Where-Object { $_.Status -notin @('Healthy', 'Repairable') }).Count -gt 0) {
        return [pscustomobject]@{ Completed = $false; Results = @($checks | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = 'Not repaired'; Detail = $_.Issues -join ' ' } }) }
    }
    if ($ExpectedChecks) {
        foreach ($check in $checks) {
            $expected = @($ExpectedChecks | Where-Object { $_.Id -ceq $check.Id })
            if ($expected.Count -ne 1 -or $expected[0].Snapshot -cne $check.Snapshot) { throw 'The setup changed after the check. Check Apps again before repairing.' }
        }
    }
    $apps = @($checks | ForEach-Object { ConvertTo-EeaKitApp -State $_.State -Context $Context -AutomaticIfMissing })
    $kit = ConvertTo-EeaKit ([pscustomobject]@{ Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = 'Repair selected apps'; Notes = ''; Apps = $apps })
    $repairPreview = @(Get-EeaKitPreview -Kit $kit -Context $Context)
    for ($checkIndex = 0; $checkIndex -lt $checks.Count; $checkIndex++) {
        if ($checks[$checkIndex].Snapshot -cne $repairPreview[$checkIndex].Snapshot) { throw 'The setup changed during the check. Check Apps again before repairing.' }
    }
    if (-not $PSCmdlet.ShouldProcess(($AppNames -join ', '), 'Repair selected owned shortcuts and missing icons; do not test websites')) {
        return [pscustomobject]@{ Completed = $false; Results = @($checks | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = 'Not applied'; Detail = $_.Issues -join ' ' } }) }
    }
    $result = Import-EeaKit -Kit $kit -ExpectedPreview $repairPreview -Context $Context -Confirm:$false
    foreach ($row in $result.Results) { if ($row.Status -eq 'Updated') { $row.Status = 'Repaired' } }
    return $result
}

function Initialize-EeaCrypto {
    [CmdletBinding()]
    param()

    if ($null -ne ('EasyEdgeApps.CryptoSupportV1' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System.Runtime.CompilerServices;
namespace EasyEdgeApps {
    public static class CryptoSupportV1 {
        [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
        public static bool TagsEqual(byte[] expected, byte[] received) {
            if (expected == null || received == null || expected.Length != 32 || received.Length != 32) return false;
            int differences = 0;
            for (int byteIndex = 0; byteIndex < 32; byteIndex++) differences |= expected[byteIndex] ^ received[byteIndex];
            return differences == 0;
        }
    }
}
'@ -ErrorAction Stop
}

function ConvertFrom-EeaPassword {
    [CmdletBinding()]
    param([Security.SecureString]$Password)

    if ($null -eq $Password -or $Password.Length -lt 1 -or $Password.Length -gt 1024) { throw 'Provide a SecureString password of 1 to 1024 characters. Use Read-Host -AsSecureString; do not put a password in a command.' }
    $pointer = [IntPtr]::Zero
    $characters = New-Object char[] $Password.Length
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        [Runtime.InteropServices.Marshal]::Copy($pointer, $characters, 0, $characters.Length)
        return ,(New-Object Text.UTF8Encoding($false, $true)).GetBytes($characters)
    }
    finally {
        [Array]::Clear($characters, 0, $characters.Length)
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer) }
    }
}

function Assert-EeaExportPassword {
    [CmdletBinding()]
    param([Security.SecureString]$Password, [Security.SecureString]$Confirmation)

    if ($null -eq $Password -or $Password.Length -lt 12 -or $Password.Length -gt 1024) { throw 'Choose a strong, unique passphrase between 12 and 1024 characters.' }
    if ($null -eq $Confirmation) { throw 'Confirm the export password. In the CLI, provide -PasswordConfirmation as a SecureString.' }
    Initialize-EeaCrypto
    $passwordBytes = $null
    $confirmationBytes = $null
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $passwordBytes = ConvertFrom-EeaPassword $Password
        $confirmationBytes = ConvertFrom-EeaPassword $Confirmation
        if (-not [EasyEdgeApps.CryptoSupportV1]::TagsEqual($hasher.ComputeHash($passwordBytes), $hasher.ComputeHash($confirmationBytes))) { throw 'The passwords do not match.' }
    }
    finally {
        if ($null -ne $passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
        if ($null -ne $confirmationBytes) { [Array]::Clear($confirmationBytes, 0, $confirmationBytes.Length) }
        $hasher.Dispose()
    }
}

function Get-EeaKitKey {
    [CmdletBinding()]
    param([Security.SecureString]$Password, [Parameter(Mandatory = $true)][byte[]]$Salt, [int]$Iterations = 600000)

    if ($Salt.Length -ne 16 -or $Iterations -lt 600000 -or $Iterations -gt 1200000) { throw 'Unsupported App Kit key derivation parameters.' }
    $passwordBytes = ConvertFrom-EeaPassword $Password
    $derivation = $null
    try {
        $derivation = [Security.Cryptography.Rfc2898DeriveBytes]::new($passwordBytes, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
        return ,$derivation.GetBytes(64)
    }
    finally {
        if ($null -ne $derivation) { $derivation.Dispose() }
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
    }
}

function Get-EeaAuthenticationTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [Parameter(Mandatory = $true)][byte[]]$InitializationVector,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$AssociatedData,
        [Parameter(Mandatory = $true)][byte[]]$Ciphertext
    )

    if ($Key.Length -ne 64 -or $InitializationVector.Length -ne 16 -or $AssociatedData.Length -gt 1024 -or
        $Ciphertext.Length -gt 16MB + 16 -or $Ciphertext.Length % 16 -ne 0) { throw 'Invalid authenticated-encryption input lengths.' }
    $macKey = New-Object byte[] 32
    [Array]::Copy($Key, 0, $macKey, 0, 32)
    $hmac = [Security.Cryptography.HMACSHA512]::new($macKey)
    try {
        $lengthBytes = [BitConverter]::GetBytes([uint64]($AssociatedData.LongLength * 8))
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($lengthBytes) }
        foreach ($part in @($AssociatedData, $InitializationVector, $Ciphertext)) { [void]$hmac.TransformBlock($part, 0, $part.Length, $null, 0) }
        [void]$hmac.TransformFinalBlock($lengthBytes, 0, $lengthBytes.Length)
        $tag = New-Object byte[] 32
        [Array]::Copy($hmac.Hash, $tag, 32)
        return ,$tag
    }
    finally { $hmac.Dispose(); [Array]::Clear($macKey, 0, $macKey.Length) }
}

function Protect-EeaBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [Parameter(Mandatory = $true)][byte[]]$InitializationVector,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$AssociatedData,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Plaintext
    )

    if ($Key.Length -ne 64 -or $InitializationVector.Length -ne 16 -or $Plaintext.Length -gt 16MB -or $AssociatedData.Length -gt 1024) { throw 'Invalid App Kit encryption input lengths.' }
    $encryptionKey = New-Object byte[] 32
    [Array]::Copy($Key, 32, $encryptionKey, 0, 32)
    $aes = [Security.Cryptography.Aes]::Create()
    $encryptor = $null
    try {
        $aes.Key = $encryptionKey
        $aes.IV = $InitializationVector
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $encryptor = $aes.CreateEncryptor()
        $ciphertext = $encryptor.TransformFinalBlock($Plaintext, 0, $Plaintext.Length)
        $tag = Get-EeaAuthenticationTag -Key $Key -InitializationVector $InitializationVector -AssociatedData $AssociatedData -Ciphertext $ciphertext
        return [pscustomobject]@{ Ciphertext = $ciphertext; Tag = $tag }
    }
    finally {
        if ($null -ne $encryptor) { $encryptor.Dispose() }
        $aes.Dispose()
        [Array]::Clear($encryptionKey, 0, $encryptionKey.Length)
    }
}

function Unprotect-EeaBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [Parameter(Mandatory = $true)][byte[]]$InitializationVector,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$AssociatedData,
        [Parameter(Mandatory = $true)][byte[]]$Ciphertext,
        [Parameter(Mandatory = $true)][byte[]]$Tag
    )

    Initialize-EeaCrypto
    $expectedTag = Get-EeaAuthenticationTag -Key $Key -InitializationVector $InitializationVector -AssociatedData $AssociatedData -Ciphertext $Ciphertext
    if (-not [EasyEdgeApps.CryptoSupportV1]::TagsEqual($expectedTag, $Tag)) { throw 'Incorrect password or damaged kit.' }
    $encryptionKey = New-Object byte[] 32
    [Array]::Copy($Key, 32, $encryptionKey, 0, 32)
    $aes = [Security.Cryptography.Aes]::Create()
    $decryptor = $null
    try {
        $aes.Key = $encryptionKey
        $aes.IV = $InitializationVector
        $aes.Mode = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $decryptor = $aes.CreateDecryptor()
        return ,$decryptor.TransformFinalBlock($Ciphertext, 0, $Ciphertext.Length)
    }
    catch { throw 'Incorrect password or damaged kit.' }
    finally {
        if ($null -ne $decryptor) { $decryptor.Dispose() }
        $aes.Dispose()
        [Array]::Clear($encryptionKey, 0, $encryptionKey.Length)
    }
}

function Get-EeaEnvelopeData {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Envelope)

    Assert-EeaFields $Envelope @('Product', 'SchemaVersion', 'Algorithm', 'Kdf', 'Iterations', 'Salt', 'Iv', 'Ciphertext', 'Tag')
    foreach ($field in @('Product', 'Algorithm', 'Kdf', 'Salt', 'Iv', 'Ciphertext', 'Tag')) {
        if ($Envelope.$field -isnot [string]) { throw 'Invalid encrypted App Kit field type.' }
    }
    if ($Envelope.Product -cne 'EasyEdgeApps.EncryptedKit' -or
        ($Envelope.SchemaVersion -isnot [int] -and $Envelope.SchemaVersion -isnot [long]) -or $Envelope.SchemaVersion -ne 1 -or
        $Envelope.Algorithm -cne 'A256CBC-HS512' -or $Envelope.Kdf -cne 'PBKDF2-HMAC-SHA256') { throw 'Unsupported encrypted App Kit version or algorithm.' }
    if (($Envelope.Iterations -isnot [int] -and $Envelope.Iterations -isnot [long]) -or $Envelope.Iterations -lt 600000 -or $Envelope.Iterations -gt 1200000) { throw 'Unsupported App Kit key derivation parameters.' }
    $salt = ConvertFrom-EeaBase64 $Envelope.Salt -MaximumBytes 16 -ExactBytes 16
    $initializationVector = ConvertFrom-EeaBase64 $Envelope.Iv -MaximumBytes 16 -ExactBytes 16
    $tag = ConvertFrom-EeaBase64 $Envelope.Tag -MaximumBytes 32 -ExactBytes 32
    $ciphertext = ConvertFrom-EeaBase64 $Envelope.Ciphertext -MaximumBytes (16MB + 16)
    if ($ciphertext.Length -lt 16 -or $ciphertext.Length % 16 -ne 0) { throw 'Invalid App Kit ciphertext length.' }
    $header = @('EasyEdgeApps.EncryptedKit', '1', 'A256CBC-HS512', 'PBKDF2-HMAC-SHA256', $Envelope.Iterations.ToString([Globalization.CultureInfo]::InvariantCulture), $Envelope.Salt) -join "`n"
    return [pscustomobject]@{ Salt = $salt; InitializationVector = $initializationVector; Tag = $tag; Ciphertext = $ciphertext; AssociatedData = [Text.Encoding]::ASCII.GetBytes($header) }
}

function Protect-EeaKit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Kit, [Security.SecureString]$Password, [Security.SecureString]$PasswordConfirmation)

    $validated = ConvertTo-EeaKit $Kit
    Assert-EeaExportPassword -Password $Password -Confirmation $PasswordConfirmation
    $plaintext = [Text.Encoding]::UTF8.GetBytes(($validated | ConvertTo-Json -Depth 8 -Compress))
    $salt = New-Object byte[] 16
    $initializationVector = New-Object byte[] 16
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $key = $null
    try {
        $random.GetBytes($salt)
        $random.GetBytes($initializationVector)
        $envelope = [pscustomobject][ordered]@{
            Product = 'EasyEdgeApps.EncryptedKit'; SchemaVersion = 1; Algorithm = 'A256CBC-HS512'
            Kdf = 'PBKDF2-HMAC-SHA256'; Iterations = 600000; Salt = [Convert]::ToBase64String($salt)
            Iv = [Convert]::ToBase64String($initializationVector); Ciphertext = [Convert]::ToBase64String((New-Object byte[] 16)); Tag = [Convert]::ToBase64String((New-Object byte[] 32))
        }
        $metadata = Get-EeaEnvelopeData $envelope
        $key = Get-EeaKitKey -Password $Password -Salt $salt -Iterations $envelope.Iterations
        $encrypted = Protect-EeaBytes -Key $key -InitializationVector $initializationVector -AssociatedData $metadata.AssociatedData -Plaintext $plaintext
        $envelope.Ciphertext = [Convert]::ToBase64String($encrypted.Ciphertext)
        $envelope.Tag = [Convert]::ToBase64String($encrypted.Tag)
        return $envelope
    }
    finally {
        $random.Dispose()
        if ($null -ne $key) { [Array]::Clear($key, 0, $key.Length) }
        [Array]::Clear($plaintext, 0, $plaintext.Length)
    }
}

function Unprotect-EeaKit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Envelope, [Security.SecureString]$Password)

    $metadata = Get-EeaEnvelopeData $Envelope
    if ($null -eq $Password) { throw 'This App Kit needs a password. Provide -Password as a SecureString; no interactive prompt will be opened automatically.' }
    $key = $null
    $plaintext = $null
    try {
        $key = Get-EeaKitKey -Password $Password -Salt $metadata.Salt -Iterations $Envelope.Iterations
        $plaintext = Unprotect-EeaBytes -Key $key -InitializationVector $metadata.InitializationVector -AssociatedData $metadata.AssociatedData -Ciphertext $metadata.Ciphertext -Tag $metadata.Tag
        if ($plaintext.Length -gt 16MB) { throw 'The App Kit payload exceeds 16 MB.' }
        try { $value = ConvertFrom-EeaJson ((New-Object Text.UTF8Encoding($false, $true)).GetString($plaintext)) }
        catch { throw 'The decrypted App Kit is not valid UTF-8 JSON.' }
        return ConvertTo-EeaKit $value
    }
    finally {
        if ($null -ne $key) { [Array]::Clear($key, 0, $key.Length) }
        if ($null -ne $plaintext) { [Array]::Clear($plaintext, 0, $plaintext.Length) }
    }
}

function Read-EeaKitDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    Assert-EeaSafePath $resolvedPath
    $stream = $null
    $bytes = $null
    try {
        $stream = [IO.File]::OpenRead($resolvedPath)
        if ($stream.Length -lt 2 -or $stream.Length -gt 24MB) { throw 'Use an App Kit file no larger than 24 MB.' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -eq 0) { throw 'The App Kit file is incomplete.' }
            $offset += $count
        }
        try {
            $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
            if ($text[0] -eq [char]0xfeff) { $text = $text.Substring(1) }
            $document = ConvertFrom-EeaJson $text
        }
        catch { throw 'The App Kit is not valid UTF-8 JSON.' }
        if ($null -eq $document -or $null -eq $document.PSObject.Properties['Product']) { throw 'This file is not an App Kit.' }
        if ($document.Product -is [string] -and $document.Product -ceq 'EasyEdgeApps.EncryptedKit') { $null = Get-EeaEnvelopeData $document; return $document }
        if ($bytes.Length -gt 16MB) { throw 'The App Kit payload exceeds 16 MB.' }
        return ConvertTo-EeaKit $document
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Read-EeaKit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Security.SecureString]$Password)

    $document = Read-EeaKitDocument $Path
    if ($document.Product -ceq 'EasyEdgeApps.EncryptedKit') { return Unprotect-EeaKit -Envelope $document -Password $Password }
    return $document
}

function Write-EeaKit {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]$Kit,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Protected,
        [Security.SecureString]$Password,
        [Security.SecureString]$PasswordConfirmation,
        [switch]$Replace
    )

    $validated = ConvertTo-EeaKit $Kit
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $resolvedPath.EndsWith('.eeakit.json', [StringComparison]::OrdinalIgnoreCase)) { throw 'Use a filename ending in .eeakit.json.' }
    $fileName = [IO.Path]::GetFileName($resolvedPath)
    $null = ConvertTo-EeaName $fileName.Substring(0, $fileName.Length - '.eeakit.json'.Length)
    Assert-EeaSafePath $resolvedPath
    $parent = [IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [IO.Directory]::Exists($parent)) { throw 'Choose an existing folder for the App Kit.' }
    if ([IO.Directory]::Exists($resolvedPath)) { throw 'The export destination is occupied by a folder.' }
    $existed = [IO.File]::Exists($resolvedPath)
    if ($existed -and -not $Replace) { throw 'The export file already exists. Choose another name, or explicitly use -Replace after reviewing the file.' }
    $originalHash = if ($existed) { (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256 -ErrorAction Stop).Hash } else { '' }
    if (-not $Protected -and ($null -ne $Password -or $null -ne $PasswordConfirmation)) { throw 'Choose -Protected when supplying export passwords. Plaintext fallback is not allowed.' }
    $description = if ($Protected) { 'Write a password-protected App Kit; its password cannot be recovered' } else { 'Write a readable App Kit containing private website addresses and helper notes' }
    if (-not $PSCmdlet.ShouldProcess($resolvedPath, $description)) { return }
    $bytes = $null
    $stagedPath = Join-Path $parent ('.EasyEdgeApps.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $created = $false
    try {
        $document = if ($Protected) { Protect-EeaKit -Kit $validated -Password $Password -PasswordConfirmation $PasswordConfirmation } else { $validated }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($document | ConvertTo-Json -Depth 8))
        $maximumBytes = if ($Protected) { 24MB } else { 16MB }
        if ($bytes.Length -gt $maximumBytes) { throw 'The serialized App Kit exceeds the file size limit.' }
        Assert-EeaSafePath $stagedPath
        $stream = [IO.File]::Open($stagedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        Assert-EeaSafePath $resolvedPath
        if ($existed) {
            if (-not [IO.File]::Exists($resolvedPath) -or (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256 -ErrorAction Stop).Hash -cne $originalHash) { throw 'The export file changed after approval. Nothing was replaced.' }
            Write-EeaAtomicFile -Source $stagedPath -Destination $resolvedPath
        }
        else { [IO.File]::Move($stagedPath, $resolvedPath) }
        [pscustomobject]@{ Path = $resolvedPath; Protected = [bool]$Protected; AppCount = $validated.Apps.Count }
    }
    finally {
        if ($created -and [IO.File]::Exists($stagedPath)) { [IO.File]::Delete($stagedPath) }
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-EeaBrandIcon {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $encodedIcon = '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'
    $compressed = New-Object IO.MemoryStream(,[Convert]::FromBase64String($encodedIcon))
    $decompressor = New-Object IO.Compression.GZipStream($compressed, [IO.Compression.CompressionMode]::Decompress)
    $iconStream = New-Object IO.MemoryStream
    $icon = $null
    try {
        $decompressor.CopyTo($iconStream)
        if ($iconStream.Length -ne 16958) { throw 'The embedded application icon is invalid.' }
        $iconStream.Position = 0
        $icon = New-Object Drawing.Icon($iconStream)
        return $icon.Clone()
    }
    finally {
        if ($null -ne $icon) { $icon.Dispose() }
        $iconStream.Dispose()
        $decompressor.Dispose()
        $compressed.Dispose()
    }
}

function Set-EeaFormIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $Form.Icon = Get-EeaBrandIcon
    $Form.Add_Disposed({ param($Sender, $EventArgs) if ($null -ne $Sender.Icon) { $Sender.Icon.Dispose() } })
}

function Get-EeaIconPreview {
    [CmdletBinding(DefaultParameterSetName = 'File')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'File')][string]$Path,
        [Parameter(Mandatory = $true, ParameterSetName = 'Data')][byte[]]$IconData
    )

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    if ($PSCmdlet.ParameterSetName -eq 'File') { $IconData = Read-EeaCustomIcon $Path }
    else { Assert-EeaIconData $IconData }
    $stream = New-Object IO.MemoryStream(,$IconData)
    $icon = $null
    $bitmap = $null
    $graphics = $null
    try {
        $icon = New-Object Drawing.Icon($stream)
        $bitmap = New-Object Drawing.Bitmap(96, 96)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.DrawIcon($icon, (New-Object Drawing.Rectangle(0, 0, 96, 96)))
        return $bitmap
    }
    catch { if ($null -ne $bitmap) { $bitmap.Dispose() }; throw }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $icon) { $icon.Dispose() }
        $stream.Dispose()
    }
}

function Initialize-EeaSpaceBackground {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $references = @([Drawing.Bitmap].Assembly.Location, [Drawing.PointF].Assembly.Location, [Windows.Forms.Form].Assembly.Location) | Select-Object -Unique
    foreach ($assemblyName in @('System.Private.Windows.Core.dll', 'System.Private.Windows.GdiPlus.dll', 'System.Windows.Forms.Primitives.dll', 'System.ComponentModel.Primitives.dll', 'System.ComponentModel.TypeConverter.dll', 'System.ObjectModel.dll', 'System.Drawing.dll')) {
        $assemblyPath = Join-Path $PSHOME $assemblyName
        if (Test-Path -LiteralPath $assemblyPath -PathType Leaf) { $references += $assemblyPath }
    }
    $typeSource = @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace EasyEdgeApps
{
    public sealed class StarfieldRenderer : IDisposable
    {
        private struct Star
        {
            public float Horizontal, Vertical, Depth, Phase, Flux;
            public int Tone, Kernel;
            public bool Galaxy;
        }

        private readonly Star[] stars = new Star[3880];
        private readonly Color[] tones = { Color.FromArgb(226, 239, 255), Color.FromArgb(107, 183, 239), Color.FromArgb(255, 196, 143) };
        private readonly int[] kernelSizes = { 3, 7, 13, 25, 41 };
        private readonly float[][] kernels = new float[5][];
        private Bitmap image;
        private int[] background, pixels;
        private int width, height;
        private bool disposed;

        public StarfieldRenderer()
        {
            Random random = new Random(67129);
            for (int kernel = 0; kernel < kernels.Length; kernel++) kernels[kernel] = CreateKernel(kernelSizes[kernel], kernel);
            for (int index = 0; index < stars.Length; index++)
            {
                double brightness = random.NextDouble();
                Star star = new Star {
                    Depth = (float)random.NextDouble(), Phase = (float)(random.NextDouble() * Math.PI * 2),
                    Tone = random.Next(10) < 6 ? 0 : random.Next(1, 3),
                    Kernel = brightness > 0.994 ? 4 : brightness > 0.97 ? 3 : brightness > 0.86 ? 2 : brightness > 0.52 ? 1 : 0,
                    Flux = (float)(40 + brightness * 180), Galaxy = index < 3600
                };
                if (index < 3000)
                {
                    double radius = 0.07 + Math.Pow(random.NextDouble(), 0.73) * 0.9;
                    double scattering = Gaussian(random);
                    star.Horizontal = (float)(radius + Gaussian(random) * (0.006 + radius * 0.018));
                    star.Vertical = (float)((index % 3) * Math.PI * 2 / 3 + radius * 5.6 + scattering * (0.055 + radius * 0.12));
                    if (index % 9 == 0) { star.Vertical += (float)(Gaussian(random) * 0.48); star.Flux *= 0.48f; }
                }
                else if (index < 3600)
                {
                    star.Horizontal = (float)(Math.Pow(random.NextDouble(), 1.55) * 0.155);
                    star.Vertical = (float)(random.NextDouble() * Math.PI * 2);
                    star.Flux *= 0.8f;
                    star.Tone = 0;
                    star.Kernel = Math.Min(2, star.Kernel);
                }
                else
                {
                    star.Horizontal = (float)random.NextDouble();
                    star.Vertical = (float)random.NextDouble();
                    star.Flux *= 0.72f;
                }
                stars[index] = star;
            }
        }

        private static double Gaussian(Random random)
        {
            return Math.Sqrt(-2 * Math.Log(Math.Max(0.00001, random.NextDouble()))) * Math.Cos(random.NextDouble() * Math.PI * 2);
        }

        private static float[] CreateKernel(int size, int level)
        {
            float[] kernel = new float[size * size];
            double center = (size - 1) / 2.0;
            for (int vertical = 0; vertical < size; vertical++)
            {
                for (int horizontal = 0; horizontal < size; horizontal++)
                {
                    double horizontalDistance = horizontal - center;
                    double verticalDistance = vertical - center;
                    double distance = horizontalDistance * horizontalDistance + verticalDistance * verticalDistance;
                    double core = Math.Exp(-distance / (0.42 + level * 0.24));
                    double halo = level == 0 ? 0 : Math.Exp(-distance / (size * size * 0.075)) * (0.055 + level * 0.016);
                    double rays = level < 3 ? 0 : (Math.Exp(-horizontalDistance * horizontalDistance * 3.5) + Math.Exp(-verticalDistance * verticalDistance * 3.5)) * Math.Exp(-Math.Sqrt(distance) / (size * 0.16)) * 0.07;
                    kernel[vertical * size + horizontal] = (float)(core + halo + rays);
                }
            }
            return kernel;
        }

        private void EnsureViewport(Size viewport)
        {
            if (image != null && image.Size == viewport) return;
            Bitmap replacement = new Bitmap(viewport.Width, viewport.Height, PixelFormat.Format32bppPArgb);
            if (image != null) image.Dispose();
            image = replacement;
            width = viewport.Width;
            height = viewport.Height;
            pixels = new int[checked(width * height)];
            background = new int[pixels.Length];
            double scale = Math.Min(width * 0.47, height * 0.76);
            for (int vertical = 0; vertical < height; vertical++)
            {
                for (int horizontal = 0; horizontal < width; horizontal++)
                {
                    double horizontalDistance = (horizontal - width * 0.58) / scale;
                    double verticalDistance = (vertical - height * 0.52) / scale;
                    double radius = horizontalDistance * horizontalDistance + verticalDistance * verticalDistance * 1.6;
                    double starlight = Math.Exp(-radius * 19) * 11 + Math.Exp(-radius * 210) * 17;
                    int red = 4 + (int)starlight;
                    int green = 8 + (int)(starlight * 1.04);
                    int blue = 11 + (int)(starlight * 1.12);
                    background[vertical * width + horizontal] = unchecked((int)0xff000000) | (red << 16) | (green << 8) | blue;
                }
            }
        }

        private void AddLight(int horizontal, int vertical, float intensity, Color color)
        {
            if ((uint)horizontal >= (uint)width || (uint)vertical >= (uint)height || intensity < 0.6f) return;
            int offset = vertical * width + horizontal;
            int previous = pixels[offset];
            int red = Math.Min(255, ((previous >> 16) & 255) + (int)(color.R * intensity / 255));
            int green = Math.Min(255, ((previous >> 8) & 255) + (int)(color.G * intensity / 255));
            int blue = Math.Min(255, (previous & 255) + (int)(color.B * intensity / 255));
            pixels[offset] = unchecked((int)0xff000000) | (red << 16) | (green << 8) | blue;
        }

        private void DrawStar(float horizontal, float vertical, Star star, float brightness)
        {
            int size = kernelSizes[star.Kernel];
            float[] kernel = kernels[star.Kernel];
            float left = horizontal - (size - 1) / 2f;
            float top = vertical - (size - 1) / 2f;
            int originHorizontal = (int)Math.Floor(left);
            int originVertical = (int)Math.Floor(top);
            float fractionHorizontal = left - originHorizontal;
            float fractionVertical = top - originVertical;
            float topLeft = (1 - fractionHorizontal) * (1 - fractionVertical);
            float topRight = fractionHorizontal * (1 - fractionVertical);
            float bottomLeft = (1 - fractionHorizontal) * fractionVertical;
            float bottomRight = fractionHorizontal * fractionVertical;
            Color tone = tones[star.Tone];
            for (int row = 0; row < size; row++)
            {
                for (int column = 0; column < size; column++)
                {
                    float intensity = kernel[row * size + column] * brightness;
                    if (intensity < 0.6f) continue;
                    int pixelHorizontal = originHorizontal + column;
                    int pixelVertical = originVertical + row;
                    AddLight(pixelHorizontal, pixelVertical, intensity * topLeft, tone);
                    AddLight(pixelHorizontal + 1, pixelVertical, intensity * topRight, tone);
                    AddLight(pixelHorizontal, pixelVertical + 1, intensity * bottomLeft, tone);
                    AddLight(pixelHorizontal + 1, pixelVertical + 1, intensity * bottomRight, tone);
                }
            }
        }

        public void Render(Graphics graphics, Size viewport, double seconds, PointF pointer, float pointerInfluence)
        {
            if (disposed) throw new ObjectDisposedException("StarfieldRenderer");
            if (viewport.Width < 1 || viewport.Height < 1) return;
            EnsureViewport(viewport);
            Array.Copy(background, pixels, pixels.Length);
            float influence = Math.Max(0, Math.Min(1, pointerInfluence));
            float horizontalShift = (Math.Max(0, Math.Min(1, pointer.X)) - 0.5f) * influence;
            float verticalShift = (Math.Max(0, Math.Min(1, pointer.Y)) - 0.5f) * influence;
            float scale = Math.Min(width * 0.47f, height * 0.76f);
            double tilt = -0.38 + horizontalShift * 0.018;
            double tiltCosine = Math.Cos(tilt);
            double tiltSine = Math.Sin(tilt);
            for (int index = 0; index < stars.Length; index++)
            {
                Star star = stars[index];
                float horizontal, vertical;
                if (star.Galaxy)
                {
                    double angle = star.Vertical + seconds * (0.0018 + star.Depth * 0.00035);
                    double orbitHorizontal = Math.Cos(angle) * star.Horizontal * scale;
                    double orbitVertical = Math.Sin(angle) * star.Horizontal * scale * (0.74 + verticalShift * 0.015);
                    horizontal = width * 0.58f + (float)(orbitHorizontal * tiltCosine - orbitVertical * tiltSine);
                    vertical = height * 0.52f + (float)(orbitHorizontal * tiltSine + orbitVertical * tiltCosine);
                }
                else
                {
                    double span = width + 48;
                    double drift = star.Horizontal * span - seconds * (0.12 + star.Depth * 0.32);
                    horizontal = (float)((drift % span + span) % span) - 24;
                    vertical = star.Vertical * (height + 48) - 24 + (float)Math.Sin(seconds * 0.018 + star.Phase) * 3;
                }
                horizontal += horizontalShift * (4 + star.Depth * 14);
                vertical += verticalShift * (4 + star.Depth * 14);
                float shimmer = (float)(0.97 + Math.Sin(seconds * 0.18 + star.Phase) * 0.03);
                DrawStar(horizontal, vertical, star, star.Flux * shimmer);
            }
            BitmapData data = image.LockBits(new Rectangle(Point.Empty, image.Size), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
            try { Marshal.Copy(pixels, 0, data.Scan0, pixels.Length); }
            finally { image.UnlockBits(data); }
            GraphicsState original = graphics.Save();
            try
            {
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.DrawImageUnscaled(image, 0, 0);
            }
            finally { graphics.Restore(original); }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (image != null) { image.Dispose(); image = null; }
            background = null;
            pixels = null;
        }
    }

    public sealed class StarfieldForm : Form
    {
        private readonly Timer animationTimer;
        private readonly Stopwatch animationClock = new Stopwatch();
        private StarfieldRenderer renderer;
        private Bitmap frame;
        private bool active, resizing, failed, disposing;
        private bool motionEnabled = true;
        private bool animationsAllowed;
        private bool highContrast;
        private double lastTick, sceneTime;
        private PointF smoothPointer = new PointF(0.5f, 0.5f);
        private float pointerInfluence;

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SystemParametersInfo(uint action, uint parameter, [MarshalAs(UnmanagedType.Bool)] out bool value, uint flags);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int valueSize);

        public event EventHandler AppearanceChanged;
        public event EventHandler MotionStateChanged;

        public StarfieldForm()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            animationTimer = new Timer();
            animationTimer.Interval = 33;
            animationTimer.Tick += AnimateBackground;
            RefreshPreferences();
        }

        public bool SceneEnabled { get { return !highContrast && !failed; } }
        public bool MotionAvailable { get { return SceneEnabled && animationsAllowed; } }
        public bool IsAnimationRunning { get { return !disposing && animationTimer.Enabled; } }
        public double SceneTime { get { return sceneTime; } }
        public long RenderedFrameCount { get; private set; }
        public bool MotionEnabled
        {
            get { return motionEnabled; }
            set
            {
                if (motionEnabled == value) return;
                motionEnabled = value;
                UpdateAnimationState();
                if (MotionStateChanged != null) MotionStateChanged(this, EventArgs.Empty);
            }
        }

        public void RefreshPreferences()
        {
            bool clientAnimations;
            bool preferenceRead = SystemParametersInfo(0x1042, 0, out clientAnimations, 0);
            ApplyPreferences(SystemInformation.HighContrast, preferenceRead && clientAnimations, SystemInformation.TerminalServerSession);
        }

        private void ApplyPreferences(bool useHighContrast, bool useAnimations, bool remoteSession)
        {
            highContrast = useHighContrast;
            animationsAllowed = useAnimations && !remoteSession;
            UpdateWindowChrome();
            UpdateAnimationState();
            if (AppearanceChanged != null) AppearanceChanged(this, EventArgs.Empty);
            if (MotionStateChanged != null) MotionStateChanged(this, EventArgs.Empty);
            if (Visible) RefreshScene();
        }

        private void UpdateWindowChrome()
        {
            if (!IsHandleCreated || disposing) return;
            int dark = SceneEnabled ? 1 : 0;
            try { DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int)); }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }

        private void UpdateAnimationState()
        {
            if (animationTimer == null || disposing) return;
            bool shouldRun = MotionEnabled && MotionAvailable && active && Visible && !resizing && WindowState != FormWindowState.Minimized;
            if (shouldRun)
            {
                if (!animationTimer.Enabled)
                {
                    animationClock.Restart();
                    lastTick = 0;
                    animationTimer.Start();
                }
            }
            else
            {
                animationTimer.Stop();
                animationClock.Stop();
            }
        }

        private void AnimateBackground(object sender, EventArgs arguments)
        {
            double now = animationClock.Elapsed.TotalSeconds;
            double elapsed = Math.Min(0.1, Math.Max(0, now - lastTick));
            lastTick = now;
            sceneTime += elapsed;
            Point pointer = PointToClient(Control.MousePosition);
            bool inside = ClientRectangle.Contains(pointer);
            PointF target = inside ? new PointF(pointer.X / (float)Math.Max(1, ClientSize.Width), pointer.Y / (float)Math.Max(1, ClientSize.Height)) : new PointF(0.5f, 0.5f);
            float blend = (float)(1 - Math.Exp(-elapsed * 2.8));
            smoothPointer.X += (target.X - smoothPointer.X) * blend;
            smoothPointer.Y += (target.Y - smoothPointer.Y) * blend;
            pointerInfluence += ((inside ? 1 : 0) - pointerInfluence) * blend;
            RefreshScene();
        }

        public void RefreshScene()
        {
            if (disposing || !IsHandleCreated || !Visible || WindowState == FormWindowState.Minimized) return;
            if (!SceneEnabled) { InvalidateSurfaces(this); return; }
            Stopwatch renderClock = Stopwatch.StartNew();
            try
            {
                if (renderer == null) renderer = new StarfieldRenderer();
                float scale = Math.Min(1, 1920f / Math.Max(1, Math.Max(ClientSize.Width, ClientSize.Height)));
                Size size = new Size(Math.Max(1, (int)(ClientSize.Width * scale)), Math.Max(1, (int)(ClientSize.Height * scale)));
                if (frame == null || frame.Size != size)
                {
                    Bitmap replacement = new Bitmap(size.Width, size.Height, PixelFormat.Format32bppPArgb);
                    if (frame != null) frame.Dispose();
                    frame = replacement;
                }
                using (Graphics graphics = Graphics.FromImage(frame)) renderer.Render(graphics, size, sceneTime, smoothPointer, pointerInfluence);
                RenderedFrameCount++;
                renderClock.Stop();
                int minimumInterval = SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline ? 50 : 33;
                animationTimer.Interval = Math.Max(minimumInterval, Math.Min(100, (int)(renderClock.Elapsed.TotalMilliseconds * 3)));
            }
            catch (Exception failure)
            {
                if (!(failure is ArgumentException || failure is ExternalException || failure is OutOfMemoryException)) throw;
                failed = true;
                animationTimer.Stop();
                if (renderer != null) { renderer.Dispose(); renderer = null; }
                if (frame != null) { frame.Dispose(); frame = null; }
                UpdateWindowChrome();
                if (AppearanceChanged != null) AppearanceChanged(this, EventArgs.Empty);
                if (MotionStateChanged != null) MotionStateChanged(this, EventArgs.Empty);
            }
            InvalidateSurfaces(this);
        }

        private static void InvalidateSurfaces(Control control)
        {
            if (control is TextBoxBase || control is ListBox || control is ComboBox || control is DataGridView || control is Button) return;
            control.Invalidate();
            foreach (Control child in control.Controls) InvalidateSurfaces(child);
        }

        public bool PaintScene(Control surface, Graphics graphics)
        {
            if (!SceneEnabled || frame == null || disposing) return false;
            Point origin = surface == this ? Point.Empty : PointToClient(surface.PointToScreen(Point.Empty));
            float scaleHorizontal = frame.Width / (float)Math.Max(1, ClientSize.Width);
            float scaleVertical = frame.Height / (float)Math.Max(1, ClientSize.Height);
            Rectangle destination = surface.ClientRectangle;
            RectangleF source = new RectangleF(origin.X * scaleHorizontal, origin.Y * scaleVertical, destination.Width * scaleHorizontal, destination.Height * scaleVertical);
            graphics.DrawImage(frame, destination, source, GraphicsUnit.Pixel);
            return true;
        }

        protected override void OnPaintBackground(PaintEventArgs arguments)
        {
            if (!PaintScene(this, arguments.Graphics)) base.OnPaintBackground(arguments);
        }

        protected override void OnHandleCreated(EventArgs arguments)
        {
            base.OnHandleCreated(arguments);
            UpdateWindowChrome();
        }

        protected override void OnShown(EventArgs arguments)
        {
            base.OnShown(arguments);
            StarfieldForm owner = Owner as StarfieldForm;
            if (owner != null) MotionEnabled = owner.MotionEnabled;
            RefreshScene();
            UpdateAnimationState();
        }

        protected override void OnActivated(EventArgs arguments)
        {
            base.OnActivated(arguments);
            active = true;
            UpdateAnimationState();
        }

        protected override void OnDeactivate(EventArgs arguments)
        {
            active = false;
            UpdateAnimationState();
            base.OnDeactivate(arguments);
        }

        protected override void OnVisibleChanged(EventArgs arguments)
        {
            base.OnVisibleChanged(arguments);
            UpdateAnimationState();
        }

        protected override void OnResize(EventArgs arguments)
        {
            base.OnResize(arguments);
            if (animationTimer == null) return;
            UpdateAnimationState();
            if (!resizing) RefreshScene();
        }

        protected override void OnResizeBegin(EventArgs arguments)
        {
            resizing = true;
            UpdateAnimationState();
            base.OnResizeBegin(arguments);
        }

        protected override void OnResizeEnd(EventArgs arguments)
        {
            resizing = false;
            RefreshScene();
            UpdateAnimationState();
            base.OnResizeEnd(arguments);
        }

        protected override void WndProc(ref Message message)
        {
            base.WndProc(ref message);
            if ((message.Msg == 0x001A || message.Msg == 0x0015) && animationTimer != null && !disposing) RefreshPreferences();
        }

        protected override void Dispose(bool managed)
        {
            if (managed && !disposing)
            {
                disposing = true;
                animationTimer.Stop();
                animationTimer.Dispose();
                animationClock.Stop();
                if (frame != null) { frame.Dispose(); frame = null; }
                if (renderer != null) { renderer.Dispose(); renderer = null; }
            }
            base.Dispose(managed);
        }
    }

    public sealed class SpaceTableLayoutPanel : TableLayoutPanel
    {
        public SpaceTableLayoutPanel() { DoubleBuffered = true; BackColor = Color.Transparent; }
        protected override void OnPaintBackground(PaintEventArgs arguments)
        {
            StarfieldForm form = FindForm() as StarfieldForm;
            if (form == null || !form.PaintScene(this, arguments.Graphics)) base.OnPaintBackground(arguments);
        }
    }

    public sealed class SpaceFlowLayoutPanel : FlowLayoutPanel
    {
        public SpaceFlowLayoutPanel() { DoubleBuffered = true; BackColor = Color.Transparent; }
        protected override void OnPaintBackground(PaintEventArgs arguments)
        {
            StarfieldForm form = FindForm() as StarfieldForm;
            if (form == null || !form.PaintScene(this, arguments.Graphics)) base.OnPaintBackground(arguments);
        }
    }

    public sealed class SpacePanel : Panel
    {
        public SpacePanel() { DoubleBuffered = true; BackColor = Color.Transparent; }
        protected override void OnLayout(LayoutEventArgs arguments)
        {
            base.OnLayout(arguments);
            if (AutoScroll && Controls.Count == 1)
            {
                Control content = Controls[0];
                int height = content.GetPreferredSize(new Size(content.Width, 0)).Height + content.Margin.Vertical;
                if (AutoScrollMinSize.Height != height) AutoScrollMinSize = new Size(0, height);
                AdjustFormScrollbars(true);
            }
        }
        protected override void OnPaintBackground(PaintEventArgs arguments)
        {
            StarfieldForm form = FindForm() as StarfieldForm;
            if (form == null || !form.PaintScene(this, arguments.Graphics)) base.OnPaintBackground(arguments);
        }
    }

    public sealed class IconCheckBox : CheckBox
    {
        public override Size GetPreferredSize(Size proposedSize)
        {
            Size preferred = base.GetPreferredSize(proposedSize);
            if (Image == null) return preferred;
            Size text = TextRenderer.MeasureText(Text.Replace("&", ""), Font);
            int width = text.Width + Image.Width + Padding.Horizontal + Math.Max(18, Font.Height) + 6;
            return new Size(Math.Max(preferred.Width, width), Math.Max(preferred.Height, Image.Height + Padding.Vertical + 4));
        }
    }
}
'@
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($typeSource))).Replace('-', '').Substring(0, 24) }
    finally { $hash.Dispose() }
    $uiNamespace = 'EasyEdgeApps.Native_' + $fingerprint
    if (-not (($uiNamespace + '.StarfieldForm') -as [type])) {
        Add-Type -ReferencedAssemblies $references -TypeDefinition $typeSource.Replace('namespace EasyEdgeApps', ('namespace ' + $uiNamespace)) -ErrorAction Stop
    }
    return $uiNamespace
}

function Set-EeaSpaceTheme {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, $Control = $Form)

    $space = $Form.SceneEnabled
    $foreground = if ($space) { [Drawing.Color]::FromArgb(235, 241, 245) } else { [Drawing.SystemColors]::WindowText }
    $surface = if ($space) { [Drawing.Color]::FromArgb(17, 23, 28) } else { [Drawing.SystemColors]::Window }
    $border = if ($space) { [Drawing.Color]::FromArgb(65, 78, 87) } else { [Drawing.SystemColors]::ControlDark }
    $primary = $null
    if ($null -ne $Form.Tag) {
        if ($null -ne $Form.Tag.PSObject.Properties['SaveButton']) { $primary = $Form.Tag.SaveButton }
        elseif ($null -ne $Form.Tag.PSObject.Properties['ApplyButton']) { $primary = $Form.Tag.ApplyButton }
    }
    if ($Control -is [Windows.Forms.Button]) {
        if (-not [object]::ReferenceEquals($Control, $primary)) {
            $Control.ForeColor = if ($space) { $foreground } else { [Drawing.SystemColors]::ControlText }
            $Control.BackColor = if ($space) { [Drawing.Color]::FromArgb(28, 36, 42) } else { [Drawing.SystemColors]::Control }
            $Control.FlatStyle = if ($space) { [Windows.Forms.FlatStyle]::Flat } else { [Windows.Forms.FlatStyle]::Standard }
            $Control.UseVisualStyleBackColor = -not $space
            $Control.FlatAppearance.BorderColor = $border
            $Control.FlatAppearance.MouseOverBackColor = if ($space) { [Drawing.Color]::FromArgb(43, 56, 65) } else { [Drawing.Color]::Empty }
            $Control.FlatAppearance.MouseDownBackColor = if ($space) { [Drawing.Color]::FromArgb(51, 67, 78) } else { [Drawing.Color]::Empty }
        }
        return
    }
    $Control.ForeColor = $foreground
    if ($Control -is [Windows.Forms.Form]) { $Control.BackColor = if ($space) { [Drawing.Color]::FromArgb(4, 8, 12) } else { $surface } }
    elseif ($Control -is [Windows.Forms.TextBoxBase] -or $Control -is [Windows.Forms.ListBox]) {
        $Control.BackColor = $surface
        $Control.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    }
    elseif ($Control -is [Windows.Forms.ComboBox]) {
        $Control.BackColor = $surface
        $Control.FlatStyle = if ($space) { [Windows.Forms.FlatStyle]::Flat } else { [Windows.Forms.FlatStyle]::Standard }
    }
    elseif ($Control -is [Windows.Forms.DataGridView]) {
        $Control.BackgroundColor = $surface
        $Control.GridColor = $border
        $Control.EnableHeadersVisualStyles = -not $space
        $Control.DefaultCellStyle.BackColor = $surface
        $Control.DefaultCellStyle.ForeColor = $foreground
        $Control.DefaultCellStyle.SelectionBackColor = [Drawing.SystemColors]::Highlight
        $Control.DefaultCellStyle.SelectionForeColor = [Drawing.SystemColors]::HighlightText
        $Control.ColumnHeadersDefaultCellStyle.BackColor = if ($space) { [Drawing.Color]::FromArgb(28, 36, 42) } else { [Drawing.SystemColors]::Control }
        $Control.ColumnHeadersDefaultCellStyle.ForeColor = $foreground
        return
    }
    elseif ($space -and ($Control -is [Windows.Forms.Label] -or $Control -is [Windows.Forms.CheckBox])) {
        $Control.BackColor = [Drawing.Color]::FromArgb(160, 4, 8, 12)
    }
    else { $Control.BackColor = [Drawing.Color]::Transparent }
    foreach ($child in $Control.Controls) { Set-EeaSpaceTheme -Form $Form -Control $child }
}

function Enable-EeaSpaceTheme {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $Form.Add_AppearanceChanged({ param($Sender, $EventArgs) Set-EeaSpaceTheme $Sender })
    Set-EeaSpaceTheme $Form
}

function New-EeaSymbolImage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Icon, [Parameter(Mandatory = $true)][int]$Size, [Parameter(Mandatory = $true)]$Color)

    $symbols = @{
        Apps = 0xE71D; Add = 0xE710; Save = 0xE74E; Open = 0xE8A7; Remove = 0xE74D
        Export = 0xE898; Import = 0xE896; Favorites = 0xE734; Check = 0xE73E; Repair = 0xE90F
        Refresh = 0xE72C; Close = 0xE711; Image = 0xEB9F; Name = 0xE8AC; Link = 0xE71B
        Notes = 0xE70B; Privacy = 0xEA18; Lock = 0xE72E; Unlock = 0xE785; Info = 0xE946
        Desktop = 0xE7F4; Start = 0xE8FC; SelectAll = 0xE8B3; Motion = 0xE768
    }
    if (-not $symbols.ContainsKey($Icon)) { throw 'An interface icon is not recognized.' }
    $font = $null
    $bitmap = $null
    $graphics = $null
    $brush = $null
    $format = $null
    try {
        foreach ($fontName in @('Segoe Fluent Icons', 'Segoe MDL2 Assets')) {
            $candidate = New-Object Drawing.Font($fontName, [single]($Size * 0.85), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
            if ($candidate.Name -eq $fontName) { $font = $candidate; break }
            $candidate.Dispose()
        }
        if ($null -eq $font) { return $null }
        $bitmap = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $brush = New-Object Drawing.SolidBrush($Color)
        $format = [Drawing.StringFormat]::GenericTypographic.Clone()
        $format.Alignment = [Drawing.StringAlignment]::Center
        $format.LineAlignment = [Drawing.StringAlignment]::Center
        $graphics.DrawString(([char]$symbols[$Icon]).ToString(), $font, $brush, (New-Object Drawing.RectangleF(0, 0, $Size, $Size)), $format)
        $bitmap.Tag = $Icon
        return $bitmap
    }
    catch { if ($null -ne $bitmap) { $bitmap.Dispose() }; throw }
    finally {
        if ($null -ne $format) { $format.Dispose() }
        if ($null -ne $brush) { $brush.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $font) { $font.Dispose() }
    }
}

function Set-EeaControlIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Control, [Parameter(Mandatory = $true)][string]$Icon)

    if ($Control.IsDisposed) { return }
    $size = [Math]::Max(16, [Math]::Min(64, $Control.Font.Height - 2))
    $color = if ($Control.Enabled) { $Control.ForeColor } else { [Drawing.SystemColors]::GrayText }
    $image = New-EeaSymbolImage -Icon $Icon -Size $size -Color $color
    if ($null -eq $image) { return }
    $isLabel = $Control -is [Windows.Forms.Label]
    $previousImage = if ($isLabel) { $Control.Tag } else { $Control.Image }
    if ($isLabel) {
        $Control.Tag = $image
        $Control.Padding = New-Object Windows.Forms.Padding(($size + [Math]::Max(6, [int][Math]::Round($size / 4.0))), 0, 0, 0)
        $Control.Invalidate()
    }
    else { $Control.Image = $image }
    if ($null -ne $previousImage) { $previousImage.Dispose() }
    else {
        $refresh = {
            param($Sender, $EventArgs)
            if ($Sender.IsDisposed) { return }
            $currentImage = if ($Sender -is [Windows.Forms.Label]) { $Sender.Tag } else { $Sender.Image }
            if ($null -ne $currentImage) { Set-EeaControlIcon -Control $Sender -Icon $currentImage.Tag }
        }
        $Control.Add_FontChanged($refresh)
        $Control.Add_ForeColorChanged($refresh)
        $Control.Add_EnabledChanged($refresh)
        $Control.Add_SystemColorsChanged($refresh)
        $Control.Add_Disposed({
            param($Sender, $EventArgs)
            if ($Sender -is [Windows.Forms.Label]) {
                if ($null -ne $Sender.Tag) { $Sender.Tag.Dispose(); $Sender.Tag = $null }
            }
            elseif ($null -ne $Sender.Image) { $Sender.Image.Dispose(); $Sender.Image = $null }
        })
    }
}

function New-EeaLabel {
    [CmdletBinding()]
    param([string]$Text = '', [string]$Icon = 'Info')

    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.Text = $Text
    $label.UseMnemonic = $true
    $label.Add_Paint({
        param($Sender, $EventArgs)
        if ($null -ne $Sender.Tag) {
            $offset = [Math]::Max(0, [int][Math]::Floor(($Sender.Font.Height - $Sender.Tag.Height) / 2.0))
            $EventArgs.Graphics.DrawImageUnscaled($Sender.Tag, 0, $offset)
        }
    })
    $label.Add_PaddingChanged({
        param($Sender, $EventArgs)
        if ($null -ne $Sender.Tag) {
            $left = $Sender.Tag.Width + [Math]::Max(6, [int][Math]::Round($Sender.Tag.Width / 4.0))
            if ($Sender.Padding.Left -ne $left) { $Sender.Padding = New-Object Windows.Forms.Padding($left, 0, 0, 0) }
        }
    })
    Set-EeaControlIcon -Control $label -Icon $Icon
    return $label
}

function New-EeaCheckBox {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Icon)

    $uiNamespace = Initialize-EeaSpaceBackground
    $checkBox = New-Object ($uiNamespace + '.IconCheckBox')
    $checkBox.AutoSize = $true
    $checkBox.Text = $Text
    $checkBox.TextImageRelation = [Windows.Forms.TextImageRelation]::ImageBeforeText
    $checkBox.ImageAlign = [Drawing.ContentAlignment]::MiddleLeft
    Set-EeaControlIcon -Control $checkBox -Icon $Icon
    return $checkBox
}

function Set-EeaPrimaryButton {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Button)

    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $refresh = {
        param($Sender, $EventArgs)
        if ($Sender.IsDisposed) { return }
        if ($Sender.Enabled) {
            $Sender.BackColor = [Drawing.SystemColors]::Highlight
            $Sender.ForeColor = [Drawing.SystemColors]::HighlightText
            $Sender.FlatAppearance.BorderColor = [Drawing.SystemColors]::Highlight
        }
        else {
            $Sender.BackColor = [Drawing.SystemColors]::Control
            $Sender.ForeColor = [Drawing.SystemColors]::GrayText
            $Sender.FlatAppearance.BorderColor = [Drawing.SystemColors]::ControlDark
        }
    }
    $Button.Add_EnabledChanged($refresh)
    $Button.Add_SystemColorsChanged($refresh)
    & $refresh $Button ([EventArgs]::Empty)
}

function New-EeaTextBox {
    [CmdletBinding()]
    param()

    $textBox = New-Object Windows.Forms.TextBox
    $textBox.Add_KeyDown({
        param($Sender, $EventArgs)
        if ($EventArgs.KeyCode -ne [Windows.Forms.Keys]::Back -or -not $EventArgs.Control -or $EventArgs.Alt) { return }
        $EventArgs.SuppressKeyPress = $true
        if ($Sender.ReadOnly) { return }
        if ($Sender.SelectionLength -eq 0) {
            $end = $Sender.SelectionStart
            if ($end -eq 0) { return }
            $text = $Sender.Text
            $start = $end
            while ($start -gt 0 -and [char]::IsWhiteSpace($text[$start - 1])) { $start-- }
            while ($start -gt 0 -and -not [char]::IsWhiteSpace($text[$start - 1])) { $start-- }
            $Sender.Select($start, $end - $start)
        }
        $Sender.Paste([string]::Empty)
    })
    return $textBox
}

function New-EeaButton {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text, [string]$Icon = 'Apps', [string]$AccessibleName)

    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    if ($AccessibleName) {
        $button.AccessibleName = $AccessibleName
        $toolTip = New-Object Windows.Forms.ToolTip
        $toolTip.SetToolTip($button, $AccessibleName)
        $button.Add_Disposed({ param($Sender, $EventArgs) $toolTip.Dispose() }.GetNewClosure())
    }
    $button.AutoSize = $true
    $button.MinimumSize = New-Object Drawing.Size(110, 40)
    $button.Padding = New-Object Windows.Forms.Padding(8, 2, 8, 2)
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $button.UseVisualStyleBackColor = $true
    $button.TextImageRelation = [Windows.Forms.TextImageRelation]::ImageBeforeText
    $button.ImageAlign = [Drawing.ContentAlignment]::MiddleLeft
    Set-EeaControlIcon -Control $button -Icon $Icon
    return $button
}

function Set-EeaEditorIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [string]$CustomIcon, [byte[]]$IconData)

    $ui = $Form.Tag
    $bitmap = $null
    $caption = 'Automatic'
    $website = $null
    if ($null -ne $IconData) {
        $website = ConvertTo-EeaWebsite $ui.UrlInput.Text
        $bitmap = Get-EeaIconPreview -IconData $IconData
        $caption = 'Website icon'
    }
    elseif ($CustomIcon) {
        $bitmap = Get-EeaIconPreview -Path $CustomIcon
        $caption = [IO.Path]::GetFileName($CustomIcon)
    }
    elseif ($ui.AppList.SelectedIndex -ge 0) {
        $paths = Get-EeaPaths $ui.Context $ui.AppList.SelectedItem.Name
        $bitmap = Get-EeaIconPreview -Path $paths.Icon
        $caption = 'Saved icon'
    }
    $previous = $ui.IconPreview.Image
    $ui.IconPreview.Image = $bitmap
    $ui.CustomIcon = $CustomIcon
    $ui.WebsiteIconData = $IconData
    $ui.WebsiteIconUrl = $website
    $ui.IconLabel.Text = $caption
    if ($null -ne $previous) { $previous.Dispose() }
}

function Stop-EeaWebsiteIconLookup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $ui = $Form.Tag
    if ($null -ne $ui.IconRequest) {
        $ui.IconRequest.Discard = $true
        $ui.IconRequest.Cancellation.Cancel()
        $ui.CancelIconButton.Enabled = $false
        $ui.StatusLabel.Text = 'Cancelling icon lookup...'
    }
}

function Complete-EeaWebsiteIconLookup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $ui = $Form.Tag
    $request = $ui.IconRequest
    if ($null -eq $request -or -not $request.AsyncResult.IsCompleted) { return }
    try {
        $result = @($request.PowerShell.EndInvoke($request.AsyncResult))
        if (-not $request.Discard -and -not $request.Cancellation.IsCancellationRequested -and
            (ConvertTo-EeaWebsite $ui.UrlInput.Text) -ceq $request.Website) {
            if ($result.Count -ne 1) { throw 'The website did not return an icon.' }
            Set-EeaEditorIcon -Form $Form -IconData $result[0].Bytes
            $ui.StatusLabel.Text = 'Website icon retrieved.'
        }
        else { $ui.StatusLabel.Text = 'Icon lookup cancelled.' }
    }
    catch {
        $ui.StatusLabel.Text = if ($request.Discard -or $request.Cancellation.IsCancellationRequested) { 'Icon lookup cancelled.' }
            else { 'Could not retrieve an icon. Your current icon has not changed.' }
    }
    finally {
        $request.PowerShell.Dispose()
        $request.Cancellation.Dispose()
        $ui.IconRequest = $null
        $ui.IconTimer.Stop()
        $ui.GetIconButton.Enabled = $true
        $ui.CancelIconButton.Enabled = $false
        $ui.SaveButton.Enabled = $true
    }
    if ($ui.CloseAfterIconLookup) { $Form.Close() }
}

function Reset-EeaEditor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $ui = $Form.Tag
    Stop-EeaWebsiteIconLookup $Form
    $ui.AppList.SelectedIndex = -1
    $ui.NameInput.ReadOnly = $false
    $ui.NameInput.Clear()
    $ui.UrlInput.Clear()
    $ui.NotesInput.Clear()
    $ui.DesktopCheck.Checked = $true
    $ui.StartMenuCheck.Checked = $true
    $ui.CustomIcon = $null
    $ui.WebsiteIconData = $null
    $ui.WebsiteIconUrl = $null
    $ui.IconLabel.Text = 'Automatic'
    if ($null -ne $ui.IconPreview.Image) { $ui.IconPreview.Image.Dispose(); $ui.IconPreview.Image = $null }
    $ui.SaveButton.Text = '&Add website'
    Set-EeaControlIcon -Control $ui.SaveButton -Icon Add
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
    param($Context = (Get-EeaContext), [string]$EdgeUserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'))

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'Open this script with powershell.exe -NoProfile -STA -File .\EasyEdgeApps.ps1 to use the setup window.'
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [Windows.Forms.Application]::EnableVisualStyles()
    $uiNamespace = Initialize-EeaSpaceBackground
    $form = New-Object ($uiNamespace + '.StarfieldForm')
    $form.Text = 'Easy Edge Apps'
    $form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(1000, 700)
    $form.MinimumSize = New-Object Drawing.Size(800, 640)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = [Drawing.SystemColors]::Window
    $form.ForeColor = [Drawing.SystemColors]::WindowText
    Set-EeaFormIcon $form
    $form.Padding = New-Object Windows.Forms.Padding(20)

    $layout = New-Object ($uiNamespace + '.SpaceTableLayoutPanel')
    $layout.Dock = [Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $form.Controls.Add($layout)

    $headingLayout = New-Object ($uiNamespace + '.SpaceTableLayoutPanel')
    $headingLayout.Dock = [Windows.Forms.DockStyle]::Fill
    $headingLayout.AutoSize = $true
    $headingLayout.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $headingLayout.Margin = New-Object Windows.Forms.Padding(0)
    $headingLayout.ColumnCount = 3
    $headingLayout.RowCount = 1
    [void]$headingLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 48)))
    [void]$headingLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$headingLayout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$headingLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $brandPicture = New-Object Windows.Forms.PictureBox
    $brandPicture.Size = New-Object Drawing.Size(32, 32)
    $brandPicture.Anchor = [Windows.Forms.AnchorStyles]::Left
    $brandPicture.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $brandPicture.Image = $form.Icon.ToBitmap()
    $brandPicture.AccessibleName = 'Easy Edge Apps logo'
    $brandPicture.TabStop = $false
    $brandPicture.Margin = New-Object Windows.Forms.Padding(0, 0, 12, 16)
    $headingLayout.Controls.Add($brandPicture, 0, 0)
    $heading = New-Object Windows.Forms.Label
    $heading.Text = 'Easy Edge Apps'
    $heading.Font = New-Object Drawing.Font('Segoe UI', 20, [Drawing.FontStyle]::Bold)
    $heading.AutoSize = $true
    $heading.Anchor = [Windows.Forms.AnchorStyles]::Left
    $heading.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 16)
    $headingLayout.Controls.Add($heading, 1, 0)
    $motionCheck = New-EeaCheckBox '&Motion' -Icon Motion
    $motionCheck.AccessibleName = 'Animate the space background'
    $motionCheck.AccessibleDescription = 'Pause or resume background motion. Windows accessibility preferences take precedence.'
    $motionCheck.Anchor = [Windows.Forms.AnchorStyles]::Right
    $motionCheck.Margin = New-Object Windows.Forms.Padding(12, 0, 0, 16)
    $motionCheck.Enabled = $form.MotionAvailable
    $motionCheck.Checked = $form.MotionEnabled -and $form.MotionAvailable
    $motionCheck.Add_CheckedChanged({ param($Sender, $EventArgs) if ($Sender.Enabled) { $Sender.FindForm().MotionEnabled = $Sender.Checked } })
    $headingLayout.Controls.Add($motionCheck, 2, 0)
    $layout.Controls.Add($headingLayout, 0, 0)

    $content = New-Object ($uiNamespace + '.SpaceTableLayoutPanel')
    $content.Dock = [Windows.Forms.DockStyle]::Fill
    $content.ColumnCount = 2
    $content.RowCount = 1
    [void]$content.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 34)))
    [void]$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 66)))
    $layout.Controls.Add($content, 0, 1)

    $listPanel = New-Object ($uiNamespace + '.SpaceTableLayoutPanel')
    $listPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $listPanel.ColumnCount = 1
    $listPanel.RowCount = 3
    [void]$listPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $listPanel.Margin = New-Object Windows.Forms.Padding(0, 0, 16, 0)
    [void]$listPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$listPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$listPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $listLabel = New-EeaLabel -Icon Apps
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
    $newButton = New-EeaButton '&New' -Icon Add -AccessibleName 'New website'
    $newButton.TabIndex = 2
    $listPanel.Controls.Add($newButton, 0, 2)
    $content.Controls.Add($listPanel, 0, 0)

    $editorViewport = New-Object ($uiNamespace + '.SpacePanel')
    $editorViewport.Dock = [Windows.Forms.DockStyle]::Fill
    $editorViewport.AutoScroll = $true
    $content.Controls.Add($editorViewport, 1, 0)
    $editor = New-Object ($uiNamespace + '.SpaceTableLayoutPanel')
    $editor.Dock = [Windows.Forms.DockStyle]::Top
    $editor.AutoSize = $true
    $editor.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $editor.ColumnCount = 1
    $editor.RowCount = 10
    [void]$editor.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    for ($rowIndex = 0; $rowIndex -lt 10; $rowIndex++) {
        [void]$editor.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    }
    $editorViewport.Controls.Add($editor)
    $nameLabel = New-EeaLabel -Icon Name
    $nameLabel.Text = '&Name'
    $nameLabel.AutoSize = $true
    $nameLabel.TabIndex = 0
    $editor.Controls.Add($nameLabel, 0, 0)
    $nameInput = New-EeaTextBox
    $nameInput.Dock = [Windows.Forms.DockStyle]::Top
    $nameInput.MaxLength = 60
    $nameInput.AccessibleName = 'Website name'
    $nameInput.TabIndex = 1
    $nameInput.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $editor.Controls.Add($nameInput, 0, 1)
    $urlLabel = New-EeaLabel -Icon Link
    $urlLabel.Text = 'Website &address'
    $urlLabel.AutoSize = $true
    $urlLabel.TabIndex = 2
    $editor.Controls.Add($urlLabel, 0, 2)
    $urlInput = New-EeaTextBox
    $urlInput.Dock = [Windows.Forms.DockStyle]::Top
    $urlInput.MaxLength = 2048
    $urlInput.AccessibleName = 'Website address starting with https'
    $urlInput.TabIndex = 3
    $urlInput.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $editor.Controls.Add($urlInput, 0, 3)

    $notesLabel = New-EeaLabel -Icon Notes
    $notesLabel.Text = 'Helper &notes (optional)'
    $notesLabel.AutoSize = $true
    $notesLabel.TabIndex = 4
    $editor.Controls.Add($notesLabel, 0, 4)
    $notesInput = New-EeaTextBox
    $notesInput.Multiline = $true
    $notesInput.AcceptsReturn = $true
    $notesInput.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    $notesInput.Dock = [Windows.Forms.DockStyle]::Top
    $notesInput.Height = 88
    $notesInput.MaxLength = 4000
    $notesInput.AccessibleName = 'Plain-text helper notes'
    $notesInput.TabIndex = 5
    $notesInput.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $editor.Controls.Add($notesInput, 0, 5)

    $placement = New-Object ($uiNamespace + '.SpaceFlowLayoutPanel')
    $placement.AutoSize = $true
    $placement.Dock = [Windows.Forms.DockStyle]::Fill
    $placement.TabIndex = 6
    $desktopCheck = New-EeaCheckBox '&Desktop' -Icon Desktop
    $desktopCheck.AutoSize = $true
    $desktopCheck.Checked = $true
    $desktopCheck.Margin = New-Object Windows.Forms.Padding(0, 0, 20, 8)
    $startMenuCheck = New-EeaCheckBox 'Start &menu' -Icon Start
    $startMenuCheck.AutoSize = $true
    $startMenuCheck.Checked = $true
    $placement.Controls.AddRange([Windows.Forms.Control[]]@($desktopCheck, $startMenuCheck))
    $editor.Controls.Add($placement, 0, 6)

    $iconPanel = New-Object ($uiNamespace + '.SpaceFlowLayoutPanel')
    $iconPanel.AutoSize = $true
    $iconPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $iconPanel.TabIndex = 7
    $iconPreview = New-Object Windows.Forms.PictureBox
    $iconPreview.Size = New-Object Drawing.Size(48, 48)
    $iconPreview.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $iconPreview.AccessibleName = 'Website icon'
    $iconPreview.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $getIconButton = New-EeaButton '&Get icon' -Icon Import -AccessibleName 'Get website icon'
    $getIconButton.AccessibleDescription = 'Retrieve the icon from the website address without browser cookies or passwords.'
    $cancelIconButton = New-EeaButton '' -Icon Close -AccessibleName 'Cancel icon lookup'
    $cancelIconButton.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $cancelIconButton.MinimumSize = New-Object Drawing.Size(40, 40)
    $cancelIconButton.Size = New-Object Drawing.Size(40, 40)
    $cancelIconButton.ImageAlign = [Drawing.ContentAlignment]::MiddleCenter
    $cancelIconButton.Enabled = $false
    $iconButton = New-EeaButton 'Choose &icon...' -Icon Image
    $clearIconButton = New-EeaButton 'Use &saved icon' -Icon Image
    $iconPanel.Controls.AddRange([Windows.Forms.Control[]]@($iconPreview, $getIconButton, $cancelIconButton, $iconButton, $clearIconButton))
    $editor.Controls.Add($iconPanel, 0, 7)
    $iconLabel = New-EeaLabel -Icon Image
    $iconLabel.AutoSize = $true
    $iconLabel.Text = 'Automatic'
    $iconLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 16)
    $editor.Controls.Add($iconLabel, 0, 8)

    $actions = New-Object ($uiNamespace + '.SpaceFlowLayoutPanel')
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Top
    $actions.TabIndex = 8
    $saveButton = New-EeaButton '&Add website' -Icon Add
    Set-EeaPrimaryButton $saveButton
    $openButton = New-EeaButton '&Open' -Icon Open
    $removeButton = New-EeaButton '&Remove...' -Icon Remove
    $openButton.Enabled = $false
    $removeButton.Enabled = $false
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($saveButton, $openButton, $removeButton))
    $editor.Controls.Add($actions, 0, 9)

    $statusLabel = New-EeaLabel -Icon Info
    $statusLabel.AutoSize = $true
    $statusLabel.Dock = [Windows.Forms.DockStyle]::Fill
    $statusLabel.AccessibleName = 'Status'
    $statusLabel.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 12)
    $statusLabel.Text = 'Ready'
    $layout.Controls.Add($statusLabel, 0, 2)
    $closeButton = New-EeaButton '&Close' -Icon Close
    $closeButton.Anchor = [Windows.Forms.AnchorStyles]::Right
    $closeButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $footer = New-Object ($uiNamespace + '.SpaceFlowLayoutPanel')
    $footer.Dock = [Windows.Forms.DockStyle]::Fill
    $footer.AutoSize = $true
    $exportButton = New-EeaButton '&Export kit...' -Icon Export -AccessibleName 'Export App Kit'
    $importButton = New-EeaButton '&Import kit...' -Icon Import -AccessibleName 'Import App Kit'
    $favoritesButton = New-EeaButton '&Favorites...' -Icon Favorites -AccessibleName 'Edge Favorites bar'
    $checkButton = New-EeaButton 'C&heck apps...' -Icon Check -AccessibleName 'Check and Repair Apps'
    $footer.Controls.AddRange([Windows.Forms.Control[]]@($exportButton, $importButton, $favoritesButton, $checkButton, $closeButton))
    $layout.Controls.Add($footer, 0, 3)
    $form.AcceptButton = $saveButton
    $form.CancelButton = $closeButton
    $iconTimer = New-Object Windows.Forms.Timer
    $iconTimer.Interval = 100
    $iconTimer.Tag = $form
    $iconTimer.Add_Tick({ param($Sender, $EventArgs) Complete-EeaWebsiteIconLookup $Sender.Tag })
    $form.Tag = [pscustomobject]@{
        Context = $Context; AppList = $appList; NameInput = $nameInput; UrlInput = $urlInput; NotesInput = $notesInput
        DesktopCheck = $desktopCheck; StartMenuCheck = $startMenuCheck; CustomIcon = $null
        WebsiteIconData = $null; WebsiteIconUrl = $null; IconRequest = $null; IconTimer = $iconTimer; CloseAfterIconLookup = $false
        GetIconButton = $getIconButton; CancelIconButton = $cancelIconButton; ChooseIconButton = $iconButton; ClearIconButton = $clearIconButton
        IconPreview = $iconPreview; IconLabel = $iconLabel; StatusLabel = $statusLabel
        SaveButton = $saveButton; OpenButton = $openButton; RemoveButton = $removeButton
        NewButton = $newButton; CloseButton = $closeButton
        EditorViewport = $editorViewport; BrandPicture = $brandPicture; MotionCheck = $motionCheck
        ExportButton = $exportButton; ImportButton = $importButton; FavoritesButton = $favoritesButton; CheckButton = $checkButton
        EdgeUserDataPath = $EdgeUserDataPath
    }
    $form.Add_MotionStateChanged({
        param($Sender, $EventArgs)
        $check = $Sender.Tag.MotionCheck
        $check.Enabled = $Sender.MotionAvailable
        $check.Checked = $Sender.MotionEnabled -and $Sender.MotionAvailable
    })
    Enable-EeaSpaceTheme $form

    $appList.Add_SelectedIndexChanged({
        param($Sender, $EventArgs)
        if ($Sender.SelectedIndex -lt 0) { return }
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        $selected = $Sender.SelectedItem
        Stop-EeaWebsiteIconLookup $ownerForm
        $ui.NameInput.Text = $selected.Name
        $ui.NameInput.ReadOnly = $true
        $ui.UrlInput.Text = $selected.Url
        $ui.NotesInput.Text = if ($null -ne $selected.PSObject.Properties['Notes']) { $selected.Notes } else { '' }
        $ui.DesktopCheck.Checked = $selected.Desktop
        $ui.StartMenuCheck.Checked = $selected.StartMenu
        $ui.CustomIcon = $null
        $ui.WebsiteIconData = $null
        $ui.WebsiteIconUrl = $null
        $ui.IconLabel.Text = 'Saved icon'
        $ui.SaveButton.Text = '&Save changes'
        Set-EeaControlIcon -Control $ui.SaveButton -Icon Save
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
    $urlInput.Add_TextChanged({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        if ($null -eq $ownerForm -or $null -eq $ownerForm.Tag) { return }
        $ui = $ownerForm.Tag
        Stop-EeaWebsiteIconLookup $ownerForm
        if ($null -ne $ui.WebsiteIconData) {
            try { Set-EeaEditorIcon $ownerForm }
            catch { $ui.WebsiteIconData = $null; $ui.WebsiteIconUrl = $null; $ui.IconLabel.Text = 'Icon unavailable' }
        }
    })
    $getIconButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        try {
            if ($null -ne $ui.IconRequest) { return }
            $ui.IconRequest = Start-EeaWebsiteIconRequest -Website $ui.UrlInput.Text
            $ui.GetIconButton.Enabled = $false
            $ui.CancelIconButton.Enabled = $true
            $ui.SaveButton.Enabled = $false
            $ui.StatusLabel.Text = 'Retrieving website icon...'
            $ui.IconTimer.Start()
        }
        catch { Show-EeaFormError $ownerForm $_ }
    })
    $cancelIconButton.Add_Click({ param($Sender, $EventArgs) Stop-EeaWebsiteIconLookup $Sender.FindForm() })
    $iconButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        Stop-EeaWebsiteIconLookup $ownerForm
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Windows icons (*.ico)|*.ico'
        $dialog.Title = 'Choose a website icon'
        $dialog.CheckFileExists = $true
        try {
            if ($dialog.ShowDialog($ownerForm) -eq [Windows.Forms.DialogResult]::OK) {
                Set-EeaEditorIcon -Form $ownerForm -CustomIcon $dialog.FileName
            }
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally { $dialog.Dispose() }
    })
    $clearIconButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        Stop-EeaWebsiteIconLookup $ownerForm
        try { Set-EeaEditorIcon $ownerForm }
        catch { Show-EeaFormError $ownerForm $_ }
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
            if ($null -ne $ui.WebsiteIconData -and (ConvertTo-EeaWebsite $ui.UrlInput.Text) -cne $ui.WebsiteIconUrl) { throw 'The website address changed. Retrieve its icon again before saving.' }
            $ownerForm.UseWaitCursor = $true
            $ui.SaveButton.Enabled = $false
            $ui.StatusLabel.Text = 'Saving...'
            $ui.StatusLabel.Refresh()
            $installed = Install-EeaApp -AppName $cleanName -Website $ui.UrlInput.Text -Notes $ui.NotesInput.Text -CustomIcon $ui.CustomIcon -IconData $ui.WebsiteIconData -Desktop $ui.DesktopCheck.Checked -StartMenu $ui.StartMenuCheck.Checked -Context $ui.Context -Confirm:$false
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
    $form.Add_FormClosing({
        param($Sender, $EventArgs)
        if ($null -ne $Sender.Tag.IconRequest) {
            $Sender.Tag.CloseAfterIconLookup = $true
            Stop-EeaWebsiteIconLookup $Sender
            $EventArgs.Cancel = $true
            $Sender.DialogResult = [Windows.Forms.DialogResult]::None
        }
    })
    $form.Add_Disposed({
        param($Sender, $EventArgs)
        $Sender.Tag.IconTimer.Stop()
        $Sender.Tag.IconTimer.Dispose()
        $Sender.Tag.IconTimer.Tag = $null
        $request = $Sender.Tag.IconRequest
        if ($null -ne $request) {
            $request.Cancellation.Cancel()
            try { $request.PowerShell.Stop() }
            finally { $request.PowerShell.Dispose(); $request.Cancellation.Dispose(); $Sender.Tag.IconRequest = $null }
        }
        if ($null -ne $Sender.Tag.IconPreview.Image) { $Sender.Tag.IconPreview.Image.Dispose() }
        if ($null -ne $Sender.Tag.BrandPicture.Image) { $Sender.Tag.BrandPicture.Image.Dispose(); $Sender.Tag.BrandPicture.Image = $null }
    })
    $exportButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $dialog = $null
        try { $dialog = New-EeaExportForm -Context $ownerForm.Tag.Context; [void](Show-EeaModal -Owner $ownerForm -Dialog $dialog) }
        catch { Show-EeaFormError $ownerForm $_ }
        finally { if ($null -ne $dialog) { $dialog.Dispose() } }
    })
    $importButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $dialog = $null
        $passwordDialog = $null
        try {
            $kitPath = Select-EeaKitPath -Form $ownerForm
            if (-not $kitPath) { return }
            $document = Read-EeaKitDocument $kitPath
            if ($document.Product -ceq 'EasyEdgeApps.EncryptedKit') {
                $passwordDialog = New-EeaPasswordForm -Envelope $document
                if ((Show-EeaModal -Owner $ownerForm -Dialog $passwordDialog) -ne [Windows.Forms.DialogResult]::OK) { return }
                $kit = $passwordDialog.Tag.Kit
            }
            else { $kit = $document }
            $dialog = New-EeaSelectionForm -Mode Import -Kit $kit -Context $ownerForm.Tag.Context
            [void](Show-EeaModal -Owner $ownerForm -Dialog $dialog)
            Update-EeaForm $ownerForm
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally { if ($null -ne $passwordDialog) { $passwordDialog.Dispose() }; if ($null -ne $dialog) { $dialog.Dispose() } }
    })
    foreach ($toolButton in @($favoritesButton, $checkButton)) {
        $toolButton.Tag = if ($toolButton -eq $favoritesButton) { 'Favorites' } else { 'Check' }
        $toolButton.Add_Click({
            param($Sender, $EventArgs)
            $ownerForm = $Sender.FindForm()
            $dialog = $null
            try {
                $dialog = New-EeaSelectionForm -Mode $Sender.Tag -Context $ownerForm.Tag.Context -EdgeUserDataPath $ownerForm.Tag.EdgeUserDataPath
                [void](Show-EeaModal -Owner $ownerForm -Dialog $dialog)
                Update-EeaForm $ownerForm
            }
            catch { Show-EeaFormError $ownerForm $_ }
            finally { if ($null -ne $dialog) { $dialog.Dispose() } }
        })
    }
    try { Update-EeaForm $form }
    catch { $statusLabel.Text = 'Saved settings need attention. Use Check Apps before making changes.' }
    return $form
}

function Show-EeaModal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Owner, [Parameter(Mandatory = $true)]$Dialog)

    return $Dialog.ShowDialog($Owner)
}

function Select-EeaKitPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [switch]$Save, [string]$FileName = 'My websites.eeakit.json')

    $dialog = if ($Save) { New-Object Windows.Forms.SaveFileDialog } else { New-Object Windows.Forms.OpenFileDialog }
    $dialog.Title = if ($Save) { 'Export App Kit' } else { 'Import App Kit' }
    $dialog.Filter = 'Easy Edge App Kits (*.eeakit.json)|*.eeakit.json|JSON files (*.json)|*.json'
    $dialog.DefaultExt = 'eeakit.json'
    $dialog.AddExtension = $true
    $dialog.CheckPathExists = $true
    $dialog.RestoreDirectory = $true
    if ($Save) { $dialog.FileName = $FileName; $dialog.OverwritePrompt = $true } else { $dialog.CheckFileExists = $true }
    try { if ($dialog.ShowDialog($Form) -eq [Windows.Forms.DialogResult]::OK) { return $dialog.FileName } }
    finally { $dialog.Dispose() }
}

function New-EeaScrollDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][string]$ActionText, [string]$ActionIcon = 'Export')

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(740, 640)
    $form.MinimumSize = New-Object Drawing.Size(600, 450)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $form.Padding = New-Object Windows.Forms.Padding(16)
    $form.BackColor = [Drawing.SystemColors]::Window
    $form.ForeColor = [Drawing.SystemColors]::WindowText
    Set-EeaFormIcon $form
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = [Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $form.Controls.Add($layout)
    $viewport = New-Object Windows.Forms.Panel
    $viewport.Dock = [Windows.Forms.DockStyle]::Fill
    $viewport.AutoScroll = $true
    $editor = New-Object Windows.Forms.TableLayoutPanel
    $editor.Dock = [Windows.Forms.DockStyle]::Top
    $editor.AutoSize = $true
    $editor.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $editor.ColumnCount = 1
    $editor.RowCount = 0
    [void]$editor.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $viewport.Controls.Add($editor)
    $layout.Controls.Add($viewport, 0, 0)
    $status = New-EeaLabel -Icon Info
    $status.AutoSize = $true
    $status.Dock = [Windows.Forms.DockStyle]::Fill
    $status.Text = 'Ready'
    $status.AccessibleName = 'Status'
    $status.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
    $layout.Controls.Add($status, 0, 1)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Fill
    $apply = New-EeaButton $ActionText -Icon $ActionIcon
    Set-EeaPrimaryButton $apply
    $cancel = New-EeaButton '&Cancel' -Icon Close
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($apply, $cancel))
    $layout.Controls.Add($actions, 0, 2)
    $form.AcceptButton = $apply
    $form.CancelButton = $cancel
    $form.Tag = [pscustomobject]@{ Editor = $editor; EditorViewport = $viewport; StatusLabel = $status; ApplyButton = $apply; CloseButton = $cancel }
    return $form
}

function Add-EeaDialogField {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)]$Control, [string]$Icon = 'Info')

    $editor = $Form.Tag.Editor
    $caption = New-EeaLabel -Icon $Icon
    $caption.Text = $Label
    $caption.AutoSize = $true
    $caption.Dock = [Windows.Forms.DockStyle]::Fill
    $caption.UseMnemonic = $true
    $caption.TabIndex = $editor.RowCount
    $Control.AccessibleName = $Label.Replace('&', '')
    $Control.Dock = [Windows.Forms.DockStyle]::Top
    $Control.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
    $Control.TabIndex = $editor.RowCount + 1
    [void]$editor.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$editor.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $editor.Controls.Add($caption, 0, $editor.RowCount)
    $editor.Controls.Add($Control, 0, $editor.RowCount + 1)
    $editor.RowCount += 2
}

function New-EeaPasswordForm {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Envelope)

    $null = Get-EeaEnvelopeData $Envelope
    $form = New-EeaScrollDialog -Title 'Unlock App Kit' -ActionText '&Unlock' -ActionIcon Unlock
    $passwordInput = New-EeaTextBox
    $passwordInput.UseSystemPasswordChar = $true
    $passwordInput.MaxLength = 1024
    Add-EeaDialogField $form '&Password' $passwordInput -Icon Lock
    $notice = New-EeaLabel -Icon Info
    $notice.AutoSize = $true
    $notice.Text = 'A forgotten password cannot be recovered. Unlocking does not install anything or verify the sender. Imported addresses remain visible in local settings and shortcuts.'
    Add-EeaDialogField $form 'Privacy' $notice -Icon Privacy
    $form.Tag | Add-Member -NotePropertyName Envelope -NotePropertyValue $Envelope
    $form.Tag | Add-Member -NotePropertyName Kit -NotePropertyValue $null
    $form.Tag | Add-Member -NotePropertyName PasswordInput -NotePropertyValue $passwordInput
    $form.Tag.ApplyButton.Enabled = $false
    $passwordInput.Add_TextChanged({ param($Sender, $EventArgs) $Sender.FindForm().Tag.ApplyButton.Enabled = $Sender.TextLength -gt 0 })
    $form.Tag.ApplyButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $secret = $null
        try {
            $ownerForm.UseWaitCursor = $true
            $Sender.Enabled = $false
            $ownerForm.Tag.StatusLabel.Text = 'Unlocking...'
            $ownerForm.Tag.StatusLabel.Refresh()
            $secret = ConvertTo-SecureString $ownerForm.Tag.PasswordInput.Text -AsPlainText -Force
            $ownerForm.Tag.Kit = Unprotect-EeaKit -Envelope $ownerForm.Tag.Envelope -Password $secret
            $ownerForm.DialogResult = [Windows.Forms.DialogResult]::OK
            $ownerForm.Close()
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally {
            if ($null -ne $secret) { $secret.Dispose() }
            $ownerForm.Tag.PasswordInput.Clear()
            $ownerForm.UseWaitCursor = $false
        }
    })
    $form.Add_FormClosed({ param($Sender, $EventArgs) $Sender.Tag.PasswordInput.Clear(); $Sender.Tag.Envelope = $null })
    return $form
}

function New-EeaExportForm {
    [CmdletBinding()]
    param($Context = (Get-EeaContext))

    $apps = @(Get-EeaApps -Context $Context | Sort-Object Name)
    $form = New-EeaScrollDialog -Title 'Export App Kit' -ActionText '&Export App Kit'
    $nameInput = New-EeaTextBox
    $nameInput.MaxLength = 60
    $nameInput.Text = 'My websites'
    Add-EeaDialogField $form 'App Kit &name' $nameInput -Icon Name
    $appList = New-Object Windows.Forms.CheckedListBox
    $appList.CheckOnClick = $true
    $appList.IntegralHeight = $false
    $appList.Height = 144
    $appList.DisplayMember = 'Name'
    $appList.HorizontalScrollbar = $true
    foreach ($app in $apps) { [void]$appList.Items.Add($app, $true) }
    Add-EeaDialogField $form '&Websites' $appList -Icon Apps
    $notesInput = New-EeaTextBox
    $notesInput.Multiline = $true
    $notesInput.AcceptsReturn = $true
    $notesInput.Height = 96
    $notesInput.MaxLength = 4000
    $notesInput.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    Add-EeaDialogField $form 'Kit helper n&otes (optional)' $notesInput -Icon Notes
    $formatInput = New-Object Windows.Forms.ComboBox
    $formatInput.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$formatInput.Items.Add('Standard JSON (readable)')
    [void]$formatInput.Items.Add('Password-protected')
    $formatInput.SelectedIndex = 1
    Add-EeaDialogField $form '&Protection' $formatInput -Icon Privacy
    $passwordInput = New-EeaTextBox
    $passwordInput.UseSystemPasswordChar = $true
    $passwordInput.MaxLength = 1024
    Add-EeaDialogField $form 'Export pass&word' $passwordInput -Icon Lock
    $confirmationInput = New-EeaTextBox
    $confirmationInput.UseSystemPasswordChar = $true
    $confirmationInput.MaxLength = 1024
    Add-EeaDialogField $form 'Con&firm password' $confirmationInput -Icon Lock
    $privacy = New-EeaLabel -Icon Info
    $privacy.AutoSize = $true
    $privacy.Text = 'Standard JSON exposes names, URLs, notes, and icons. Encryption protects only the exported file. Installed settings, shortcuts, and recovery files can reveal URLs. Browsing remains visible to Edge, websites, and network monitoring. Never use credentials, reset links, or session tokens in URLs.' + "`r`n`r`n" + 'Choose a strong, unique passphrase of at least 12 characters and share it separately. Weak passwords can be guessed offline. Forgotten passwords cannot be recovered. Independent security review is still needed before production use.'
    Add-EeaDialogField $form 'Privacy and password safety' $privacy -Icon Privacy
    foreach ($property in @{ Context = $Context; NameInput = $nameInput; AppList = $appList; NotesInput = $notesInput; FormatInput = $formatInput; PasswordInput = $passwordInput; ConfirmationInput = $confirmationInput }.GetEnumerator()) {
        $form.Tag | Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value
    }
    $form.Tag.ApplyButton.Enabled = $apps.Count -gt 0
    if ($apps.Count -eq 0) { $form.Tag.StatusLabel.Text = 'No saved websites to export.' }
    $formatInput.Add_SelectedIndexChanged({
        param($Sender, $EventArgs)
        $ui = $Sender.FindForm().Tag
        $ui.PasswordInput.Enabled = $Sender.SelectedIndex -eq 1
        $ui.ConfirmationInput.Enabled = $Sender.SelectedIndex -eq 1
        $ui.PasswordInput.Clear()
        $ui.ConfirmationInput.Clear()
    })
    $form.Tag.ApplyButton.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        $secret = $null
        $confirmation = $null
        try {
            $selected = @($ui.AppList.CheckedItems | ForEach-Object { $_.Name })
            if ($selected.Count -eq 0) { throw 'Choose at least one website to export.' }
            $kit = New-EeaKit -KitName $ui.NameInput.Text -Notes $ui.NotesInput.Text -AppNames $selected -Context $ui.Context
            $usePassword = $ui.FormatInput.SelectedIndex -eq 1
            if ($usePassword) {
                if (-not $ui.PasswordInput.TextLength -or -not $ui.ConfirmationInput.TextLength) { throw 'Enter and confirm a strong export passphrase.' }
                $secret = ConvertTo-SecureString $ui.PasswordInput.Text -AsPlainText -Force
                $confirmation = ConvertTo-SecureString $ui.ConfirmationInput.Text -AsPlainText -Force
                Assert-EeaExportPassword -Password $secret -Confirmation $confirmation
            }
            elseif (-not (Confirm-EeaChange $ownerForm 'This readable file will expose website addresses and helper notes to anyone who can read it. Export standard JSON?' 'Export a readable App Kit?')) { return }
            $kitPath = Select-EeaKitPath -Form $ownerForm -Save -FileName ($kit.Name + '.eeakit.json')
            if (-not $kitPath) { return }
            $ownerForm.UseWaitCursor = $true
            $Sender.Enabled = $false
            $ui.StatusLabel.Text = if ($usePassword) { 'Encrypting and saving...' } else { 'Saving...' }
            $ui.StatusLabel.Refresh()
            $null = Write-EeaKit -Kit $kit -Path $kitPath -Protected:$usePassword -Password $secret -PasswordConfirmation $confirmation -Replace:([IO.File]::Exists($kitPath)) -Confirm:$false
            $ui.StatusLabel.Text = 'Exported ' + $selected.Count + ' websites. Keep the App Kit private.'
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally {
            if ($null -ne $secret) { $secret.Dispose() }
            if ($null -ne $confirmation) { $confirmation.Dispose() }
            $ui.PasswordInput.Clear()
            $ui.ConfirmationInput.Clear()
            $ownerForm.UseWaitCursor = $false
            $Sender.Enabled = $true
        }
    })
    $form.Add_FormClosed({ param($Sender, $EventArgs) $Sender.Tag.PasswordInput.Clear(); $Sender.Tag.ConfirmationInput.Clear() })
    return $form
}

function Update-EeaSelectionButtons {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $ui = $Form.Tag
    if ($ui.Updating) { return }
    $selectedCount = @($ui.Grid.Rows | Where-Object { $_.Tag.CanSelect -and [bool]$_.Cells[0].Value }).Count
    $ui.ApplyButton.Enabled = $selectedCount -gt 0 -and $selectedCount -le 100
    $ui.StatusLabel.Text = $selectedCount.ToString() + ' selected. Up to 100 apps per operation.'
}

function Set-EeaSelectionRows {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form, [AllowEmptyCollection()][object[]]$Rows)

    $ui = $Form.Tag
    $ui.Updating = $true
    try {
        $ui.Grid.Rows.Clear()
        $ui.Details.Clear()
        $ui.AllCheck.Checked = $false
        foreach ($row in $Rows) {
            $index = $ui.Grid.Rows.Add([object[]]@($false, $row.Name, $row.Status, $row.Url, $row.Detail))
            $gridRow = $ui.Grid.Rows[$index]
            $gridRow.Tag = $row
            $gridRow.Cells[0].ReadOnly = -not $row.CanSelect
            if (-not $row.CanSelect) { $gridRow.DefaultCellStyle.ForeColor = [Drawing.SystemColors]::GrayText }
        }
    }
    finally { $ui.Updating = $false }
    Update-EeaSelectionButtons $Form
}

function Update-EeaSelectionForm {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Form)

    $ui = $Form.Tag
    $rows = @()
    if ($ui.Mode -eq 'Favorites') {
        if ($ui.ProfileInput.SelectedIndex -ge 0) {
            $rows = @(Get-EeaFavoriteChoices -ProfileDirectory $ui.ProfileInput.SelectedItem.DirectoryName -UserDataPath $ui.EdgeUserDataPath -Context $ui.Context | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Url = $_.Url; Detail = $_.Folder; CanSelect = $_.CanImport; Data = $_; Description = ('Favorite: ' + $_.Title + "`r`nFolder: " + $_.Folder + "`r`nAddress: " + $_.Url + "`r`n" + $_.Status) }
            })
        }
    }
    elseif ($ui.Mode -eq 'Import') {
        $rows = @(Get-EeaKitPreview -Kit $ui.Kit -Context $ui.Context | ForEach-Object {
            $status = if ($_.DomainChanged) { 'Update: DOMAIN CHANGE' } else { $_.Action }
            [pscustomobject]@{ Name = $_.Name; Status = $status; Url = $_.Url; Detail = $_.Detail; CanSelect = ($_.Action -in @('Add', 'Update')); Data = $_; Description = ('Current: ' + $_.CurrentUrl + "`r`nNew: " + $_.Url + "`r`n" + $_.Detail + "`r`nDesktop: " + $_.App.Desktop + '   Start menu: ' + $_.App.StartMenu + "`r`nApp notes: " + $_.App.Notes + "`r`nKit notes: " + $ui.Kit.Notes) }
        })
    }
    else {
        $rows = @(Get-EeaChecks -Context $ui.Context | ForEach-Object {
            $website = if ($null -ne $_.State) { $_.State.Url } else { '' }
            $detail = if ($_.Issues.Count -gt 0) { $_.Issues -join ' ' } else { 'Owned shortcuts are present. Website access was not tested.' }
            [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Url = $website; Detail = $detail; CanSelect = $_.CanRepair; Data = $_; Description = $detail }
        })
    }
    Set-EeaSelectionRows -Form $Form -Rows $rows
    if ($rows.Count -eq 0) { $ui.StatusLabel.Text = if ($ui.Mode -eq 'Favorites') { 'No locally saved Favorites bar items were found in this profile.' } else { 'No saved apps to show.' } }
}

function New-EeaSelectionForm {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Favorites', 'Import', 'Check')][string]$Mode, $Kit, $Context = (Get-EeaContext), [string]$EdgeUserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'))

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [Windows.Forms.Application]::EnableVisualStyles()
    if ($Mode -eq 'Import') { $Kit = ConvertTo-EeaKit $Kit }
    $form = New-Object Windows.Forms.Form
    $form.Text = switch ($Mode) { Favorites { 'Edge Favorites Bar' } Import { 'Import App Kit: ' + $Kit.Name } Check { 'Check and Repair Apps' } }
    $form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(960, 640)
    $form.MinimumSize = New-Object Drawing.Size(640, 500)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $form.Padding = New-Object Windows.Forms.Padding(16)
    $form.BackColor = [Drawing.SystemColors]::Window
    $form.ForeColor = [Drawing.SystemColors]::WindowText
    Set-EeaFormIcon $form
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = [Windows.Forms.DockStyle]::Fill
    $layout.ColumnCount = 1
    $layout.RowCount = 5
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 68)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 32)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $form.Controls.Add($layout)
    $toolbar = New-Object Windows.Forms.FlowLayoutPanel
    $toolbar.AutoSize = $true
    $toolbar.Dock = [Windows.Forms.DockStyle]::Fill
    $profileInput = New-Object Windows.Forms.ComboBox
    $profileInput.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $profileInput.DisplayMember = 'DisplayName'
    $profileInput.Width = 300
    $profileInput.AccessibleName = 'Edge profile to read Favorites bar from'
    $profileInput.Visible = $Mode -eq 'Favorites'
    $toolbar.Controls.Add($profileInput)
    $refresh = New-EeaButton '&Refresh' -Icon Refresh
    $all = New-EeaCheckBox 'All &available' -Icon SelectAll
    $all.AutoSize = $true
    $all.Text = 'All &available'
    $all.AccessibleName = 'Select all available rows'
    $desktop = New-EeaCheckBox '&Desktop' -Icon Desktop
    $desktop.AutoSize = $true
    $desktop.Text = '&Desktop'
    $desktop.Checked = $true
    $desktop.Visible = $Mode -eq 'Favorites'
    $startMenu = New-EeaCheckBox 'Start &menu' -Icon Start
    $startMenu.AutoSize = $true
    $startMenu.Text = 'Start &menu'
    $startMenu.Checked = $true
    $startMenu.Visible = $Mode -eq 'Favorites'
    $toolbar.Controls.AddRange([Windows.Forms.Control[]]@($refresh, $all, $desktop, $startMenu))
    $layout.Controls.Add($toolbar, 0, 0)
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = [Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoSizeRowsMode = [Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCellsExceptHeaders
    $grid.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
    $grid.BackgroundColor = [Drawing.SystemColors]::Window
    $grid.AccessibleName = 'Website preview and selection'
    $chooseColumn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $chooseColumn.Name = 'Selected'
    $chooseColumn.HeaderText = 'Select'
    $chooseColumn.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::ColumnHeader
    $chooseColumn.MinimumWidth = 52
    [void]$grid.Columns.Add($chooseColumn)
    foreach ($columnInfo in @(@('Name', 'Shortcut name', 180), @('Status', 'Status', 190), @('Url', 'Website address', 320), @('Detail', 'Folder or change', 320))) {
        $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $columnInfo[0]
        $column.HeaderText = $columnInfo[1]
        $column.Width = $columnInfo[2]
        $column.ReadOnly = $true
        $column.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$grid.Columns.Add($column)
    }
    $layout.Controls.Add($grid, 0, 1)
    $details = New-EeaTextBox
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = [Windows.Forms.ScrollBars]::Both
    $details.Dock = [Windows.Forms.DockStyle]::Fill
    $details.AccessibleName = 'Selected website details and plain-text helper notes'
    $layout.Controls.Add($details, 0, 2)
    $status = New-EeaLabel -Icon Info
    $status.AutoSize = $true
    $status.Dock = [Windows.Forms.DockStyle]::Fill
    $status.AccessibleName = 'Status'
    $status.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
    $layout.Controls.Add($status, 0, 3)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Fill
    $applyText = switch ($Mode) { Favorites { '&Add Selected' } Import { '&Import Selected' } Check { '&Repair Selected' } }
    $applyIcon = switch ($Mode) { Favorites { 'Add' } Import { 'Import' } Check { 'Repair' } }
    $apply = New-EeaButton $applyText -Icon $applyIcon
    Set-EeaPrimaryButton $apply
    $apply.Enabled = $false
    $close = New-EeaButton '&Close' -Icon Close
    $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($apply, $close))
    $layout.Controls.Add($actions, 0, 4)
    $form.AcceptButton = $close
    $form.CancelButton = $close
    $form.Tag = [pscustomobject]@{
        Mode = $Mode; Kit = $Kit; Context = $Context; EdgeUserDataPath = $EdgeUserDataPath; Updating = $false
        ProfileInput = $profileInput; RefreshButton = $refresh; AllCheck = $all; DesktopCheck = $desktop; StartMenuCheck = $startMenu
        Grid = $grid; Details = $details; StatusLabel = $status; ApplyButton = $apply; CloseButton = $close; Result = $null
    }
    $grid.Add_CurrentCellDirtyStateChanged({ param($Sender, $EventArgs) if ($Sender.IsCurrentCellDirty) { [void]$Sender.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })
    $grid.Add_CellValueChanged({ param($Sender, $EventArgs) Update-EeaSelectionButtons $Sender.FindForm() })
    $grid.Add_SelectionChanged({
        param($Sender, $EventArgs)
        if ($Sender.SelectedRows.Count -gt 0 -and $null -ne $Sender.SelectedRows[0].Tag) { $Sender.FindForm().Tag.Details.Text = $Sender.SelectedRows[0].Tag.Description }
    })
    $all.Add_CheckedChanged({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        if ($ui.Updating) { return }
        $ui.Updating = $true
        try { foreach ($row in $ui.Grid.Rows) { $row.Cells[0].Value = $Sender.Checked -and $row.Tag.CanSelect } }
        finally { $ui.Updating = $false }
        Update-EeaSelectionButtons $ownerForm
    })
    $refresh.Add_Click({ param($Sender, $EventArgs) try { Update-EeaSelectionForm $Sender.FindForm() } catch { Show-EeaFormError $Sender.FindForm() $_ } })
    $profileInput.Add_SelectedIndexChanged({ param($Sender, $EventArgs) try { Update-EeaSelectionForm $Sender.FindForm() } catch { Set-EeaSelectionRows -Form $Sender.FindForm() -Rows @(); Show-EeaFormError $Sender.FindForm() $_ } })
    $apply.Add_Click({
        param($Sender, $EventArgs)
        $ownerForm = $Sender.FindForm()
        $ui = $ownerForm.Tag
        try {
            [void]$ui.Grid.EndEdit()
            $selected = @($ui.Grid.Rows | Where-Object { $_.Tag.CanSelect -and [bool]$_.Cells[0].Value } | ForEach-Object { $_.Tag.Data })
            if ($selected.Count -lt 1 -or $selected.Count -gt 100) { throw 'Choose between 1 and 100 available websites.' }
            $message = switch ($ui.Mode) {
                Favorites { 'Add the selected Favorites bar websites? Edge favorites stay unchanged. Shortcuts use Edge''s normal profile. Completed apps remain if a later app fails.' }
                Import { 'Apply the selected App Kit changes? Review the old and new addresses, especially domain changes. Apps outside this selection stay unchanged. Completed apps remain if a later app fails.' }
                Check { 'Repair the selected owned files? Missing custom icons become automatic letter icons. Website access, accounts, and sign-in will not be tested or repaired.' }
            }
            if (-not (Confirm-EeaChange $ownerForm $message 'Apply selected changes?')) { return }
            $ownerForm.UseWaitCursor = $true
            $Sender.Enabled = $false
            $ui.StatusLabel.Text = 'Applying selected changes...'
            $ui.StatusLabel.Refresh()
            if ($ui.Mode -eq 'Favorites') {
                $kit = New-EeaFavoritesKit -Favorites $selected -Desktop $ui.DesktopCheck.Checked -StartMenu $ui.StartMenuCheck.Checked
                $ui.Result = Import-EeaKit -Kit $kit -NewOnly -Context $ui.Context -Confirm:$false
            }
            elseif ($ui.Mode -eq 'Import') {
                $kit = ConvertTo-EeaKit ([pscustomobject]@{ Product = 'EasyEdgeApps.AppKit'; SchemaVersion = 1; Name = $ui.Kit.Name; Notes = $ui.Kit.Notes; Apps = @($selected | ForEach-Object { $_.App }) })
                $ui.Result = Import-EeaKit -Kit $kit -ExpectedPreview $selected -Context $ui.Context -Confirm:$false
            }
            else { $ui.Result = Repair-EeaApps -AppNames @($selected | ForEach-Object { $_.Name }) -ExpectedChecks $selected -Context $ui.Context -Confirm:$false }
            $resultRows = @($ui.Result.Results | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Url = ''; Detail = $_.Detail; CanSelect = $false; Data = $_; Description = $_.Detail } })
            Set-EeaSelectionRows -Form $ownerForm -Rows $resultRows
            $ui.StatusLabel.Text = if ($ui.Result.Completed) { 'Shortcut changes completed. Website access was not tested.' } else { 'Some changes were not completed. Review each result; earlier completed apps remain.' }
        }
        catch { Show-EeaFormError $ownerForm $_ }
        finally { $ownerForm.UseWaitCursor = $false }
    })
    try {
        if ($Mode -eq 'Favorites') {
            foreach ($profile in @(Get-EeaEdgeProfiles -UserDataPath $EdgeUserDataPath)) { [void]$profileInput.Items.Add($profile) }
            if ($profileInput.Items.Count -gt 0) {
                $selectedIndex = 0
                for ($profileIndex = 0; $profileIndex -lt $profileInput.Items.Count; $profileIndex++) { if ($profileInput.Items[$profileIndex].IsLastUsed) { $selectedIndex = $profileIndex; break } }
                $profileInput.SelectedIndex = $selectedIndex
            }
        }
        Update-EeaSelectionForm $form
    }
    catch { $form.Dispose(); throw }
    return $form
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        if ($Help -or $Action -eq '--help') {
            Get-Help -Name $PSCommandPath -Full
            exit 0
        }
        if ($env:OS -ne 'Windows_NT') { throw 'Easy Edge Apps needs Windows and Microsoft Edge.' }
        if (-not $PSBoundParameters.ContainsKey('Action') -and $Name -and $Url) { $Action = 'Install' }
        $actionOptions = @{
            Setup = @('EdgeUserDataPath'); Install = @('Name', 'Url', 'IconPath', 'Notes', 'NoDesktop', 'NoStartMenu', 'Launch')
            List = @(); Remove = @('Name'); Open = @('Name')
            ExportKit = @('Path', 'KitName', 'Notes', 'AppNames', 'Protected', 'Password', 'PasswordConfirmation', 'Replace')
            ImportKit = @('Path', 'AppNames', 'Password', 'Preview'); Check = @('Name', 'AppNames'); Repair = @('Name', 'AppNames', 'Preview')
            ListFavorites = @('EdgeProfile', 'EdgeUserDataPath'); ImportFavorites = @('EdgeProfile', 'EdgeUserDataPath', 'AppNames', 'NoDesktop', 'NoStartMenu', 'Preview')
        }
        $commonOptions = @('Action', 'Unattended', 'Quiet', 'Help', 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
        foreach ($option in $PSBoundParameters.Keys) {
            if ($option -notin $commonOptions -and $option -notin $actionOptions[$Action]) { throw "-$option is not supported with -Action $Action." }
        }
        if ($Name -and $AppNames) { throw 'Choose either -Name or -AppNames, not both.' }
        if ($Unattended) {
            if ($Action -eq 'Setup') { throw 'Choose a command-line -Action when using -Unattended.' }
            if ($PSBoundParameters.ContainsKey('Confirm') -and $PSBoundParameters['Confirm']) { throw 'Do not combine -Unattended with -Confirm. Use -WhatIf to preview changes.' }
            $ConfirmPreference = 'None'
            $Quiet = $true
            if ($WarningPreference -eq 'Inquire') { $WarningPreference = 'Continue' }
            if ($DebugPreference -eq 'Inquire') { $DebugPreference = 'Continue' }
            if ($InformationPreference -eq 'Inquire') { $InformationPreference = 'Continue' }
        }
        switch ($Action) {
            'Setup' {
                if ($Quiet -or $Name -or $Url -or $IconPath -or $NoDesktop -or $NoStartMenu -or $Launch) {
                    throw 'Run without parameters for the setup window, or use -Action Install with -Name and -Url.'
                }
                if ($PSCmdlet.ShouldProcess('Easy Edge Apps', 'Open the setup window')) {
                    $setupForm = New-EeaSetupForm -EdgeUserDataPath $EdgeUserDataPath
                    try { [void]$setupForm.ShowDialog() }
                    finally { $setupForm.Dispose() }
                }
            }
            'Install' {
                if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Url)) {
                    throw 'Provide both -Name and -Url when using -Action Install.'
                }
                $installOptions = @{ AppName = $Name; Website = $Url; CustomIcon = $IconPath; Desktop = (-not $NoDesktop); StartMenu = (-not $NoStartMenu) }
                if ($PSBoundParameters.ContainsKey('Notes')) { $installOptions.Notes = $Notes }
                $installedApp = Install-EeaApp @installOptions
                if ($null -ne $installedApp) {
                    if (-not $Quiet) { Write-Host ('Saved website shortcuts: ' + $installedApp.Name) }
                    if ($Unattended) { $installedApp | Select-Object Name, Url, Desktop, StartMenu }
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
            'ExportKit' {
                if (-not $Path) { throw 'Provide -Path with a filename ending in .eeakit.json.' }
                $kit = New-EeaKit -KitName $KitName -Notes $Notes -AppNames $AppNames
                Write-EeaKit -Kit $kit -Path $Path -Protected:$Protected -Password $Password -PasswordConfirmation $PasswordConfirmation -Replace:$Replace
            }
            'ImportKit' {
                if (-not $Path) { throw 'Provide -Path to an App Kit.' }
                $kit = Read-EeaKit -Path $Path -Password $Password
                if ($AppNames) {
                    $selectedIds = @($AppNames | ForEach-Object { Get-EeaId $_ })
                    foreach ($selectedId in $selectedIds) {
                        if (@($kit.Apps | Where-Object { (Get-EeaId $_.Name) -ceq $selectedId }).Count -ne 1) { throw 'A selected website is not in the App Kit. Review -Action ImportKit -Preview.' }
                    }
                    $kit.Apps = @($kit.Apps | Where-Object { $selectedIds -ccontains (Get-EeaId $_.Name) })
                }
                $kitPreview = @(Get-EeaKitPreview -Kit $kit)
                if ($Preview) { $kitPreview | Select-Object Name, Action, CurrentUrl, Url, DomainChanged, Detail }
                else {
                    if (-not $Quiet) { $kitPreview | Format-Table Name, Action, CurrentUrl, Url, DomainChanged, Detail -Wrap | Out-Host }
                    $result = Import-EeaKit -Kit $kit -ExpectedPreview $kitPreview
                    $result.Results
                    if (@($result.Results | Where-Object { $_.Status -in @('Failed', 'Conflict', 'Not attempted') }).Count -gt 0) { exit 1 }
                }
            }
            'Check' {
                $selectedNames = if ($Name) { @($Name) } else { $AppNames }
                Get-EeaChecks -AppNames $selectedNames | Select-Object Name, Status, CanRepair, Issues
            }
            'Repair' {
                $selectedNames = if ($Name) { @($Name) } else { $AppNames }
                if (-not $selectedNames) { throw 'Choose saved apps with -Name or -AppNames for repair.' }
                $checks = @(Get-EeaChecks -AppNames $selectedNames)
                if ($Preview) { $checks | Select-Object Name, Status, CanRepair, Issues }
                else {
                    if (-not $Quiet) { $checks | Format-Table Name, Status, Issues -Wrap | Out-Host }
                    $result = Repair-EeaApps -AppNames $selectedNames -ExpectedChecks $checks
                    $result.Results
                    if (@($result.Results | Where-Object { $_.Status -in @('Failed', 'Conflict', 'Not attempted', 'Not repaired') }).Count -gt 0) { exit 1 }
                }
            }
            { $_ -in @('ListFavorites', 'ImportFavorites') } {
                $profiles = @(Get-EeaEdgeProfiles -UserDataPath $EdgeUserDataPath)
                if ($EdgeProfile) { $profiles = @($profiles | Where-Object { $_.DirectoryName -ceq $EdgeProfile }) }
                if ($profiles.Count -eq 0) { throw 'No local Edge Favorites bar was found for that profile. Open Edge in this Windows account and let favorites sync first.' }
                if ($Action -eq 'ListFavorites') {
                    foreach ($profile in $profiles) {
                        Get-EeaFavoriteChoices -ProfileDirectory $profile.DirectoryName -UserDataPath $EdgeUserDataPath | Select-Object ProfileDirectory, Folder, Title, Name, Url, CanImport, Status
                    }
                }
                else {
                    $profile = @($profiles | Where-Object IsLastUsed | Select-Object -First 1)
                    if ($profile.Count -eq 0) { $profile = @($profiles[0]) }
                    $favorites = @(Get-EeaFavoriteChoices -ProfileDirectory $profile[0].DirectoryName -UserDataPath $EdgeUserDataPath | Where-Object CanImport)
                    if ($AppNames) {
                        $selectedIds = @($AppNames | ForEach-Object { Get-EeaId $_ })
                        foreach ($selectedId in $selectedIds) {
                            if (@($favorites | Where-Object { (Get-EeaId $_.Name) -ceq $selectedId }).Count -ne 1) { throw 'A selected favorite is unavailable. Refresh -Action ListFavorites.' }
                        }
                        $favorites = @($favorites | Where-Object { $selectedIds -ccontains (Get-EeaId $_.Name) })
                    }
                    if ($favorites.Count -eq 0) { if (-not $Quiet) { Write-Host 'No new HTTPS favorites are available.' }; break }
                    $kit = New-EeaFavoritesKit -Favorites $favorites -Desktop (-not $NoDesktop) -StartMenu (-not $NoStartMenu)
                    $kitPreview = @(Get-EeaKitPreview -Kit $kit -NewOnly)
                    if ($Preview) { $kitPreview | Select-Object Name, Action, Url, Detail }
                    else {
                        if (-not $Quiet) { $kitPreview | Format-Table Name, Action, Url, Detail -Wrap | Out-Host }
                        $result = Import-EeaKit -Kit $kit -ExpectedPreview $kitPreview -NewOnly
                        $result.Results
                        if (@($result.Results | Where-Object { $_.Status -in @('Failed', 'Conflict', 'Not attempted') }).Count -gt 0) { exit 1 }
                    }
                }
            }
        }
        if ($Unattended) { exit 0 }
    }
    catch {
        if ($Action -eq 'Setup' -and -not $Unattended -and -not $Quiet -and -not $WhatIfPreference) {
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