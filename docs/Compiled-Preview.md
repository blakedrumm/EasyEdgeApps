# Compiled C# and WinUI Preview

This checkout contains a compiled successor to Easy Edge Apps 1.4.0. It uses C#, .NET 10 LTS, WinUI 3, and Windows App SDK 2.4.0. The original PowerShell application and its distribution remain present. [Version 2.0.0 Preview 1](https://github.com/blakedrumm/EasyEdgeApps/releases/tag/v2.0.0-preview.1) is an unsigned prerelease of the tested `p4` payload, not a production release. Compiled installation and real-browser acceptance remain unperformed; v1.4.0 remains stable.

**Status: unsigned engineering preview, not production-ready or complete parity.** Local checksums detect changed bytes; they do not authenticate a publisher. Live migration and rollback of legacy websites are disabled until cross-session writer exclusion and disposable-Windows acceptance are established. Use synthetic, repository-local isolated roots for development.

[Architecture and recovery](Compiled-Architecture.md) | [CLI reference](Compiled-Automation.md) | [Acceptance commands and release gates](Compiled-Acceptance.md) | [Current local validation](Compiled-Validation.md) | [Executed progress](Migration-Progress.md)

## Run the Current C# GUI

Download the [portable ZIP](https://github.com/blakedrumm/EasyEdgeApps/releases/download/v2.0.0-preview.1/EasyEdgeApps-2.0.0-preview.1-x64.zip) and [SHA256SUMS.txt](https://github.com/blakedrumm/EasyEdgeApps/releases/download/v2.0.0-preview.1/SHA256SUMS.txt), compare the archive hash, and extract the complete ZIP into a new directory. From the extracted folder:

```powershell
& .\EasyEdgeApps.Manager.exe --isolated-root (Join-Path $PWD 'preview-data')
```

This runs the compiled manager with synthetic state and blocks actual browser, network, pin and installer actions. Keep all extracted files together. The MSI is for separately authorized disposable-Windows acceptance only; do not install it over an everyday installation. The [release notes](releases/v2.0.0-preview.1.md) contain exact sizes, hashes and prerequisites. No separate .NET runtime installation is needed for the portable manager.

For this development checkout, the same tested delivery is also recorded in [p4/build-result.json](../artifacts/p4/build-result.json). Local `artifacts/` records are intentionally ignored by Git and are not included in source downloads; either use the release ZIP above or [build a new local preview](#build-and-run-an-isolated-preview). `p3`, `p2` and `compiled-delivery` remain historical. When the original `p4` folder is available:

```powershell
$build = Get-Content .\artifacts\p4\build-result.json -Raw | ConvertFrom-Json
& (Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe') `
  --isolated-root (Join-Path $PWD 'artifacts\p4-manager-data')
```

The [prepublication validation report](Compiled-Validation.md#current-delivery-p4) records exact unsigned hashes, 182 Core passes, 84 Windows passes plus one explicit skip, 38 retained-suite passes, eight published GUI workflows and remaining limits. Tagged GitHub Actions results are additional evidence, not implied by those local counts.

## Build and Run an Isolated Preview

Build on Windows 11 x64 with .NET SDK 10 installed. The SDK selection is controlled by [global.json](../global.json); dependencies are locked per project. The verified development SDK was 10.0.303, runtime 10.0.11. The build requires package restore access, the Windows SDK tools, and the existing Windows PowerShell/.NET Framework build tools for the retained legacy distribution. A compatible PowerShell 7 host can run the wrapper; `-STA` is required for the original branding and installer tooling.

Use a fresh output directory, since the wrapper refuses to overwrite a previous archive or MSI:

Keep the checkout and output paths short. The WiX native cabinet tool failed on a 261-character payload source during clean-build acceptance; the generator now rejects sources at 260 characters with a clear diagnostic. A shorter clean build passed.

Allow several GiB of free working space and recheck it before multi-site tests: self-contained launchers and transaction archives multiply storage use. The readiness run exhausted the disk after packaging; all affected cases passed after removing only regenerable build intermediates. Preserve delivery artifacts and recovery data rather than pruning them to bypass a failure.

```powershell
pwsh.exe -NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass `
  -File .\tools\Build-Compiled.ps1 `
  -OutputDirectory .\artifacts\compiled-preview-local
```

[Build-Compiled.ps1](../tools/Build-Compiled.ps1) restores the solution in locked mode, verifies the native-source transplant, generates original branding assets, builds both launcher targets, publishes the self-contained manager/CLI/image worker, retains the original distribution, gathers exact dependency notices, embeds a complete payload index, and creates a ZIP, per-user MSI, and checksums. `-SkipInstaller` omits the new MSI, not the legacy payload build. Build output and synthetic test data stay inside repository artifacts.

Read the build result rather than guessing the generated payload directory:

```powershell
$build = Get-Content .\artifacts\compiled-preview-local\build-result.json -Raw | ConvertFrom-Json
& (Join-Path $build.PortableDirectory 'EasyEdgeApps.Manager.exe') `
  --isolated-root (Join-Path $PWD 'artifacts\preview-manager-data')
& (Join-Path $build.PortableDirectory 'eea.exe') help
```

Keep the entire portable folder together. WinUI requires the published XBF, PRI, Windows App SDK, and runtime files; copying only the EXE does not work. The manager, CLI, site launcher, and image worker do not host PowerShell or compile source at runtime. The separately retained legacy entry point still uses PowerShell.

Isolated mode redirects the catalog, Desktop, Start menu, and legacy fixture locations. It disables actual browser launch, website lookup, update network access, and pin requests in the manager and CLI. Do not install the preview MSI on the development account: it shares the original product upgrade identity and needs a disposable-machine lifecycle test.

## Parity and Evidence

The statuses below distinguish source implementation from executed acceptance. The detailed history, including failed runs and mutations, is in [Migration-Progress.md](Migration-Progress.md). Tests use synthetic websites and files; a working shortcut or synthetic HWND is not proof of real Edge behavior.

| Surface | Current behavior and evidence | Remaining boundary |
| --- | --- | --- |
| Original PowerShell distribution | Retained, with shared effective-window validation added to import preview/install and matching native handle/job cleanup fixes. Both-host regression rejects predictable conflicts before any selected write; all 19 suites pass in both hosts. | Existing release acceptance limits still apply. |
| Permanent identity and rename | Random immutable IDs for new sites; exact legacy IDs on isolated migration. Rename preserves launcher, profile directory, shortcut filename, icon ownership, and AUMID. Historical names remain reserved. | Real pre-existing shell pins need disposable acceptance. |
| Save, remove, repair | Owned-file hashes, stale approval checks, reversible transactions and retained unrelated files. Native Check Apps verifies icon/configuration/shortcut metadata, current Edge and launcher, and reports unclaimed successor folders without adoption. Only repairable rows can be selected. | No Edge execution or account-health inference. Legacy inventory and corrupt-catalog recovery remain separate. External races and power loss are not fully tested. |
| Draft recovery | Save/Discard/Cancel, retained selection/raw address, asynchronous icon work and failed-save retry. Commands lock selection; Remove names the captured saved target; icon failure blocks both Save routes with explicit draft-preserving recovery. Published default/enlarged safety workflows pass. | Every dialog and assistive technology is not covered. |
| Profiles and window choices | New sites use Dedicated and RememberLast; Fresh, Taskbar, and topmost are off. Existing shared routes remain shared. FullScreen/topmost require an owned route and cannot be combined. | Real Edge Fresh/Persistent/fullscreen/Escape behavior is not current-run acceptance. |
| Process ownership | Compiled native controller runs the original child-tree, lease, interruption, long-path and placement fixtures. It owns a duplicate job handle until worker exit; launcher cleanup terminates only its successfully assigned job even when another handle remains. Focused red/green evidence is retained. | A historic post-Escape persistent shutdown timeout and real long-running 250 ms identity-polling cost remain unverified. |
| Window placement | Owned synthetic native windows restore and capture geometry; unrelated windows remain untouched; bounded disposal passes. | Topmost is explicitly skipped on this host. A direct successful topmost request also left the observable flag unset. Physical mixed-DPI is unverified. |
| Taskbar | Preserved per-site path/AUMID, GUI/CLI request-on-save and explicit `pin`; required Start/Dedicated choices, retained pins on clearing, bounded owned helper. Cancellation terminates and awaits that helper. Import and repair never request pins. | Synthetic cancellation does not contact the shell. No real pin, policy bypass or shell mutation was performed. |
| Addresses | HTTPS-first header-only scheme resolution; any HTTPS HTTP response retains HTTPS; TLS failures never downgrade. Explicit HTTP requires manager approval. | No live website was probed during acceptance. |
| Icons | Generated ICO; local ICO/PNG/JPEG/GIF/BMP/static SVG; bounded credential-free discovery; decoder-invalid candidates fall through; resolved URL/icon apply together without overwriting newer edits. Real worker pixel/cancellation and offline fallback tests pass. | Some ICO preview handling remains in process; no live website acceptance. |
| Image isolation | Child job has kill-on-close, one-process and 384 MiB limits, a 20-second deadline, and bounded I/O. Applied job settings, post-input cancellation and deadline expiry are executed checks. | Resource isolation is not an AppContainer or restricted-token security sandbox. Memory exhaustion itself was not forced. |
| App Kits | Strict schemas 1/2, before/after effective settings, selected unowned-path preflight, approval binding, missing-owned-file repair, explicit per-app partial results, portable custom icons and protected export paths. Actual protected-kit Save/Open round trips preserve matching catalog/source bytes. | Portable data excludes local profile/taskbar/geometry/global settings. Other picker locales/provider versions and exhaustive keyboard coverage remain unverified. |
| Protected kits | Both-host bidirectional compatibility and published crypto vector; no plaintext fallback. Actual blank/mismatched input and wrong-password retries, encrypted export, correct unlock/import and save-picker cancellation retention pass at 16/24 DIP. A lost-draft mutation failed, then passed after restoration. | Experimental pending independent audit; passwords are not publisher identity. Managed strings/UI internals do not guarantee secure erasure. |
| Favorites | Saved profile, refresh/file selection, visible disabled candidates, folder context, placements and cancelled-preview retention. Collision-safe names include tombstones, paths and legacy folders. New-only approvals reject concurrent name/URL matches. CLI name selection ignores unrelated unusable titles while keeping requested names strict. | Synthetic Bookmarks/Local State only; real profile data was not inspected. The approved in-memory GUI selection is a snapshot, not a live bookmark subscription. |
| Preferences and appearance | Original/System/Light/Dark, original deterministic starfield/motion, list/tiles, grouped Settings, exact legacy point-size mapping, read-only preference fallback, defaults and opt-in updates/logging. Startup centers/fits its working area. Actual default/24-DIP/legacy-size and System-motion workflows pass. | Physical DPI, high contrast/reduced motion and complete visual parity remain unaccepted. |
| Accessibility | Native WinUI controls, accessible names, live status, command bar, scrolling, actual font-size and primary-action checks, default/compact and Preferences captures. | Narrator/NVDA speech, all dialogs, high contrast, physical DPI, and reduced-motion acceptance remain open. |
| Logs and support | Opt-in UTC/category/outcome logs, bounded rotation, no private exception text. CLI writes still succeed with a locked log. Support is allowlisted and never uploaded. | Support aggregates use lower-level owned-hash checks, not full native inspection. Logging is best-effort, not an audit log. |
| Migration and rollback | Separate successor catalog, full owned-file archives, receipts, reserved aliases, legacy manifest retirement and ownership-checked rollback, including owned shortcuts enabled later. All four legacy schemas tested in isolation. | Disabled for live roots until old writers are excluded across sessions. Same-session mutex and a new lock file are not proof of that exclusion. |
| Recovery | Reader-compatible catalog/journal limits before writes, strict journals, per-restore ownership rechecks, Preparing recovery, no delete-then-copy replacement, streamed backups/apply/rollback. | A crash before the first journal exists fails closed for manual inspection; no batch power-loss or atomic compare-and-swap guarantee. |
| Updates | Opt-in cancellable checks, credential-free transport, explicit malformed-metadata validation, pinned publisher/timestamp checks, exact payload index, durable Later pointer and repeated MSI validation. Portable transitions have owned receipts and mock-publisher tests. Actual unsigned artifacts are rejected. | No trusted signed positive path, MSI execution, actual signed portable lifecycle or positive signed Later-resume UI acceptance. |
| Packaging and CI | Current self-contained `p4` folder/ZIP/MSI, complete index, exact notices, full tests and eight published GUI workflows pass. MSI checks share the selected build record. Pinned workflows and the earlier source-only clean build are retained. | CI was not pushed or run remotely; system-picker checks remain opt-in. Runtime-free clean-machine and installer lifecycle remain external. |

## Data and Rollback Boundaries

Normal successor state is under `%LOCALAPPDATA%\EasyEdgeApps.Next`; legacy state remains under `%LOCALAPPDATA%\EasyEdgeApps`. The successor does not mirror its catalog into a legacy schema and does not invite old managers to rewrite it. New schema/protocol 1 catalog records include immutable IDs, revisions, aliases, complete owned-artifact metadata, and tombstones. Unknown, missing, or malformed required fields fail closed.

Legacy migration is an explicit, reviewed ownership handoff, not opening an old folder and adopting it. It archives all owned bytes, including unchanged icons, records a receipt, retires the old manifest, and commits successor ownership. Rollback checks current owned hashes, restores archived originals, removes recorded owned slots added only afterward, and restores the old manifest late. Browser data and unrelated files are retained. Missing-manifest nonempty folders are conflicts, not adoptable data. The implementation currently exposes this only with an isolated fixture root.

Catalogs are limited to 16 MiB and 5,000 retained identities, including removed entries; journals to 1 MiB and 1,024 entries. Both also bound depth and value count. Writes validate reader-compatible limits before starting the transaction. Reaching a limit does not authorize deleting tombstones, archives or retained browser data.

Do not delete `.writer.lock`, pending journals, manifests, receipts, or browser data to bypass a conflict. Read-only recovery inspection remains available with a corrupt catalog. Unexpected per-app import errors may leave earlier completed apps installed; results identify those changes. Logs and hashes do not prove that private data has been securely erased.

## Performance and Footprint

Measured launcher sizes after the native cleanup fixes: Framework 4.8 target 48,128 bytes; self-contained .NET 10 target 141,518,994 bytes (134.96 MiB **per site**). The compiled package selects .NET 10 to avoid a separate runtime prerequisite. The Framework target remains available; its small size is not the selected portable deployment contract.

The earlier complete payload was 427,027,980 bytes, approximately 407 MiB unpacked. This is not a final-source size. Backups can retain additional full launcher copies, and no automatic backup pruning is implemented. Saving builds a template byte array and hashes large artifacts; streaming transaction copies removes additional full-file buffers but does not remove all memory or I/O cost.

The [current p4 delivery](Compiled-Validation.md) is 427,222,548 bytes unpacked. Its two actual published full UI runs peaked at 626-631 MiB, with saves taking 2.87 and 3.71 seconds. Those costs remain limitations, not performance-parity or benchmark claims. Historical `p3` was 427,216,088 bytes and peaked at 623-632 MiB; earlier measurements remain in the validation history.

One observed 24-DIP native UI run recorded startup 763 ms, save 3,615 ms, rename 2,958 ms, working set 212,520,960 bytes, and peak 482,922,496 bytes. An earlier run peaked at 624,947,200 bytes. These are individual workflow observations, not benchmarks, clean-machine numbers, or a controlled attribution of the difference to streaming. Final published measurements should be read from the retained UI observations.

## Acceptance and Trust

Required external acceptance includes real Edge process/profile continuity, fullscreen/Escape/shutdown, topmost, actual taskbar grouping/pinning, cross-session predecessor writers, install/upgrade/repair/uninstall, older MSI rollback, runtime-free clean Windows, physical DPI, high contrast, and screen-reader output. Use disposable Windows environments and synthetic data for those actions, not the developer's live profiles or installed products.

Signing needs an authorized publisher thumbprint, signed runtime files and installer, and a valid timestamp. The default publisher pin is empty and disables production update handoff. No credentials were inspected and no artifact was signed. Exact dependency notices are retained by [Export-CompiledNotices.ps1](../tools/Export-CompiledNotices.ps1); [Compiled-Third-Party-Notices.md](Compiled-Third-Party-Notices.md) explains their scope. Retaining supplied notices is not legal signoff.

Evidence labels: **SOURCE** means implementation inspected; **UNIT/MOCK** means deterministic or fake dependency checks; **AUTOMATED** means a command was executed; **WINDOWS** means local native integration; **EDGE** requires an actual Edge run; **PACKAGE** means built/read-only package evidence; **UNVERIFIED** means not established; **BLOCKED** names an external prerequisite; **PROHIBITED** names an action intentionally not performed here.