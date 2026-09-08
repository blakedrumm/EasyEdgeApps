# Command-Line Automation

These examples apply to [Easy Edge Apps](../EasyEdgeApps.ps1) version 1.2.0 or later, including `-Unattended` and selected kit imports. Windows PowerShell 5.1 and PowerShell 7 on Windows are supported.

Run as the Windows user whose shortcuts you intend to manage, not as SYSTEM, an administrator, or a different helper account. The application is still one script; no module, service, or scheduled task is installed.

For built-in help, run `.\EasyEdgeApps.ps1 --help`, `.\EasyEdgeApps.ps1 -h`, or `.\EasyEdgeApps.ps1 -?`. `-Help` is also supported. Each example explains its scenario and effects; `--help`, `-h`, and `-Help` use compact spacing, while `-?` retains PowerShell's native formatting. Help does not open setup or perform an operation. Use `-h`, `-Help`, or `-?` when combining help with an explicit `-Action`.

## Unattended approval

`-Unattended` is explicit approval for the requested command. It disables confirmation prompts, suppresses routine host messages and formatted previews, and returns result objects. It never opens the setup window. Missing passwords, invalid parameters, damaged kits, conflicting files, and failed changes return promptly with an error.

It does not bypass validation, ownership checks, locking, recovery checks, or stale-preview protection. Exporting over an existing file still requires `-Replace`. `-Preview` and `-WhatIf` remain read-only. `-Quiet` alone is not approval; `-Confirm:$false` remains available for existing scripts. `-Unattended -Confirm` is rejected as contradictory; explicitly specifying `-Confirm:$false` is harmless.

Only an explicit `-Action Open` or install `-Launch` requests a browser launch. Those options can still expose Edge's normal first-run, profile, and sign-in dialogs. Avoid them in background jobs.

Website URLs supplied to commands or kits must include `https://` or `http://`. Commands preserve that scheme and do not probe, download icons, or automatically upgrade addresses. HTTPS-first resolution and icon retrieval are setup-window features. Prefer HTTPS: explicitly supplying HTTP approves an unencrypted destination, including under `-Unattended`. Never include passwords or other secrets in URLs. Favorites import remains HTTPS-only, and kits containing HTTP URLs require application version 1.2.0 or later.

## Commands

Use absolute paths in task runners, and create the private export folder beforehand. Readable kits contain private website addresses and notes; protect their destination folder or use a protected export.

```powershell
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/' -Unattended
.\EasyEdgeApps.ps1 -Action List -Unattended
.\EasyEdgeApps.ps1 -Action Open -Name 'My Mail' -Unattended

.\EasyEdgeApps.ps1 -Action ExportKit -Path 'C:\Backups\Family.eeakit.json' -Replace -Unattended
.\EasyEdgeApps.ps1 -Action ImportKit -Path 'C:\Backups\Family.eeakit.json' -Preview -Unattended
.\EasyEdgeApps.ps1 -Action ImportKit -Path 'C:\Backups\Family.eeakit.json' -AppNames 'My Mail' -Unattended

.\EasyEdgeApps.ps1 -Action ListFavorites -EdgeProfile 'Default' -Unattended
.\EasyEdgeApps.ps1 -Action ImportFavorites -EdgeProfile 'Default' -AppNames 'My Mail' -Preview -Unattended
.\EasyEdgeApps.ps1 -Action ImportFavorites -EdgeProfile 'Default' -AppNames 'My Mail' -Unattended

.\EasyEdgeApps.ps1 -Action Check -Unattended
.\EasyEdgeApps.ps1 -Action Repair -AppNames 'My Mail' -WhatIf -Unattended
.\EasyEdgeApps.ps1 -Action Repair -AppNames 'My Mail' -Unattended
.\EasyEdgeApps.ps1 -Action Remove -Name 'My Mail' -WhatIf -Unattended
.\EasyEdgeApps.ps1 -Action Remove -Name 'My Mail' -Unattended
```

Choose proposed names from `ListFavorites`, which may differ from bookmark titles. Specify `-EdgeProfile` for predictable profile selection; browser data is never written. Up to 100 apps can be imported per operation.

| Action | Selection and options | Unattended result |
| --- | --- | --- |
| `Install` | `-Name`, `-Url`; optional `-IconPath`, `-Notes`, `-NoDesktop`, `-NoStartMenu`, `-Launch` | Saved name, URL, and placement |
| `List` | All saved apps | Name, URL, and placement per app |
| `ExportKit` | `-Path`; optional `-AppNames`, `-KitName`, `-Notes`, `-Replace`, password options | Destination, protection flag, app count |
| `ImportKit` | `-Path`; optional `-AppNames`, `-Password`, `-Preview` | Preview rows or per-app application results |
| `ListFavorites` | Optional `-EdgeProfile`, `-EdgeUserDataPath` | Available and unavailable Favorites rows |
| `ImportFavorites` | Optional `-EdgeProfile`, `-EdgeUserDataPath`, `-AppNames`, placement options, `-Preview` | Preview rows or per-app application results |
| `Check` | Optional `-Name` or `-AppNames`; otherwise all saved apps | Status, repairability, and issues |
| `Repair` | Required `-Name` or `-AppNames`; optional `-Preview` | Check rows or per-app repair results |
| `Remove` | Required `-Name` | Exit code; no routine result object |
| `Open` | Required `-Name` | Exit code; no routine result object |

