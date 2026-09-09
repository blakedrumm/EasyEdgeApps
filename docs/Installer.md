# MSI Installation and Builds

## Installation

Download the x64 MSI from the [official release](https://github.com/blakedrumm/EasyEdgeApps/releases/latest), verify its SHA-256 checksum, and open it while signed in as the intended Windows user. The minimal Windows Installer wizard installs the manager for that account without requesting elevation. Windows 11 x64 is the supported target; ARM64 has not been acceptance-tested.

Open **Easy Edge Apps** from Start afterward. Installation does not run the application or make update requests automatically. The MSI, launcher, and script are unsigned. Follow organizational policy and do not disable SmartScreen, antivirus, or other security controls to run them.

Program files are placed in `%LOCALAPPDATA%\Programs\Easy Edge Apps`:

- `EasyEdgeApps.exe`, a small Windows .NET Framework launcher.
- `EasyEdgeApps.ps1`, the same self-contained portable application.
- `LICENSE` and combined `THIRD-PARTY-NOTICES.md`, including WiX's license and source attribution.

The manager is registered with Windows Installer and Installed Apps. Its Start menu shortcut is separate from the website shortcuts under the **Easy Edge Apps** folder. The launcher starts the adjacent script using the absolute Windows PowerShell path, STA mode, no profile scripts, no console, and a process-only execution-policy override. It accepts no forwarded arguments. Windows PowerShell 5.1 and .NET Framework are provided with Windows 11; end users do not install WiX or a .NET SDK.

New websites default to a separate persistent app profile. Saving/importing/repairing an app with a separate or Fresh profile generates an unsigned `fresh-session.exe` beneath its application-data folder using the Windows .NET Framework compiler. The shared filename is retained for compatibility and is not another MSI payload. It runs without PowerShell and manages only its own browser job, profile, website identity, and selected window controls. Fresh uses Guest mode. Existing shared apps are not converted by MSI upgrade or Repair. Browsing requires a non-elevated session and compatible policies; do not bypass application controls. See [window preferences](../README.md#window-size-and-always-on-top), [Fresh limits](../README.md#fresh-sessions-per-website), and [taskbar support](../README.md#pin-a-website-to-the-taskbar).

## Maintenance

Close setup before installing a newer MSI. Major upgrades replace the previous product registration in the same account and retain its install location. Downgrades are rejected. Portable users can install the MSI without migrating their data, since both distributions use `%LOCALAPPDATA%\EasyEdgeApps` for saved websites and preferences.

Reopen the installed MSI for maintenance, or use Windows Installer repair. To uninstall, use **Settings > Apps > Installed apps > Easy Edge Apps**. Only the manager's installed files and shortcut are removed. Saved website shortcuts, settings, preferences, debug logs, recovery files, and browser data remain. Remove unwanted websites through the manager before uninstalling, or reinstall the manager later. The installer does not recursively delete unrelated files placed in its program folder.

MSI upgrades and repair do not rebuild per-website executables or sweep persistent profiles, placement records, or residual sessions. Use the current manager's **Check and Repair** after closing website windows. Resolve cleanup warnings before disabling/removing Fresh. New apps and changed launch preferences use local schema 4 and require 1.4.0; legacy schemas 1/2/3 remain readable and repairable without silently changing profile routes. Portable kit schemas remain 1/2.

After installing 1.4.0, open **Check apps...**, select repairable websites, and approve **Repair Selected** to update owned launchers. Select a saved app and explicitly choose Separate app profile and a window mode to adopt new controls; legacy defaults remain maximized. Re-pin old taskbar entries that target Edge directly. The update does not copy or erase normal Edge data. Full screen and Always on top cannot be combined.

For explicitly approved automation, run as the intended user, not SYSTEM or another helper account:

```powershell
msiexec.exe /i "C:\Downloads\EasyEdgeApps-1.4.0-x64.msi" /qn /norestart
msiexec.exe /famus "C:\Downloads\EasyEdgeApps-1.4.0-x64.msi" /qn /norestart
msiexec.exe /x "C:\Downloads\EasyEdgeApps-1.4.0-x64.msi" /qn /norestart
```

A deployment runner must wait for `msiexec.exe` to finish and inspect its exit code. Windows Installer exit codes differ from application CLI exit codes; `0` means success, `3010` means success with a restart required, and other codes need investigation. `/norestart` prevents an automatic restart. On managed machines, policy can block otherwise per-user installation.

Update checks are notification-only. **Download update** opens the official release page; it never downloads or executes an installer itself. The checker has no elevated component, service, scheduled task, or background process when setup is closed.

## Build

Build on 64-bit Windows with the .NET 10 SDK and Windows .NET Framework C# compiler available. Run PowerShell in STA mode:

```powershell
pwsh.exe -NoLogo -NoProfile -STA -File .\tools\Build-Installer.ps1
```

Windows PowerShell 5.1 can run the same build. The script restores the repository-local tool manifest's **WiX 5.0.2** and **WixToolset.UI.wixext 5.0.2**. The UI extension is loaded from its exact versioned cache path. WiX and the SDK are build dependencies only. The build reuses the embedded application icon, generates a license dialog, compiles the launcher, combines all notices, and builds an x64 per-user MSI with warnings treated as errors and standard Windows Installer validation enabled.

Output defaults to `artifacts\EasyEdgeApps-1.4.0-x64.msi`; `-OutputDirectory` changes that folder. After restoring dependencies, `-SkipRestore` uses the pinned local cache without package downloads. `artifacts` and the local `.wix` cache are ignored by Git. No global WiX installation or administrator prompt is required. Unique build staging folders and historical packages are retained; do not delete artifacts needed for rollback or release verification.

Version comes from `Get-EeaVersion` in the application and is shared by MSI metadata and the launcher. Upgrade and component GUIDs in the authoring are stable. Windows Installer generates new product/package identities for builds; this is a repeatable build procedure, not a promise of byte-identical MSI output. Publish a new application version for changed binaries and never replace an already published MSI under the same version.

WiX's unmodified UI resources and custom actions are MS-RL licensed. [WiX notices](../installer/WiX-Notices.txt) identify the exact upstream source revision. Releases also provide `WiX-5.0.2-source.zip` and its checksum. The Easy Edge Apps application and launcher remain MIT-licensed; the embedded image-rendering libraries retain their own licenses.

## Verification

Structural checks do not install anything:

```powershell
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeAppsInstaller.ps1 -MsiPath .\artifacts\EasyEdgeApps-1.4.0-x64.msi
```

Use a disposable Windows account or CI runner for the actual lifecycle test:

```powershell
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeAppsInstaller.ps1 -MsiPath .\artifacts\EasyEdgeApps-1.4.0-x64.msi -InstallLifecycle
```

The test refuses to touch an existing MSI installation or manager shortcut. It puts program files in a unique temporary directory, temporarily creates the real current-user installer registration and manager Start menu shortcut, and cleans them up. It does not redirect Windows known folders, use `Win32_Product`, touch actual saved website data, or request elevation.

Checks cover metadata and per-user scope, a limited payload, complete notices, actual install, upgrade from a synthetic older-version fixture, downgrade rejection, repair of a missing script with shortcut recreation, and uninstall that preserves an unrelated file. A copy of the compiled launcher runs a harmless adjacent test script to verify STA Windows PowerShell 5.1, no console, and no forwarded command-line input. Failed test logs are retained for diagnosis; if Windows prevents cleanup, the test reports the product code for manual removal.

For an authentic predecessor test, supply both the unmodified older MSI and its independently obtained published SHA-256 value:

```powershell
pwsh.exe -NoProfile -STA -File .\tests\Test-EasyEdgeAppsInstaller.ps1 -MsiPath .\artifacts\EasyEdgeApps-1.4.0-x64.msi -InstallLifecycle -PreviousMsiPath .\artifacts\EasyEdgeApps-1.3.3-x64.msi -PreviousMsiSha256 de78d13b76b1d05c1325c55599215e5e36592f8143258f0e42bc17fffe2af61a
```

This remains a disposable-account test. It verifies the predecessor's identity, version, per-user scope, checksum, and absence of existing product registration before installing. Upgrade deliberately omits `INSTALLFOLDER` and must discover the prior nondefault path. The default synthetic fixture is retained as a separate check. A mutation test removes the previous-folder lookup from a disposable MSI copy and requires the structural test to reject it before installation.

The workflow runs eighteen application suites in each PowerShell host and a separate MSI lifecycle job. It retains the exact successfully tested package as `tested-msi` for 14 days, using an immutable Node 24 artifact action. Release validation records identify the actual predecessor version and hash tested. Use that artifact rather than rebuilding untested bytes, and keep a hash-verified final MSI in the ignored `artifacts` directory without deleting historical packages.

## Support and publisher verification

[Get-SupportInfo.ps1](../tools/Get-SupportInfo.ps1) prints an allowlisted JSON report with product, OS, PowerShell, Edge, culture, process architecture, and manager-signature status. It reads no saved website content and writes or uploads nothing. Review its output before sharing.

[Test-PublisherSignature.ps1](../tools/Test-PublisherSignature.ps1) is a maintainer verification gate, not a signer. It requires a valid Authenticode result, an explicitly expected certificate thumbprint, and a timestamp certificate for every supplied file. Current unsigned artifacts intentionally fail. A trusted publisher identity, protected signing pipeline, and enterprise policy for locally generated per-website launchers are still required before claiming a signed deployment. No private key or password should be passed through chat.

Automated checks do not replace physical installer-wizard, accessibility, browser sign-in, or cross-computer handover acceptance tests. MSI installation, upgrades, repair, and removal do not manage website taskbar pins; use the setup Taskbar checkbox and Windows approval to pin, and Windows' taskbar menu to unpin.