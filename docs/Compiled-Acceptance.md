# Compiled Acceptance and Release Gates

The compiled distribution is an unsigned preview. [Parity](Compiled-Preview.md#parity-and-evidence), [architecture and recovery](Compiled-Architecture.md), and [CLI commands](Compiled-Automation.md) describe what it implements. Passing the local gates below is not permission to publish, install over a real product, migrate live data, or declare production readiness.

The [current validation report](Compiled-Validation.md) records the exact local artifacts, test results, captures, measurements, failed evidence and remaining work. The commands below reproduce the gates in a new output directory.

## Reproducible Local Gates

Run from the repository root. Use a fresh package directory so earlier failing artifacts remain available:

```powershell
pwsh.exe -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass `
  -File .\tools\Build-Compiled.ps1 -OutputDirectory .\artifacts\compiled-preview-local
if ($LASTEXITCODE -ne 0) { throw 'Compiled build failed.' }

$env:EEA_COMPILED_BUILD_RESULT = (Resolve-Path .\artifacts\compiled-preview-local\build-result.json).Path
$build = Get-Content -LiteralPath $env:EEA_COMPILED_BUILD_RESULT -Raw | ConvertFrom-Json
$env:EEA_COMPILED_MSI = $build.Msi

dotnet test .\tests\EasyEdgeApps.Core.Tests\EasyEdgeApps.Core.Tests.csproj `
  -c Release --no-restore --logger 'trx;LogFileName=core.trx' `
  --results-directory .\artifacts\compiled-acceptance
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }

dotnet test .\tests\EasyEdgeApps.Windows.Tests\EasyEdgeApps.Windows.Tests.csproj `
  -c Release --no-restore --logger 'trx;LogFileName=windows.trx' `
  --results-directory .\artifacts\compiled-acceptance
if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed.' }

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Test-CompiledManager.ps1 `
  -ManagerPath (Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe') `
  -ScreenshotDirectory (Join-Path $PWD 'artifacts\compiled-acceptance-ui')
if ($LASTEXITCODE -ne 0) { throw 'Published native UI failed.' }

powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Test-CompiledManager.ps1 `
  -ManagerPath (Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe') `
  -TextSize 24 -Theme Light `
  -ScreenshotDirectory (Join-Path $PWD 'artifacts\compiled-acceptance-ui-large')
if ($LASTEXITCODE -ne 0) { throw 'Large-text published native UI failed.' }

pwsh.exe -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Invoke-Tests.ps1 -BothHosts `
  -ResultDirectory (Join-Path $PWD 'artifacts\legacy-acceptance')
