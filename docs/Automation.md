# Command-Line Automation

These examples apply to [Easy Edge Apps](../EasyEdgeApps.ps1) version 1.4.0. Window modes, separate-profile selection, and Always on top require 1.4.0. Earlier features retain their minimum versions: unattended commands and selected kit imports 1.2.0, per-app normal-profile identifiers 1.3.0, Fresh choices 1.3.2, and Guest launchers 1.3.3. Windows PowerShell 5.1 and PowerShell 7 on Windows are supported.

Run as the Windows user whose shortcuts you intend to manage, not as SYSTEM, an administrator, or a different helper account. The portable application is still one script; the optional MSI installs that same script and a graphical manager launcher. No module, service, or scheduled task is installed. Automate the script directly, not the MSI launcher, which accepts no forwarded options.

The setup window's **Taskbar** checkbox requests a real Windows-approved pin and selects a dedicated app profile/window identity. There is no public CLI taskbar switch or unattended pinning action. CLI updates and repair preserve an existing Taskbar choice without requesting pins; `-NoStartMenu` is rejected for such apps. App Kits do not contain Taskbar intent or Windows pin state. See the [taskbar workflow](../README.md#pin-a-website-to-the-taskbar).

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
| `Install` | `-Name`, `-Url`; optional `-IconPath`, `-Notes`, `-EdgeProfile`, `-ProfileMode`, `-SessionMode`, `-LaunchMode`, `-AlwaysOnTop`, `-NoDesktop`, `-NoStartMenu`, `-Launch` | Saved name, URL, and placement |
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

## Edge profiles

New apps default to `-ProfileMode Dedicated`, an independent persistent profile. Existing apps retain their route unless `-ProfileMode` is supplied. Use `-ProfileMode Shared` explicitly to use normal Edge. No normal cookies or sign-ins are copied, and separate data is retained after switching away or removing an app. Taskbar keeps the dedicated route selected even with Fresh enabled; clear Taskbar in setup before selecting a shared route.

Install also accepts an optional normal launch-profile identifier. It is retained but unused while a separate or Fresh profile is active. This differs from `-EdgeProfile` on Favorites commands, where it only selects the local browser data to read.

```powershell
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/' -ProfileMode Shared -EdgeProfile 'Profile 1' -Unattended
.\EasyEdgeApps.ps1 -Action Open -Name 'My Mail' -Unattended

# Restore Edge-controlled profile selection for this app.
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/' -ProfileMode Shared -EdgeProfile '' -Unattended
```

Only the exact identifiers `Default`, `Profile ` followed by one to six digits, or an empty string are accepted. The CLI validates the identifier, not the profile's physical existence or sign-in state. Use the intended local Stable Edge profile. No arbitrary flags, user-data paths, or browser credentials are accepted as launch arguments.

An explicit value overrides the app's saved choice. Without `-EdgeProfile`, an existing app retains its profile and a new app uses the default from Settings. Repair and Open use the stored profile. App Kits never contain profile identifiers; existing imported apps retain their choice and newly imported apps use the destination user's default. Kit placement remains controlled by the kit. The Settings placement defaults affect the main new-website editor, not CLI `-NoDesktop`/`-NoStartMenu` behavior.

`-EdgeUserDataPath` remains a discovery source for Setup and Favorites commands, not a browser launch destination. Automatic update checking is confined to setup; command-line operations do not contact the update service. The opt-in diagnostic file is not a CLI transcript, so protect any separate automation logs and JSON output.

## Fresh sessions

Install accepts `-SessionMode Fresh` or `-SessionMode Normal`. Normal means Fresh is off, not that the profile is Shared. Omission preserves an existing website's choice; new websites default to Normal and Dedicated. This option is not accepted by Open or other actions: Open always uses the saved mode.

```powershell
# Start this website with an empty independent Guest profile on every launch.
.\EasyEdgeApps.ps1 -Action Install -Name 'Shared website' -Url 'https://example.com/' -SessionMode Fresh -Unattended
.\EasyEdgeApps.ps1 -Action Open -Name 'Shared website' -Unattended

# Explicitly restore persistent browsing for the same website.
.\EasyEdgeApps.ps1 -Action Install -Name 'Shared website' -Url 'https://example.com/' -SessionMode Normal -Unattended
```

`-Unattended` approves the mode change, including returning to persistent storage. `-WhatIf` does not compile a launcher or create app data. `-EdgeProfile` is saved but unused while Fresh or Dedicated is enabled. Disabling Fresh retains the selected profile route. To explicitly return to shared browsing, also supply `-ProfileMode Shared`, choose a compatible launch mode, and turn Always on top off; a Taskbar app must first opt out through setup.

