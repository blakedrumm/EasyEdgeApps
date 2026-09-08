# Easy Edge Apps

One PowerShell script that turns trusted websites into easy-to-find Microsoft Edge app-window shortcuts on Windows 11.

A helper sets it up once in the person's Windows account. Everyday use is opening a familiar Desktop or Start menu shortcut, with no PowerShell window, administrator prompt, or extra launcher running in the background.

Set up someone's everyday websites once. Restore and maintain that familiar setup whenever they need help.

[Download the script](https://github.com/blakedrumm/EasyEdgeApps/releases/latest/download/EasyEdgeApps.ps1) | [Latest release](https://github.com/blakedrumm/EasyEdgeApps/releases/latest) | [Automated checks](https://github.com/blakedrumm/EasyEdgeApps/actions/workflows/test.yml)

**Version 1.1.0:** Includes App Kits, optional password-protected exports, Favorites import, helper notes, and Check and Repair. Encrypted exports are experimental and require independent security review before production use. See the [release notes](docs/releases/v1.1.0.md).

## Setup for a family member

1. Sign in to **the Windows account that will use the shortcuts**. Do not run setup as administrator or as another user.
2. Download **EasyEdgeApps.ps1** using the link above. This is the only file needed to use the program. Review the script before running it.
3. Right-click the downloaded file and choose **Run with PowerShell**. On Windows 11 this may be under **Show more options**. If local execution policy prevents that, a helper can use the one-time command below.
4. Enter a familiar name, such as **My Mail**, and the site's normal **https://** address. Leave Desktop and Start menu selected unless you deliberately want only one location.
5. Select **Add website**, then **Open**. Complete any Edge first-run prompts and website sign-in together. Check the site's text size, links, and any printing or video calling the person needs.
6. Close setup. The person can now open the website using its shortcut. Keep the script somewhere the helper can find it for future changes.

For a file downloaded to the usual Downloads folder:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\EasyEdgeApps.ps1"
```

This execution-policy option applies only to that PowerShell process. It does not change the computer's saved policy. The script is unsigned; review it and obtain it from this repository. Do not disable SmartScreen, antivirus, or organizational controls to make it run. On a managed computer, ask its administrator if execution is blocked.

Use ordinary site addresses, not password-reset links, one-time sign-in links, or URLs containing secrets. Addresses, including query strings and fragments, are saved locally in clear text.

![The setup window with a saved website, name and address fields, and large native Windows controls.](docs/images/setup.png)

## Everyday experience

- A directly launchable Desktop shortcut and a Start menu entry under **Easy Edge Apps**.
- Edge opens the website in app mode and requests a maximized window. Edge and Windows ultimately control window placement.
- A distinctive, locally generated letter icon, or an optional existing `.ico` file. No third-party icon services or downloads.
- Existing Edge profile behavior, website sign-ins, and browser security remain in Edge's control. No separate browser profile is created or forcibly selected.
- Setup uses native Windows controls, keyboard navigation, accessible names, system colors, and a resizable layout. Destructive confirmation defaults to **No**.

The intended setup operator is a helper. The person using the shortcuts does not need to manage PowerShell.

## Change or remove a website

Run the same script again, select a saved website, and use **Save changes**, **Open**, or **Remove**. Changing an address updates that app's existing shortcuts. Running an install again with the same name also repairs missing shortcuts.

Names identify apps and are case-insensitive. To rename one, add the new name, check it works, then remove the old entry. Removal keeps website accounts, cookies, passwords, history, and all other browser data. Files added by someone else are preserved.

Do not edit the managed shortcut, saved icon, or settings by hand. Setup refuses to replace or remove an existing shortcut whose ownership fields do not match. Move an unrelated conflicting shortcut out of the way yourself, or choose a different name; there is deliberately no force-overwrite option.

## Gather the Edge Favorites bar

Select **Edge Favorites bar...**, choose the intended local Edge profile, and review the list. It includes websites inside nested Favorites bar folders, with their folder context. Other favorites folders, history, cookies, credentials, and cloud-only items are not imported.

Select individual available rows or **All available**, choose Desktop and Start menu placement, then select **Add Selected** and approve. Up to 100 websites can be added per operation. For a larger bar, add a smaller selection, refresh, and continue.

Only valid HTTPS websites can be selected. HTTP, browser-internal pages, executable schemes, malformed links, and addresses with embedded credentials remain unavailable with a reason. The tool does not silently upgrade HTTP addresses. Existing canonical URLs and duplicate links are marked unavailable; colliding shortcut names get a numbered alternative in the preview. Existing apps are never updated by Favorites import.

Only locally present Stable Edge `Default` and `Profile <number>` profiles are offered. Friendly profile names and the last-used hint come from Local State when readable. Let Edge finish its normal sync if expected items are missing, then select **Refresh**. This is a read-only snapshot of the local Favorites bar: the tool never writes browser files, forces sync, closes Edge, or changes favorites. Choosing a profile here does not force that profile when shortcuts launch.

## Portable App Kits

An App Kit is one named `.eeakit.json` file containing selected website names, HTTPS addresses, Desktop/Start menu choices, optional plain-text helper notes, and portable icons. Generated icons are recreated locally; custom icons are embedded as validated bytes. No installed paths, browser data, credentials, browser flags, commands, or original icon-file dependencies are included.

### Family or replacement-PC workflow

1. Configure and test the websites in the family member's Windows account. Optional **Helper notes** stay with each saved app; never put passwords or recovery codes there.
2. Select **Export App Kit...**. Choose a name, websites, optional kit notes, and either readable standard JSON or password protection. The window explains which data the file exposes.
3. For a protected export, enter and confirm a strong unique passphrase of at least 12 characters. Save the kit privately; share its password separately. A forgotten password cannot be recovered.
4. On the replacement computer, sign in as the intended Windows user and run the same reviewed script. Select **Import App Kit...** and the kit file. Protected kits unlock only in memory.
5. Review additions, updates, unchanged apps, conflicts, helper notes, and exact old/new URLs. Destination-domain changes are explicitly flagged. Select the changes to apply, then approve **Import Selected**.
6. Open the resulting shortcuts and test the real websites with the person. Website accounts and sign-in sessions do not move with the kit.

Repeated imports do not duplicate apps. Apps absent from the kit stay installed. The whole selected payload is validated before any installation writes; conflicts are not force-overwritten. The GUI can exclude conflicts from a selected batch. The CLI applies the whole kit and stops preflight if any app conflicts.

Changes use the existing per-app staging, ownership, locking, and rollback protections. A kit is **not one atomic transaction**: if a later app fails, earlier completed apps remain. Results identify added, updated, unchanged, failed, and not-attempted apps. Refresh the preview after resolving the cause.

### Password protection and privacy

The entire payload, including kit name, notes, app metadata, URLs, and custom icons, is encrypted. The outer file still reveals its format, algorithm, KDF settings, salt, IV, ciphertext length, and authentication tag. The filename is not encrypted; choose a non-sensitive one.

The portable format uses platform PBKDF2-HMAC-SHA256 (600,000 iterations) and the RFC 7518 A256CBC-HS512 authenticated-encryption construction. Both Windows PowerShell 5.1 and PowerShell 7 use the same format; it is not tied to a Windows account. See the [format and cryptographic specification](docs/App-Kit-Format.md) and [security boundaries](SECURITY.md).

Password protection applies **only to the exported file**. Installed settings, shortcuts, icons, recovery data, and readable exports are not encrypted. Browser sessions and normal network visibility are unchanged. Weak passwords can be guessed offline, authentication does not prove the sender's identity, and managed-memory cleanup is best-effort. No passwords or derived keys are saved. There is no silent plaintext fallback. Treat encryption as awaiting independent review, not as a production-security guarantee.

## Check and Repair

Select **Check Apps...** for read-only diagnostics. Select repairable rows and **Repair Selected** to review and approve repairs. The main window keeps Check Apps accessible even when saved settings are damaged.

| Status | Meaning |
| --- | --- |
| Healthy | Owned local files match saved settings; the website was not tested |
| Repairable | A shortcut or icon is missing, or owned shortcuts need the currently discovered Edge executable |
| Conflict | Settings or owned artifacts are damaged, modified, ambiguous, or occupied by unrelated files |
| Blocked | Edge is unavailable, a path is unsafe/unreadable, or pending recovery needs attention |

Repair recreates only verified owned artifacts at safely unoccupied destinations. A missing custom icon becomes an automatic letter icon unless restored from a trusted kit. Modified or undecodable existing icons and shortcuts are conflicts, not permission to overwrite. If files change after the check, a fresh check is required. Pending recovery and unknown files are preserved.

Repair does not probe private URLs, sign in, repair accounts, bypass permissions, or diagnose outages. A repaired shortcut is not proof that the website works.

## Command-line use

Windows PowerShell 5.1 is built into Windows 11. PowerShell 7 on Windows is also supported. No modules need to be installed.

```powershell
# Add or update both shortcuts.
.\EasyEdgeApps.ps1 -Action Install -Name 'My Mail' -Url 'https://outlook.live.com/mail/'

# Preview an installation without writing files or opening a browser.
.\EasyEdgeApps.ps1 -Action Install -Name 'My News' -Url 'https://www.bbc.com/news' -WhatIf

# Use an existing icon, omit the Desktop shortcut, and open after saving.
.\EasyEdgeApps.ps1 -Action Install -Name 'My Calendar' -Url 'https://outlook.live.com/calendar/' -IconPath '.\calendar.ico' -NoDesktop -Launch

# List saved websites.
.\EasyEdgeApps.ps1 -Action List

# Open or remove an existing entry.
.\EasyEdgeApps.ps1 -Action Open -Name 'My Mail'
.\EasyEdgeApps.ps1 -Action Remove -Name 'My Mail' -WhatIf
.\EasyEdgeApps.ps1 -Action Remove -Name 'My Mail' -Confirm
```

`-NoStartMenu` omits the Start menu shortcut. At least one location must be selected. `-Quiet` suppresses routine command-line install/remove messages, not errors or safety warnings. Command-line operations do not show setup dialogs. Failures return exit code 1. Use `-Quiet` with an explicit command-line action, not the default setup action.

`-Name` and `-Url` together imply `-Action Install` when no action is supplied. Website addresses must be absolute HTTPS URLs. Arbitrary Edge switches, embedded credentials, HTTP, and executable URL schemes are intentionally unsupported. Query strings and fragments are preserved for sites that depend on them.

### Favorites and maintenance commands

```powershell
.\EasyEdgeApps.ps1 -Action ListFavorites -EdgeProfile 'Default'
.\EasyEdgeApps.ps1 -Action ImportFavorites -EdgeProfile 'Default' -Preview
.\EasyEdgeApps.ps1 -Action ImportFavorites -EdgeProfile 'Default' -AppNames 'My News', 'My Mail' -WhatIf
.\EasyEdgeApps.ps1 -Action ImportFavorites -EdgeProfile 'Default' -AppNames 'My News', 'My Mail'

.\EasyEdgeApps.ps1 -Action Check
.\EasyEdgeApps.ps1 -Action Repair -Name 'My News' -Preview
.\EasyEdgeApps.ps1 -Action Repair -AppNames 'My News', 'My Mail' -WhatIf
.\EasyEdgeApps.ps1 -Action Repair -AppNames 'My News', 'My Mail'
```

Use proposed `Name` values from `ListFavorites` for selection, not the original unsanitized title. Without `-EdgeProfile`, listing includes all discovered profiles; import chooses the last-used one when known, otherwise the first. Specify a profile for predictable automation. `-EdgeUserDataPath` selects another local Edge User Data root for discovery, not an installation destination. It is also accepted by `Setup`.

### App Kit commands

```powershell
.\EasyEdgeApps.ps1 -Action ExportKit -KitName 'Family websites' -AppNames 'My News', 'My Mail' -Notes 'Call the helper for setup changes.' -Path '.\Family.eeakit.json'
.\EasyEdgeApps.ps1 -Action ImportKit -Path '.\Family.eeakit.json' -Preview
.\EasyEdgeApps.ps1 -Action ImportKit -Path '.\Family.eeakit.json' -WhatIf
.\EasyEdgeApps.ps1 -Action ImportKit -Path '.\Family.eeakit.json'
```

Export defaults to all saved apps when `-AppNames` is omitted. At least one and at most 100 apps are allowed. Export requires an existing parent folder and a filename ending `.eeakit.json`; an existing destination requires explicit `-Replace`. GUI file selection also asks before replacement. Failed or stale replacements preserve the previous file where the filesystem supports atomic replacement.

Ask for passwords explicitly in an interactive helper session, never as command-line literals or environment variables:

```powershell
$kitPassword = Read-Host 'Strong export passphrase' -AsSecureString
$confirmation = Read-Host 'Repeat export passphrase' -AsSecureString
try {
	.\EasyEdgeApps.ps1 -Action ExportKit -Path '.\Private.eeakit.json' -Protected -Password $kitPassword -PasswordConfirmation $confirmation
}
finally {
	$kitPassword.Dispose()
	$confirmation.Dispose()
}

$kitPassword = Read-Host 'App Kit password' -AsSecureString
try {
	.\EasyEdgeApps.ps1 -Action ImportKit -Path '.\Private.eeakit.json' -Password $kitPassword -Preview
	.\EasyEdgeApps.ps1 -Action ImportKit -Path '.\Private.eeakit.json' -Password $kitPassword
}
finally { $kitPassword.Dispose() }
```

The script accepts `SecureString` parameters; it never unexpectedly opens a password prompt. A missing password fails promptly, including under `-NonInteractive`. `-Preview` lists data without applying it; `-WhatIf` describes writes without performing them. An encrypted import still needs to unlock before showing a meaningful preview. Protected export `-WhatIf` does not ask for passwords or create staging.

Import, export, and repair request confirmation by default. In reviewed automation, `-Confirm:$false` is explicit approval. Noninteractive use without required approval fails rather than waiting. Wrong passwords, unsupported parameters, conflicts, and failed/partial applications return exit code 1. A declined action or `-WhatIf` leaves files unchanged and returns normally. `Check` reports findings as structured data; a completed check is not an installation success claim. Outputs and previews can contain private names and URLs, so do not publish transcripts.

## What it does not do

This creates **Edge app-window shortcuts**, not fully registered Progressive Web Apps. It does not promise an independent taskbar identity, an entry in Installed apps, or automatic Start/taskbar pinning. Windows may group app windows with Edge. Use Edge's own **Install this site as an app** feature when native PWA registration is required.

It does not bypass pop-up blockers, grant camera or microphone permissions, change the default browser, configure auto-login, suppress website prompts, disable security checks, or modify browser policies. It is not a kiosk or a security boundary. Some sign-in links and external links can open a normal browser window.

Internet access and a working, updated Microsoft Edge are required to use websites. First-time Edge setup, multi-profile selection, cookies, session expiry, passkeys, MFA, payment dialogs, and site accessibility cannot be guaranteed by a shortcut installer. Test the actual websites with the intended user before handing over the computer.

## Storage and safety

All changes are scoped to the current user:

| Location | Contents |
| --- | --- |
| `%LOCALAPPDATA%\EasyEdgeApps\Apps\<app-id>\` | Validated settings and the saved icon |
| Windows-resolved Desktop | Selected `.lnk` shortcuts |
| Windows-resolved Programs\Easy Edge Apps | Selected Start menu shortcuts |
| `%LOCALAPPDATA%\EasyEdgeApps\.pending\` | Temporary staging and rollback files while making a change |

Known folders are resolved through Windows rather than assuming a fixed Desktop path. Symbolic links and junctions in managed locations are rejected. Ordinary redirected folders are supported, but real OneDrive synchronization and unusual network filesystems require a check on the target computer. Shortcuts and locally stored icons are computer-specific; syncing a shortcut to another PC is not an installation there.

App IDs use SHA-256 of normalized names. Saved file paths are never used to choose where to write or delete. Shortcuts are checked against their ownership marker, expected executable, arguments, and icon location. Saved icons are hashed to detect outside changes. These checks protect against accidental replacement; someone who can change both your files and settings under the same Windows account is not a separate security boundary.

Updates stage all output first, copy recovery data, use same-directory atomic replacement for each file, and write settings last. Caught failures trigger rollback. A per-user, per-Windows-session mutex prevents simultaneous changes in the same session. Operations spanning several files are not a single filesystem transaction and cannot guarantee crash or power-loss atomicity.

There is no installer telemetry, website scraping, automatic script updating, scheduled task, service, or registry write. Opening a website makes the normal network requests performed by Edge and that website.

## Recovery

If setup reports that an earlier change needs recovery, stop making changes and ask the helper to inspect `%LOCALAPPDATA%\EasyEdgeApps\.pending`.

1. Preserve a copy of that folder first. Its files can contain private website addresses; do not upload them publicly.
2. Read `journal.json` as data. It describes intended file operations and numbered `.backup` files containing previous contents. Never execute it as a script or blindly trust paths from a modified journal.
3. A technically competent helper should check each path belongs to this user's affected Easy Edge Apps entry, then restore the previous owned files from the available backups. Newly created files have `Existed: false` and should only be removed after verifying ownership. Leave unrelated files alone.
4. Only after confirming the installed entry is consistent, move the remaining `.pending` folder aside and run setup again. Keep the recovery copy until the website works.

A `complete.txt` file containing `EasyEdgeApps:complete:1` means the operation completed or was successfully rolled back, but Windows temporarily prevented cleanup. Saved websites remain usable. The next change retries cleanup; do not disable antivirus to clear a file lock.

## Verification and development

The test scripts need no test framework or external packages. They write to uniquely named temporary folders, not your actual Desktop or Start menu. Core tests use real Windows shortcut COM objects; the GUI smoke test exercises native controls offscreen.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-EasyEdgeApps.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-EasyEdgeAppsGui.ps1
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeApps.ps1
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeAppsGui.ps1
```

Run all isolated suites and parser checks for the current host, or both installed hosts:

```powershell
.\tests\Invoke-Tests.ps1
.\tests\Invoke-Tests.ps1 -BothHosts -ScreenshotDirectory "$env:TEMP\EasyEdgeApps-captures"
```

The nine suites cover the existing core, JSON portability, Favorites discovery/import, App Kits and repair, RFC cryptographic known-answer tests, encrypted files and bidirectional host interoperability, public CLI binding/dispatch, and both native GUI surfaces. The CLI harness extracts the unchanged public parameter block and dispatcher using PowerShell's AST and redirects only known-folder dependencies into temporary storage. It never redirects your actual Windows folders. Interoperability tests require both `powershell.exe` and `pwsh.exe`.

Local verification uses Windows 11 Enterprise build **26200**, Windows PowerShell **5.1.26100.8875**, and PowerShell **7.6.5**, without elevation. The Windows workflow invokes the same runner in each host. Enlarged-font layout tests cap windows to 1024 by 768 and include rendered-icon pixel checks. They do not replace physical high-DPI, high-contrast, Narrator, multi-monitor, or real-site testing with the intended user.

Before handing over this version, exercise a protected-kit transfer between two real Windows accounts/computers, the intended Edge profile's Favorites selection, recovery/file-lock behavior, and any OneDrive or network-backed destination. Review the custom crypto composition independently before using encrypted exports for sensitive production data. Private `.eeakit.json` files are ignored by Git; never force-add real kits, passwords, or browser fixtures.

A separate disposable-profile launch probe with Edge **152.0.4191.66** did not expose a visible app window in the automation session. That probe was inconclusive, not an end-to-end browser pass. Opening the actual websites from the created shortcuts on the intended computer is a required helper acceptance check before handover.

Release assets include a SHA-256 checksum file. To check a downloaded script, run `Get-FileHash .\EasyEdgeApps.ps1 -Algorithm SHA256` and compare it with the checksum from the same release. A checksum detects a mismatched or corrupted download; it is not a code-signing certificate.

## Inspiration and license

Inspired by the idea behind [Sam-Knight/EdgeWebApp](https://github.com/Sam-Knight/EdgeWebApp). This is an original implementation, not a fork or copy of that repository's scripts. No source license was present in the reference repository when it was inspected.

Easy Edge Apps is available under the [MIT license](LICENSE). Microsoft and Edge are trademarks of Microsoft. This project is not affiliated with or endorsed by Microsoft.