if ($LASTEXITCODE -ne 0) { throw 'Retained PowerShell tests failed.' }
```

Set the explicit current build-result path rather than relying on the default artifacts directory. The standalone MSI check shares the package test's build-record reader; a conflicting `EEA_COMPILED_MSI` override is rejected. These tests verify published XBF/PRI resources, the complete indexed folder, every ZIP file size/hash, supplied license inventory, read-only MSI metadata, and rejection by the real unsigned-publisher gate. They do not execute MSI or prove a signed positive path. Selecting a build record alone does not establish that its bytes match later source edits.

Native UI tests start only the exact compiled manager with a unique repository-local fixture. They use UIA patterns and, for optional system pickers, verified owned native controls; no global keystrokes are sent. They close only their owned process. Captures use PrintWindow, with a foreground-guarded fallback; inspect retained images as well as assertions. Observations include startup/save/rename times and working set. A nonblank capture alone does not prove layout, font size, or browser acceptance.

[compiled.yml](../.github/workflows/compiled.yml) contains pinned-action Windows build, test, default/large-text published UI, focused Favorites/Settings/window/appearance checks, and evidence retention steps. Validate the complete YAML with a structured parser and each PowerShell run block after editing it. The original [test.yml](../.github/workflows/test.yml) remains present. Local syntax validation is not a remote workflow run.

The focused published workflows use mutually exclusive harness switches:

```powershell
$manager = Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe'
$workflows = @(
  @{ Name = 'favorites'; Arguments = @('-FavoritesOnly', '-TextSize', '24', '-Theme', 'Light') }
  @{ Name = 'settings'; Arguments = @('-SettingsOnly', '-LegacySettingsPoints', '14') }
  @{ Name = 'windows'; Arguments = @('-WindowChoicesOnly', '-TextSize', '24', '-Theme', 'Light') }
  @{ Name = 'appearance'; Arguments = @('-AppearanceOnly', '-Theme', 'System') }
)
foreach ($workflow in $workflows) {
  $arguments = @('-NoLogo', '-NoProfile', '-MTA', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', '.\tests\Test-CompiledManager.ps1', '-ManagerPath', $manager, '-ScreenshotDirectory', (Join-Path $PWD ('artifacts\acceptance-' + $workflow.Name))) + $workflow.Arguments
  & powershell.exe @arguments
  if ($LASTEXITCODE -ne 0) { throw ('Published ' + $workflow.Name + ' failed.') }
}
```

Protected-kit system-picker acceptance is opt-in and is not in the CI workflow. Run it on an English Windows desktop without concurrent GUI tests or user input into the fixture window:

```powershell
powershell.exe -NoLogo -NoProfile -MTA -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Test-CompiledManager.ps1 `
  -ManagerPath (Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe') `
  -KitFilesOnly -TextSize 24 -Theme Light `
  -ScreenshotDirectory (Join-Path $PWD 'artifacts\acceptance-protected-kits')
if ($LASTEXITCODE -ne 0) { throw 'Protected-kit picker acceptance failed.' }
```

`-KitFilesOnly` creates one synthetic website and exercises actual Save/Open pickers, save cancellation/draft retention, encrypted output, wrong-password retry, correct unlock, preview and unchanged catalog/source bytes. It is mutually exclusive with the other focused modes. `-KitFiles` runs the same assertions within the complete GUI workflow and cannot combine with a focused mode. Both keep the existing bounded worker deadline. Native fallbacks require exact manager-owned dialog ancestry, a unique expected filename hierarchy, an editable native field and exact synthetic path read-back. Queued button clicks are followed by bounded closure and result checks. Different languages or picker providers can fail these selectors; that is not automatically an application defect or a passed accessibility gate. Only the fixed synthetic fixture passphrase is used.

The [current validation report](Compiled-Validation.md#current-executed-gates) records default/enlarged published round trips and a focused cancellation mutation that failed at the intended lost-draft assertion, then passed after restoration.

The optional `-SafetyOnly` workflow also uses an actual English system picker, for a deliberately invalid local icon. It saves two synthetic websites, verifies command-time selection locking and the exact Remove target, cancels without catalog changes, checks that icon failure blocks both Save routes with recovery guidance, and restores the saved icon without losing notes. Run it at default and enlarged text:

```powershell
powershell.exe -NoLogo -NoProfile -MTA -NonInteractive -ExecutionPolicy Bypass `
  -File .\tests\Test-CompiledManager.ps1 `
  -ManagerPath (Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe') `
  -SafetyOnly -TextSize 24 -Theme Light `
  -ScreenshotDirectory (Join-Path $PWD 'artifacts\acceptance-safety')
if ($LASTEXITCODE -ne 0) { throw 'Published safety workflow failed.' }
```

This mode is mutually exclusive with every other focused workflow and `-KitFiles`. It remains opt-in with the same picker-provider limitations; no real website, browser data, or pin request is used. The new synthetic helper cancellation tests in the Windows suite also do not request a pin.

Windows test classes run serially because native fixtures share the user-scoped predecessor writer mutex and desktop even when their data folders differ. The two-direction encrypted-kit interoperability worker has a measured three-minute bound; ordinary compatibility commands retain 90 seconds. Safe stage output is retained on timeout. No production KDF, mutex or decoder deadline was relaxed.

## Required Defect Regression

[Test-EasyEdgeAppsKitWindowTransitions.ps1](../tests/Test-EasyEdgeAppsKitWindowTransitions.ps1) reproduces the controlling import defect with Alpha ordered before incompatible Bravo. Bravo has destination-local FullScreen or AlwaysOnTop and schema-2 Fresh false/omitted. Preview formerly reported Update,Update; apply updated Alpha before failing Bravo. Shared effective-setting validation now gives Update,Conflict and Not attempted,Conflict, leaving all selected managed hashes unchanged. Schema-1 preservation and Repair are included.

Both Windows PowerShell 5.1 and PowerShell 7 have observed failing and passing evidence for that regression. This fixes predictable preflight failure, not unexpected partial runtime failure or power-loss atomicity. [Migration-Progress.md](Migration-Progress.md) retains the broader sequence of red/green and mutation evidence.

## External Acceptance Matrix

These actions are not authorized on the live development account. Prepare an explicitly authorized disposable Windows 11 x64 environment, synthetic website data, approved Edge version, and recorded original/current package hashes first. Preserve failing logs before cleanup. Never use real credentials merely to make a test pass.

| Gate | Exact target/check in the disposable environment | Passing evidence required |
| --- | --- | --- |
| Clean machine | Extract the whole portable folder on Windows without a separately installed .NET/AppSDK runtime; start manager, CLI, image worker, and owned launcher health. | No missing runtime/resource prompts; complete payload; native workflow/captures. |
| Topmost | Set `EEA_TEST_TOPMOST=1` and run `dotnet test tests/EasyEdgeApps.Windows.Tests/EasyEdgeApps.Windows.Tests.csproj -c Release --filter FullyQualifiedName~ControllerMarksOnlyItsOwnedSyntheticWindowTopmost`. | Actual owned topmost flag, unrelated window unchanged. Default skip is not acceptance. |
| Real Edge Fresh | Exercise the compiled launcher with two independent synthetic Fresh sessions, child popups, supervisor interruption, locks, and owned cleanup. Compare [Test-EasyEdgeAppsFreshSessionBrowser.ps1](../tests/Test-EasyEdgeAppsFreshSessionBrowser.ps1) contracts. | Distinct profiles, exact job ownership, no normal-profile writes, retained downloads, bounded cleanup. The legacy script alone does not test the compiled entry point. |
| Persistent/window | Exercise compiled Dedicated reuse, RememberLast, monitor fitting, Maximized, FullScreen, Escape and shutdown; compare [Test-EasyEdgeAppsWindowBrowser.ps1](../tests/Test-EasyEdgeAppsWindowBrowser.ps1). | Recorded HWND/process ownership and geometry; unrelated Edge untouched; diagnose the historic post-Escape timeout rather than assuming it fixed. |
| Taskbar | Explicitly approve a Windows pin on the owned launcher; verify AUMID grouping, focus, rename continuity, Fresh grouping and unpin; compare [Test-EasyEdgeAppsTaskbarBrowser.ps1](../tests/Test-EasyEdgeAppsTaskbarBrowser.ps1). | Actual shell result and retained identities, not only supported API presence or selected shortcut. |
| Cross-session writers | Run predecessor/successor under two Windows sessions with the same data owner; contend during preview, handoff, crash recovery and rollback. | Old writers cannot recreate/rewrite retired ownership; no lost data. Keep live gate disabled until exclusion is implemented and proven. |
| Installer lifecycle | Record prior-release registration with Windows Installer APIs; install/upgrade/repair/uninstall the preview and test failed-upgrade rollback. Compare existing installer workflow/tests. | Correct per-user component identity and shortcuts; owned app/browser data retained; prior product rollback works. Do not use Win32_Product. |
| Authenticated updates | Use an authorized expected publisher, signed files/index/MSI, valid timestamp, and tampered/wrong-publisher/expired/untrusted variants. | Exact positive/negative trust results, cancellation cleanup and unchanged running version on failure. No test pin or unsigned checksum bypass. |
| Accessibility | Narrator/NVDA; keyboard-only editor and every tool dialog; Windows high contrast/reduced motion; 100/150/200 percent mixed DPI and small displays. | Spoken names/status, sensible focus, all controls reachable without overlap, visible primary actions and tooltips. UIA property assertions alone are insufficient. |
| Encryption/legal | Independent review of the envelope, KDF/MAC/validation/error/secret handling and exact dependency notices. | Written cryptographic and license review; interoperability and notice retention are not substitutes. |

There is not yet a ready-made end-to-end compiled real-Edge, cross-session migration, or installed-product acceptance harness. The referenced legacy scripts supply existing contracts, not substitute compiled-host evidence. Portable activation/rollback/recovery, persisted Later pointers, original appearance/settings mapping, GUI Favorites/profile/placement/new-only imports, native Check Apps inspection, CLI icon/taskbar choices, encryption retries, synthetic protected-kit Save/Open round trips and startup working-area fit are implemented with isolated coverage. Positive signed deployment/resume, actual browser health, other picker locales/provider versions, all-dialog keyboard/speech acceptance and physical display behavior remain unverified. Native inspection lists successor retained folders; legacy inventory and corrupt-catalog recovery remain separate surfaces.

## Evidence Interpretation

- **SOURCE:** inspected implementation or exact artifact text.
- **UNIT/MOCK:** isolated contracts or fake network/publisher dependencies; no live trust inference.
- **AUTOMATED:** an executed command with retained output and exit code.
- **WINDOWS:** actual local native UI, process, COM shortcut, decoder or synthetic window behavior.
- **EDGE:** actual Edge behavior from this compiled build/configuration; none established in this development run.
- **PACKAGE:** created/read-only validated local packages; no installer lifecycle inference.
- **UNVERIFIED:** not measured or not settled by the available evidence.
- **BLOCKED:** external prerequisite, such as authorized signing, audit or disposable environment.
- **PROHIBITED:** intentionally not performed here, including publication, credentials, live browser changes, real pins and MSI execution.

Do not add focused test counts to infer a full-suite count. Inspect each TRX outcome: retained files whose names end in `green` include some historical failed runs. New tests have targeted red/green or mutation evidence where recorded; exhaustive mutation testing of every test has not been performed. The undiagnosed File.Replace error 1175 and hosted topmost observation remain unresolved despite subsequent passing checks.