Fresh launches use a locally compiled, no-argument Windows executable, not a PowerShell session. It creates a unique temporary Edge Guest profile each time and removes that profile after its browser process tree ends. Guest mode prevents Edge browser-account sign-in and sync; website sign-in remains available. Cookies, cache, and site data are not reused across launches. Normal Edge data and downloaded files remain; website sign-ins may need repeating, and OS/site SSO is not guaranteed to be disabled. Persistent cleanup failures show a warning and leave marked data for retry on a later fresh launch, never for reuse. This is not secure erasure.

Saving, importing, and repairing Fresh websites require the Windows .NET Framework compiler. Browsing requires a non-elevated interactive user session and available Guest mode. A `UserDataDir` override, disabled `BrowserGuestModeEnabled`, forced `BrowserSignin`, or application-control restriction can block launch; there is no policy bypass or normal-profile fallback. Close fresh windows before updating/removing the website. CLI Open returns after starting the launcher, not after browsing or cleanup; exit 0 is not proof of session completion.

After upgrading from 1.3.2, use `-Action Check` and an approved `-Action Repair -AppNames 'Shared website' -Unattended` to rebuild existing fresh-session launchers with Guest mode. MSI maintenance does not rebuild them, and Open does not silently replace them. Repair preserves saved URLs, normal-profile choices, and the Fresh setting.

Exports containing any fresh website use kit schema 2, which requires 1.3.2 or later. Schema 2 applies each stored Boolean choice, including false; preview before unattended import. Schema 1 preserves existing destination Fresh choices and remains the export format for entirely non-Fresh kits. No executable, browser data, window state, local profile selection, or Taskbar choice travels. New imports default to Dedicated and RememberLast; destination-local preferences are preserved for existing apps. A kit cannot remove a Taskbar app's required Start entry. New local schema-4 state requires 1.4.0; legacy schemas 1/2/3 remain readable without an automatic profile conversion. Unpin old Edge-targeting entries and use setup for verified launcher pins.

## Window preferences

Install accepts `-LaunchMode RememberLast`, `Maximized`, or `FullScreen`, and `-AlwaysOnTop` or `-AlwaysOnTop:$false`. Omitted values preserve existing preferences. New apps default to RememberLast with topmost off; legacy apps retain their maximized behavior until explicitly changed.

```powershell
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/' -ProfileMode Dedicated -LaunchMode RememberLast -AlwaysOnTop -Unattended
.\EasyEdgeApps.ps1 -Action Install -Name 'Display' -Url 'https://example.com/' -LaunchMode FullScreen -Unattended
```

RememberLast stores bounded app-specific size, position, and normal/maximized state outside browser data. Minimized/fullscreen geometry is not saved. Missing or unreadable geometry does not block launch. Shared profiles use Edge's placement behavior instead of independent launcher control. Maximized requests a new maximized window. Reopening a running persistent app focuses its current window rather than resetting it.

FullScreen requires a Dedicated or Fresh profile. Escape exits fullscreen through the narrowly scoped owned-window handler; the next launch still uses the saved preference. AlwaysOnTop also requires an owned profile and cannot be combined with FullScreen. Invalid combinations fail before staging. These settings are local-only and are preserved by Repair and existing-app imports.

Close owned website windows before changing these preferences, then reopen the current shortcut. Open accepts no one-time window override. Local state with the new preferences uses schema 4; older application versions reject it instead of guessing. No Edge right-click menu command or kiosk lockdown is added.

## Process invocation

For a task runner or another shell, use a dedicated noninteractive PowerShell process:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\Tools\EasyEdgeApps.ps1' -Action ExportKit -Path 'C:\Backups\Family.eeakit.json' -Replace -Unattended
```

`pwsh.exe` accepts the same options. The execution-policy flag applies only to that process; it does not override organizational restrictions. For a scheduled job, run under the intended user's account with its profile available. Use a private, accessible destination and check the process exit code. These examples do not create a task or change Windows policy.

For an MSI installation, the script normally resides at `$env:LOCALAPPDATA\Programs\Easy Edge Apps\EasyEdgeApps.ps1`. Use an absolute path and invoke it with the call operator, for example `& "$env:LOCALAPPDATA\Programs\Easy Edge Apps\EasyEdgeApps.ps1" -Action List -Unattended`. MSI maintenance commands and build prerequisites are documented in [Installer](Installer.md).

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