Omitting `-AppNames` exports all saved apps or imports the entire kit. An explicitly empty array, unknown kit name, or invalid name fails instead of silently selecting everything. Names are normalized and case-insensitive. Import always validates the complete source kit before selecting apps, and leaves other installed apps alone. A conflict in the selected batch prevents all preflight writes; a later filesystem failure can leave earlier apps completed.

## Process invocation

For a task runner or another shell, use a dedicated noninteractive PowerShell process:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\Tools\EasyEdgeApps.ps1' -Action ExportKit -Path 'C:\Backups\Family.eeakit.json' -Replace -Unattended
```

`pwsh.exe` accepts the same options. The execution-policy flag applies only to that process; it does not override organizational restrictions. For a scheduled job, run under the intended user's account with its profile available. Use a private, accessible destination and check the process exit code. These examples do not create a task or change Windows policy.

## Results and exit codes

- `0`: The unattended command completed, or a requested preview/WhatIf completed without writes. Repeated imports can report `Unchanged`; a Favorites import with nothing new returns no rows.
- `1`: Invalid arguments, missing/wrong passwords, conflicting state, unreadable files, or failed/partial application. Inspect per-app results when available. Earlier successfully applied apps can remain after a later failure.
- `Check` and read-only previews report findings as data. Exit `0` does not mean all apps are healthy or that websites work.

`-Unattended` sets success to exit `0` explicitly, including when invoked from another PowerShell script after an earlier failed command. Capture `$LASTEXITCODE` immediately after invocation.

Success-stream results are ordinary PowerShell objects. For a stable JSON array, including an empty result, use `ConvertTo-Json -InputObject`:

```powershell
$tool = 'C:\Tools\EasyEdgeApps.ps1'
$results = @(& $tool -Action Check -Unattended)
$operationExitCode = $LASTEXITCODE
ConvertTo-Json -InputObject $results -Depth 8 -Compress
if ($operationExitCode -ne 0) { exit $operationExitCode }
if (@($results | Where-Object { $_.Status -ne 'Healthy' }).Count -gt 0) { exit 2 }
exit 0
```

This monitoring example deliberately maps unhealthy findings to wrapper exit `2`; that is not an additional application exit code. Keep error/warning streams separate from JSON. Use `-Preview` for machine-readable proposed changes; normal `-WhatIf` messages remain visible. Results and errors can contain private names, paths, and URLs, so protect logs.

## Passwords in automation

The tool accepts `SecureString` passwords, not plaintext strings, environment-variable names, password-file paths, or credentials on the process command line. A missing password fails without a prompt. Protected exports also require `-PasswordConfirmation`; automation can explicitly pass the same already-provisioned secret to both parameters.

Use an existing secret provider that returns a `SecureString`, or caller-managed Windows DPAPI storage. The tool neither provisions nor reads a password store automatically. DPAPI files are usable by the same Windows account on the same computer; they are not portable kit files or a password-recovery mechanism. Protect the file with normal Windows permissions, keep it outside the repository, and never distribute it with a kit. Same-user processes can decrypt it.

For a one-time, interactive provision using a passphrase already verified with a trusted kit:

```powershell
$secretDirectory = Join-Path $env:LOCALAPPDATA 'EasyEdgeAppsAutomation'
$secretFile = Join-Path $secretDirectory 'kit-password.dpapi'
$kitPassword = Read-Host 'Previously verified App Kit passphrase' -AsSecureString
try {
    New-Item -ItemType Directory -Path $secretDirectory -Force | Out-Null
    $kitPassword | ConvertFrom-SecureString | Set-Content -LiteralPath $secretFile -Encoding ASCII
}
finally { $kitPassword.Dispose() }
```

The following PowerShell job body loads that protected value and runs a protected export. Set `$operation` to `ImportKit` to restore instead; import never implicitly launches a browser.

```powershell
$ErrorActionPreference = 'Stop'
$tool = 'C:\Tools\EasyEdgeApps.ps1'
$operation = 'ExportKit'
$kitPath = 'C:\Backups\Private.eeakit.json'
$secretFile = Join-Path $env:LOCALAPPDATA 'EasyEdgeAppsAutomation\kit-password.dpapi'
$kitPassword = $null
$operationExitCode = 1
try {
    $kitPassword = ConvertTo-SecureString -String ((Get-Content -LiteralPath $secretFile -Raw).Trim())
    $options = @{
        Action = $operation
        Path = $kitPath
        Password = $kitPassword
        Unattended = $true
    }
    if ($operation -eq 'ExportKit') {
        $options.Protected = $true
        $options.PasswordConfirmation = $kitPassword
        $options.Replace = $true
    }
    $results = @(& $tool @options)
    $operationExitCode = $LASTEXITCODE
    ConvertTo-Json -InputObject $results -Depth 8 -Compress
}
catch {
    [Console]::Error.WriteLine('App Kit automation failed: ' + $_.Exception.Message)
    $operationExitCode = 1
}
finally {
    if ($null -ne $kitPassword) { $kitPassword.Dispose() }
}
exit $operationExitCode
```

Test secret access from the actual job account before relying on scheduled exports. Do not add a plaintext fallback for unavailable secrets. Portable-kit encryption remains experimental pending independent review; see [Security](../SECURITY.md). Installed shortcuts/settings and ordinary browser traffic are not encrypted by App Kit protection.