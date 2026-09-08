# MSI Installation and Builds

## Installation

Download the x64 MSI from the [official release](https://github.com/blakedrumm/EasyEdgeApps/releases/latest), verify its SHA-256 checksum, and open it while signed in as the intended Windows user. The minimal Windows Installer wizard installs the manager for that account without requesting elevation. Windows 11 x64 is the supported target; ARM64 has not been acceptance-tested.

Open **Easy Edge Apps** from Start afterward. Installation does not run the application or make update requests automatically. The MSI, launcher, and script are unsigned. Follow organizational policy and do not disable SmartScreen, antivirus, or other security controls to run them.

Program files are placed in `%LOCALAPPDATA%\Programs\Easy Edge Apps`:

- `EasyEdgeApps.exe`, a small Windows .NET Framework launcher.
- `EasyEdgeApps.ps1`, the same self-contained portable application.
- `LICENSE` and combined `THIRD-PARTY-NOTICES.md`, including WiX's license and source attribution.

The manager is registered with Windows Installer and Installed Apps. Its Start menu shortcut is separate from the website shortcuts under the **Easy Edge Apps** folder. The launcher starts the adjacent script using the absolute Windows PowerShell path, STA mode, no profile scripts, no console, and a process-only execution-policy override. It accepts no forwarded arguments. Windows PowerShell 5.1 and .NET Framework are provided with Windows 11; end users do not install WiX or a .NET SDK.

Fresh sessions, added in 1.3.2, are an optional per-website setting. Saving/importing/repairing one generates an unsigned `fresh-session.exe` beneath that website's application-data folder using the Windows .NET Framework compiler. This is not an additional MSI payload. It runs without PowerShell and manages only its temporary profile and browser job. Fresh browsing requires a non-elevated session and compatible Edge policies; do not bypass application controls to run it. See [fresh-session behavior and limits](../README.md#fresh-sessions-per-website).

## Maintenance

Close setup before installing a newer MSI. Major upgrades replace the previous product registration in the same account and retain its install location. Downgrades are rejected. Portable users can install the MSI without migrating their data, since both distributions use `%LOCALAPPDATA%\EasyEdgeApps` for saved websites and preferences.

Reopen the installed MSI for maintenance, or use Windows Installer repair. To uninstall, use **Settings > Apps > Installed apps > Easy Edge Apps**. Only the manager's installed files and shortcut are removed. Saved website shortcuts, settings, preferences, debug logs, recovery files, and browser data remain. Remove unwanted websites through the manager before uninstalling, or reinstall the manager later. The installer does not recursively delete unrelated files placed in its program folder.

MSI upgrades and repair do not rebuild per-website fresh-session executables or sweep residual session data. Use the current manager's **Check and Repair** for missing/outdated owned launchers, after closing that website's fresh windows. Resolve cleanup warnings before disabling/removing a fresh website. Schema-2 websites and kits need application 1.3.2 or later; ordinary existing settings remain compatible.

For explicitly approved automation, run as the intended user, not SYSTEM or another helper account:

```powershell
msiexec.exe /i "C:\Downloads\EasyEdgeApps-1.3.2-x64.msi" /qn /norestart
msiexec.exe /famus "C:\Downloads\EasyEdgeApps-1.3.2-x64.msi" /qn /norestart
msiexec.exe /x "C:\Downloads\EasyEdgeApps-1.3.2-x64.msi" /qn /norestart
```

A deployment runner must wait for `msiexec.exe` to finish and inspect its exit code. Windows Installer exit codes differ from application CLI exit codes; `0` means success, `3010` means success with a restart required, and other codes need investigation. `/norestart` prevents an automatic restart. On managed machines, policy can block otherwise per-user installation.

Update checks are notification-only. **Download update** opens the official release page; it never downloads or executes an installer itself. The checker has no elevated component, service, scheduled task, or background process when setup is closed.

## Build

Build on 64-bit Windows with the .NET 10 SDK and Windows .NET Framework C# compiler available. Run PowerShell in STA mode:

```powershell
pwsh.exe -NoLogo -NoProfile -STA -File .\tools\Build-Installer.ps1
```

Windows PowerShell 5.1 can run the same build. The script restores the repository-local tool manifest's **WiX 5.0.2** and **WixToolset.UI.wixext 5.0.2**. The UI extension is loaded from its exact versioned cache path. WiX and the SDK are build dependencies only. The build reuses the embedded application icon, generates a license dialog, compiles the launcher, combines all notices, and builds an x64 per-user MSI with warnings treated as errors and standard Windows Installer validation enabled.

Output defaults to `artifacts\EasyEdgeApps-1.3.2-x64.msi`; `-OutputDirectory` changes that folder. After restoring dependencies, `-SkipRestore` uses the pinned local cache without package downloads. `artifacts` and the local `.wix` cache are ignored by Git. No global WiX installation or administrator prompt is required.

Version comes from `Get-EeaVersion` in the application and is shared by MSI metadata and the launcher. Upgrade and component GUIDs in the authoring are stable. Windows Installer generates new product/package identities for builds; this is a repeatable build procedure, not a promise of byte-identical MSI output. Publish a new application version for changed binaries and never replace an already published MSI under the same version.

WiX's unmodified UI resources and custom actions are MS-RL licensed. [WiX notices](../installer/WiX-Notices.txt) identify the exact upstream source revision. Releases also provide `WiX-5.0.2-source.zip` and its checksum. The Easy Edge Apps application and launcher remain MIT-licensed; the embedded image-rendering libraries retain their own licenses.

## Verification

Structural checks do not install anything:

```powershell
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeAppsInstaller.ps1 -MsiPath .\artifacts\EasyEdgeApps-1.3.2-x64.msi
```

Use a disposable Windows account or CI runner for the actual lifecycle test:

```powershell
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeAppsInstaller.ps1 -MsiPath .\artifacts\EasyEdgeApps-1.3.2-x64.msi -InstallLifecycle
```

The test refuses to touch an existing MSI installation or manager shortcut. It puts program files in a unique temporary directory, temporarily creates the real current-user installer registration and manager Start menu shortcut, and cleans them up. It does not redirect Windows known folders, use `Win32_Product`, touch actual saved website data, or request elevation.

Checks cover metadata and per-user scope, a limited payload, complete notices, actual install, upgrade from a synthetic older-version fixture, downgrade rejection, repair of a missing script with shortcut recreation, and uninstall that preserves an unrelated file. A copy of the compiled launcher runs a harmless adjacent test script to verify STA Windows PowerShell 5.1, no console, and no forwarded command-line input. Failed test logs are retained for diagnosis; if Windows prevents cleanup, the test reports the product code for manual removal.

CI builds the MSI and runs its lifecycle from both PowerShell hosts, separately from the fourteen application suites. Automated checks do not replace physical installer-wizard, accessibility, browser sign-in, or cross-computer handover acceptance tests. MSI installation, upgrades, repair, and removal do not manage website taskbar pins; pin and unpin those manually in Windows.