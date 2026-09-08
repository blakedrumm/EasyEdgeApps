#requires -Version 5.1

<#
.SYNOPSIS
Creates easy-to-find, per-user Microsoft Edge website shortcuts on Windows 11.
.DESCRIPTION
Run without parameters for the setup window. Command-line actions also support
App Kits, Check, Repair, ListFavorites, and ImportFavorites.
No administrator rights, external modules, downloads,
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
    [ValidateSet('Setup', 'Install', 'List', 'Remove', 'Open', 'ExportKit', 'ImportKit', 'Check', 'Repair', 'ListFavorites', 'ImportFavorites')]
    [string]$Action = 'Setup',
    [string]$Name,
    [string]$Url,
    [string]$IconPath,
    [string]$Notes,
    [string]$Path,
    [string]$KitName = 'My websites',
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
    [switch]$Quiet
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
            if (-not $canImport) { $appName = $title; if ($website.Length -gt 2048) { $website = $website.Substring(0, 2048) } }
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
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

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
    $ui.NotesInput.Clear()
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
    param($Context = (Get-EeaContext), [string]$EdgeUserDataPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'))

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
    $editor.RowCount = 10
    [void]$editor.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    for ($rowIndex = 0; $rowIndex -lt 10; $rowIndex++) {
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

    $notesLabel = New-Object Windows.Forms.Label
    $notesLabel.Text = 'Helper &notes (optional)'
    $notesLabel.AutoSize = $true
    $notesLabel.TabIndex = 4
    $editor.Controls.Add($notesLabel, 0, 4)
    $notesInput = New-Object Windows.Forms.TextBox
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

    $placement = New-Object Windows.Forms.FlowLayoutPanel
    $placement.AutoSize = $true
    $placement.Dock = [Windows.Forms.DockStyle]::Fill
    $placement.TabIndex = 6
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
    $editor.Controls.Add($placement, 0, 6)

    $iconPanel = New-Object Windows.Forms.FlowLayoutPanel
    $iconPanel.AutoSize = $true
    $iconPanel.Dock = [Windows.Forms.DockStyle]::Fill
    $iconPanel.TabIndex = 7
    $iconPreview = New-Object Windows.Forms.PictureBox
    $iconPreview.Size = New-Object Drawing.Size(48, 48)
    $iconPreview.SizeMode = [Windows.Forms.PictureBoxSizeMode]::Zoom
    $iconPreview.AccessibleName = 'Website icon'
    $iconPreview.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 8)
    $iconButton = New-EeaButton 'Choose &icon...'
    $clearIconButton = New-EeaButton 'Use &saved icon'
    $iconPanel.Controls.AddRange([Windows.Forms.Control[]]@($iconPreview, $iconButton, $clearIconButton))
    $editor.Controls.Add($iconPanel, 0, 7)
    $iconLabel = New-Object Windows.Forms.Label
    $iconLabel.AutoSize = $true
    $iconLabel.Text = 'Automatic'
    $iconLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 16)
    $editor.Controls.Add($iconLabel, 0, 8)

    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Top
    $actions.TabIndex = 8
    $saveButton = New-EeaButton '&Add website'
    $openButton = New-EeaButton '&Open'
    $removeButton = New-EeaButton '&Remove...'
    $openButton.Enabled = $false
    $removeButton.Enabled = $false
    $actions.Controls.AddRange([Windows.Forms.Control[]]@($saveButton, $openButton, $removeButton))
    $editor.Controls.Add($actions, 0, 9)

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
    $footer = New-Object Windows.Forms.FlowLayoutPanel
    $footer.Dock = [Windows.Forms.DockStyle]::Fill
    $footer.AutoSize = $true
    $exportButton = New-EeaButton '&Export App Kit...'
    $importButton = New-EeaButton '&Import App Kit...'
    $favoritesButton = New-EeaButton 'Edge &Favorites bar...'
    $checkButton = New-EeaButton 'C&heck Apps...'
    $footer.Controls.AddRange([Windows.Forms.Control[]]@($exportButton, $importButton, $favoritesButton, $checkButton, $closeButton))
    $layout.Controls.Add($footer, 0, 3)
    $form.AcceptButton = $saveButton
    $form.CancelButton = $closeButton
    $form.Tag = [pscustomobject]@{
        Context = $Context; AppList = $appList; NameInput = $nameInput; UrlInput = $urlInput; NotesInput = $notesInput
        DesktopCheck = $desktopCheck; StartMenuCheck = $startMenuCheck; CustomIcon = $null
        IconPreview = $iconPreview; IconLabel = $iconLabel; StatusLabel = $statusLabel
        SaveButton = $saveButton; OpenButton = $openButton; RemoveButton = $removeButton
        NewButton = $newButton; CloseButton = $closeButton
        EditorViewport = $editorViewport
        ExportButton = $exportButton; ImportButton = $importButton; FavoritesButton = $favoritesButton; CheckButton = $checkButton
        EdgeUserDataPath = $EdgeUserDataPath
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
        $ui.NotesInput.Text = if ($null -ne $selected.PSObject.Properties['Notes']) { $selected.Notes } else { '' }
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
            $installed = Install-EeaApp -AppName $cleanName -Website $ui.UrlInput.Text -Notes $ui.NotesInput.Text -CustomIcon $ui.CustomIcon -Desktop $ui.DesktopCheck.Checked -StartMenu $ui.StartMenuCheck.Checked -Context $ui.Context -Confirm:$false
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
    param([Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][string]$ActionText)

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(740, 640)
    $form.MinimumSize = New-Object Drawing.Size(600, 450)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $form.Padding = New-Object Windows.Forms.Padding(16)
    $form.BackColor = [Drawing.SystemColors]::Control
    $form.ForeColor = [Drawing.SystemColors]::ControlText
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
    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $true
    $status.Dock = [Windows.Forms.DockStyle]::Fill
    $status.Text = 'Ready'
    $status.AccessibleName = 'Status'
    $status.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
    $layout.Controls.Add($status, 0, 1)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Fill
    $apply = New-EeaButton $ActionText
    $cancel = New-EeaButton '&Cancel'
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
    param([Parameter(Mandatory = $true)]$Form, [Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)]$Control)

    $editor = $Form.Tag.Editor
    $caption = New-Object Windows.Forms.Label
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
    $form = New-EeaScrollDialog -Title 'Unlock App Kit' -ActionText '&Unlock'
    $passwordInput = New-Object Windows.Forms.TextBox
    $passwordInput.UseSystemPasswordChar = $true
    $passwordInput.MaxLength = 1024
    Add-EeaDialogField $form '&Password' $passwordInput
    $notice = New-Object Windows.Forms.Label
    $notice.AutoSize = $true
    $notice.Text = 'A forgotten password cannot be recovered. Unlocking does not install anything or verify the sender. Imported addresses remain visible in local settings and shortcuts.'
    Add-EeaDialogField $form 'Privacy' $notice
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
    $nameInput = New-Object Windows.Forms.TextBox
    $nameInput.MaxLength = 60
    $nameInput.Text = 'My websites'
    Add-EeaDialogField $form 'App Kit &name' $nameInput
    $appList = New-Object Windows.Forms.CheckedListBox
    $appList.CheckOnClick = $true
    $appList.IntegralHeight = $false
    $appList.Height = 144
    $appList.DisplayMember = 'Name'
    $appList.HorizontalScrollbar = $true
    foreach ($app in $apps) { [void]$appList.Items.Add($app, $true) }
    Add-EeaDialogField $form '&Websites' $appList
    $notesInput = New-Object Windows.Forms.TextBox
    $notesInput.Multiline = $true
    $notesInput.AcceptsReturn = $true
    $notesInput.Height = 96
    $notesInput.MaxLength = 4000
    $notesInput.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    Add-EeaDialogField $form 'Kit helper n&otes (optional)' $notesInput
    $formatInput = New-Object Windows.Forms.ComboBox
    $formatInput.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$formatInput.Items.Add('Standard JSON (readable)')
    [void]$formatInput.Items.Add('Password-protected')
    $formatInput.SelectedIndex = 1
    Add-EeaDialogField $form '&Protection' $formatInput
    $passwordInput = New-Object Windows.Forms.TextBox
    $passwordInput.UseSystemPasswordChar = $true
    $passwordInput.MaxLength = 1024
    Add-EeaDialogField $form 'Export pass&word' $passwordInput
    $confirmationInput = New-Object Windows.Forms.TextBox
    $confirmationInput.UseSystemPasswordChar = $true
    $confirmationInput.MaxLength = 1024
    Add-EeaDialogField $form 'Con&firm password' $confirmationInput
    $privacy = New-Object Windows.Forms.Label
    $privacy.AutoSize = $true
    $privacy.Text = 'Standard JSON exposes names, URLs, notes, and icons. Encryption protects only the exported file. Installed settings, shortcuts, and recovery files can reveal URLs. Browsing remains visible to Edge, websites, and network monitoring. Never use credentials, reset links, or session tokens in URLs.' + "`r`n`r`n" + 'Choose a strong, unique passphrase of at least 12 characters and share it separately. Weak passwords can be guessed offline. Forgotten passwords cannot be recovered. Independent security review is still needed before production use.'
    Add-EeaDialogField $form 'Privacy and password safety' $privacy
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
    if ($Mode -eq 'Import') { $Kit = ConvertTo-EeaKit $Kit }
    $form = New-Object Windows.Forms.Form
    $form.Text = switch ($Mode) { Favorites { 'Edge Favorites Bar' } Import { 'Import App Kit: ' + $Kit.Name } Check { 'Check and Repair Apps' } }
    $form.Font = New-Object Drawing.Font('Segoe UI', 12)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = New-Object Drawing.Size(960, 640)
    $form.MinimumSize = New-Object Drawing.Size(640, 500)
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $form.Padding = New-Object Windows.Forms.Padding(16)
    $form.BackColor = [Drawing.SystemColors]::Control
    $form.ForeColor = [Drawing.SystemColors]::ControlText
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
    $refresh = New-EeaButton '&Refresh'
    $all = New-Object Windows.Forms.CheckBox
    $all.AutoSize = $true
    $all.Text = 'All &available'
    $all.AccessibleName = 'Select all available rows'
    $desktop = New-Object Windows.Forms.CheckBox
    $desktop.AutoSize = $true
    $desktop.Text = '&Desktop'
    $desktop.Checked = $true
    $desktop.Visible = $Mode -eq 'Favorites'
    $startMenu = New-Object Windows.Forms.CheckBox
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
    $details = New-Object Windows.Forms.TextBox
    $details.Multiline = $true
    $details.ReadOnly = $true
    $details.ScrollBars = [Windows.Forms.ScrollBars]::Both
    $details.Dock = [Windows.Forms.DockStyle]::Fill
    $details.AccessibleName = 'Selected website details and plain-text helper notes'
    $layout.Controls.Add($details, 0, 2)
    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $true
    $status.Dock = [Windows.Forms.DockStyle]::Fill
    $status.AccessibleName = 'Status'
    $status.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 8)
    $layout.Controls.Add($status, 0, 3)
    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.AutoSize = $true
    $actions.Dock = [Windows.Forms.DockStyle]::Fill
    $applyText = switch ($Mode) { Favorites { '&Add Selected' } Import { '&Import Selected' } Check { '&Repair Selected' } }
    $apply = New-EeaButton $applyText
    $apply.Enabled = $false
    $close = New-EeaButton '&Close'
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
        if ($env:OS -ne 'Windows_NT') { throw 'Easy Edge Apps needs Windows and Microsoft Edge.' }
        if (-not $PSBoundParameters.ContainsKey('Action') -and $Name -and $Url) { $Action = 'Install' }
        $actionOptions = @{
            Setup = @('EdgeUserDataPath'); Install = @('Name', 'Url', 'IconPath', 'Notes', 'NoDesktop', 'NoStartMenu', 'Launch')
            List = @(); Remove = @('Name'); Open = @('Name')
            ExportKit = @('Path', 'KitName', 'Notes', 'AppNames', 'Protected', 'Password', 'PasswordConfirmation', 'Replace')
            ImportKit = @('Path', 'Password', 'Preview'); Check = @('Name', 'AppNames'); Repair = @('Name', 'AppNames', 'Preview')
            ListFavorites = @('EdgeProfile', 'EdgeUserDataPath'); ImportFavorites = @('EdgeProfile', 'EdgeUserDataPath', 'AppNames', 'NoDesktop', 'NoStartMenu', 'Preview')
        }
        $commonOptions = @('Action', 'Quiet', 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')
        foreach ($option in $PSBoundParameters.Keys) {
            if ($option -notin $commonOptions -and $option -notin $actionOptions[$Action]) { throw "-$option is not supported with -Action $Action." }
        }
        if ($Name -and $AppNames) { throw 'Choose either -Name or -AppNames, not both.' }
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
                $kitPreview = @(Get-EeaKitPreview -Kit $kit)
                if ($Preview) { $kitPreview | Select-Object Name, Action, CurrentUrl, Url, DomainChanged, Detail }
                else {
                    $kitPreview | Format-Table Name, Action, CurrentUrl, Url, DomainChanged, Detail -Wrap | Out-Host
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
                    $checks | Format-Table Name, Status, Issues -Wrap | Out-Host
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
                        $kitPreview | Format-Table Name, Action, Url, Detail -Wrap | Out-Host
                        $result = Import-EeaKit -Kit $kit -ExpectedPreview $kitPreview -NewOnly
                        $result.Results
                        if (@($result.Results | Where-Object { $_.Status -in @('Failed', 'Conflict', 'Not attempted') }).Count -gt 0) { exit 1 }
                    }
                }
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