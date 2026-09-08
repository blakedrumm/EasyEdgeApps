#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot '..\EasyEdgeApps.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('EasyEdgeApps.FavoritesTests.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

function Assert-Favorite {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-FavoriteRejected {
    param([scriptblock]$Operation)
    $rejected = $false
    try { & $Operation | Out-Null } catch { $rejected = $true }
    Assert-Favorite $rejected 'Unsafe or damaged favorites must be rejected.'
}

try {
    $edgeRoot = Join-Path $testRoot 'Edge User Data'
    $profileRoot = Join-Path $edgeRoot 'Default'
    [void][IO.Directory]::CreateDirectory($profileRoot)
    [void][IO.Directory]::CreateDirectory((Join-Path $edgeRoot 'Profile 1'))
    [void][IO.Directory]::CreateDirectory((Join-Path $edgeRoot 'Guest Profile'))
    $bookmarkPath = Join-Path $profileRoot 'Bookmarks'
    $fixture = [ordered]@{
        roots = @{
            bookmark_bar = @{
                type = 'folder'; name = 'Favorites bar'; children = @(
                    @{ type = 'url'; name = 'News: Today'; url = 'https://example.com/?first=1&second=2#/home' },
                    @{ type = 'folder'; name = 'Daily'; children = @(
                        @{ type = 'folder'; name = 'Reading'; children = @(
                            @{ type = 'url'; name = ''; url = 'HTTPS://EXAMPLE.ORG/' },
                            @{ type = 'url'; name = 'NUL'; url = 'https://example.net/' }
                        ) }
                    ) },
                    @{ type = 'url'; name = 'Legacy'; url = 'http://example.com/' },
                    @{ type = 'url'; name = 'Local'; url = 'edge://favorites/' },
                    @{ type = 'url'; name = 'Bookmarklet'; url = 'javascript:alert(1)' },
                    @{ type = 'url'; name = 'Credentials'; url = 'https://user:password@example.com/' }
                )
            }
            other = @{ type = 'folder'; children = @(@{ type = 'url'; name = 'Not on bar'; url = 'https://other.example.com/' }) }
        }
    }
    $json = $fixture | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($bookmarkPath, $json, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $edgeRoot 'Profile 1\Bookmarks'), $json)
    [IO.File]::WriteAllText((Join-Path $edgeRoot 'Guest Profile\Bookmarks'), $json)
    [IO.File]::WriteAllText((Join-Path $edgeRoot 'Local State'), '{"profile":{"last_used":"Profile 1","info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"},"..\\Outside":{"name":"Ignore"}}}}')
    $beforeHash = (Get-FileHash -LiteralPath $bookmarkPath).Hash
    $beforeFiles = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force).Count
    $profiles = @(Get-EeaEdgeProfiles -UserDataPath $edgeRoot)
    Assert-Favorite ($profiles.Count -eq 2) 'Discover real profiles, not Guest or paths from Local State.'
    Assert-Favorite ($profiles[0].DisplayName -eq 'Personal (Default)') 'Use a friendly profile name with its folder identifier.'
    Assert-Favorite $profiles[1].IsLastUsed 'Identify the last-used profile.'
    $favorites = @(Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot)
    Assert-Favorite ($favorites.Count -eq 7) 'Read all bar items, including folders, but not other favorites roots.'
    Assert-Favorite ($favorites[0].Name -eq 'News Today') 'Adapt favorite titles to safe shortcut names.'
    Assert-Favorite ($favorites[0].Url -ceq 'https://example.com/?first=1&second=2#/home') 'Preserve query and fragment.'
    Assert-Favorite ($favorites[1].Folder -eq 'Daily / Reading' -and $favorites[1].Name -eq 'example.org') 'Traverse nested folders and handle empty names.'
    Assert-Favorite ($favorites[2].Name -eq 'Website NUL') 'Adapt Windows device names.'
    Assert-Favorite (@($favorites | Where-Object CanImport).Count -eq 3) 'Unsafe schemes and credentials remain unavailable.'
    Assert-Favorite ((Get-FileHash -LiteralPath $bookmarkPath).Hash -eq $beforeHash) 'Discovery must not write to Edge bookmarks.'
    Assert-Favorite (@(Get-ChildItem -LiteralPath $testRoot -Recurse -Force).Count -eq $beforeFiles) 'Discovery must not create any files or folders.'
    Assert-FavoriteRejected { Get-EeaEdgeFavorites -ProfileDirectory '..\Outside' -UserDataPath $edgeRoot }
    $longTitle = ('a' * 59) + [char]0xd83d + [char]0xde00
    Assert-Favorite ((ConvertTo-EeaFavoriteName -Title $longTitle -Website 'https://example.com/').Length -eq 59) 'Do not split UTF-16 surrogate pairs.'
    $sharing = [IO.File]::Open($bookmarkPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { Assert-Favorite (@(Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot).Count -eq 7) 'Read while Edge has its bookmark file open.' }
    finally { $sharing.Dispose() }
    [IO.File]::WriteAllText($bookmarkPath, '{"roots":{"bookmark_bar":{"type":"folder","children":[]}}}')
    Assert-Favorite (@(Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot).Count -eq 0) 'An empty bar is valid.'
    [IO.File]::WriteAllText($bookmarkPath, '{"roots":{"bookmark_bar":{"type":"folder","children":{}}}}')
    Assert-FavoriteRejected { Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot }
    [IO.File]::WriteAllText($bookmarkPath, '{broken JSON')
    Assert-FavoriteRejected { Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot }
    [IO.File]::WriteAllBytes($bookmarkPath, [byte[]](0xff, 0xff, 0xff))
    Assert-FavoriteRejected { Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot }
    $oversized = [IO.File]::Create($bookmarkPath)
    try { $oversized.SetLength(16MB + 1) } finally { $oversized.Dispose() }
    Assert-FavoriteRejected { Get-EeaEdgeFavorites -ProfileDirectory 'Default' -UserDataPath $edgeRoot }
    Write-Host "PASS: Favorites discovery, profiles, nested folders, safe names, unsupported URLs, read-only access, and malformed input on PowerShell $($PSVersionTable.PSVersion)."

    [IO.File]::WriteAllText($bookmarkPath, $json, (New-Object Text.UTF8Encoding($false)))
    $context = [pscustomobject]@{ Root = (Join-Path $testRoot 'Apps'); Desktop = (Join-Path $testRoot 'Desktop'); Programs = (Join-Path $testRoot 'Programs') }
    $null = Install-EeaApp -AppName 'Existing news' -Website 'https://example.com/?first=1&second=2#/home' -Context $context -Confirm:$false
    $foreignPath = Join-Path $context.Desktop 'example.org.lnk'
    [IO.File]::WriteAllText($foreignPath, 'Unrelated desktop shortcut')
    $choices = @(Get-EeaFavoriteChoices -ProfileDirectory 'Default' -UserDataPath $edgeRoot -Context $context)
    Assert-Favorite ($choices[0].Status -eq 'Already added' -and -not $choices[0].CanImport) 'Do not duplicate an already configured website under another favorite title.'
    Assert-Favorite ($choices[1].Name -eq 'example.org (2)' -and $choices[1].CanImport) 'Preview a nonconflicting name instead of overwriting an unrelated shortcut.'
    $kit = New-EeaFavoritesKit -Favorites @($choices | Where-Object CanImport)
    $importPreview = @(Get-EeaKitPreview -Kit $kit -NewOnly -Context $context)
    $result = Import-EeaKit -Kit $kit -ExpectedPreview $importPreview -NewOnly -Context $context -Confirm:$false
    Assert-Favorite $result.Completed 'Selected favorites must use the safe App Kit import path.'
    Assert-Favorite ([IO.File]::ReadAllText($foreignPath) -ceq 'Unrelated desktop shortcut') 'Never replace unrelated shortcuts.'
    Assert-Favorite (@(Get-EeaFavoriteChoices -ProfileDirectory 'Default' -UserDataPath $edgeRoot -Context $context | Where-Object CanImport).Count -eq 0) 'Repeated favorites imports should not duplicate saved websites.'
    Assert-Favorite ((Get-FileHash -LiteralPath $bookmarkPath).Hash -ceq $beforeHash) 'Import must leave Edge favorites byte-identical.'
    Assert-FavoriteRejected { ConvertTo-EeaWebsite ('https://example.com/' + ([string][char]0x4e2d * 700)) }
    Write-Host "PASS: Favorites selection, safe name collisions, idempotent imports, unchanged Edge data, and encoded URL bounds on PowerShell $($PSVersionTable.PSVersion)."
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }