# Easy Edge Apps

One PowerShell script that turns trusted websites into easy-to-find Microsoft Edge app-window shortcuts on Windows 11.

A helper sets it up once in the person's Windows account. Everyday use is opening a familiar Desktop or Start menu shortcut, with no PowerShell window, administrator prompt, or extra launcher running in the background.

[Download the script](https://github.com/blakedrumm/EasyEdgeApps/releases/latest/download/EasyEdgeApps.ps1) | [Latest release](https://github.com/blakedrumm/EasyEdgeApps/releases/latest) | [Automated checks](https://github.com/blakedrumm/EasyEdgeApps/actions/workflows/test.yml)

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

Local verification was performed without elevation on Windows 11 Enterprise build **26200**, using Windows PowerShell **5.1.26100.8875** and PowerShell **7.6.5**. The automated Windows workflow runs both suites in both hosts. Enlarged-font layout tests and rendered-icon pixel checks are included; they do not replace physical high-DPI, high-contrast, Narrator, multi-monitor, or real-site testing with the intended user.

A separate disposable-profile launch probe with Edge **152.0.4191.66** did not expose a visible app window in the automation session. That probe was inconclusive, not an end-to-end browser pass. Opening the actual websites from the created shortcuts on the intended computer is a required helper acceptance check before handover.

Release assets include a SHA-256 checksum file. To check a downloaded script, run `Get-FileHash .\EasyEdgeApps.ps1 -Algorithm SHA256` and compare it with the checksum from the same release. A checksum detects a mismatched or corrupted download; it is not a code-signing certificate.

## Inspiration and license

Inspired by the idea behind [Sam-Knight/EdgeWebApp](https://github.com/Sam-Knight/EdgeWebApp). This is an original implementation, not a fork or copy of that repository's scripts. No source license was present in the reference repository when it was inspected.

Easy Edge Apps is available under the [MIT license](LICENSE). Microsoft and Edge are trademarks of Microsoft. This project is not affiliated with or endorsed by Microsoft.