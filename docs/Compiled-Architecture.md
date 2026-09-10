# Compiled Architecture and Durable State

See [Compiled-Preview.md](Compiled-Preview.md) for the current parity matrix and [Compiled-Automation.md](Compiled-Automation.md) for executable commands. This document describes the implementation, not a claim of production acceptance.

## Projects and Ownership

| Project | Responsibility |
| --- | --- |
| [Core](../src/EasyEdgeApps.Core/EasyEdgeApps.Core.csproj) | Validated website definitions, immutable editor state, kits, strict JSON, portable encryption, Favorites, credential-free address/icon/update transport. |
| [Persistence](../src/EasyEdgeApps.Persistence/EasyEdgeApps.Persistence.csproj) | Root/path confinement, catalog and aliases, writer leases, stale approvals, owned-file transactions, migration/rollback, preferences, logs, authenticated-package staging. |
| [Windows](../src/EasyEdgeApps.Windows/EasyEdgeApps.Windows.csproj) | Native controller, shortcuts/AUMID, Edge discovery, icon conversion/worker client, publisher trust, MSI inspection, support report, taskbar assistance. |
| [SiteLauncher](../src/EasyEdgeApps.SiteLauncher/EasyEdgeApps.SiteLauncher.csproj) | Adjacent XML configuration validation and standalone native Edge process/window control. Framework 4.8 and self-contained .NET 10 targets. |
| [Manager](../src/EasyEdgeApps.Manager/EasyEdgeApps.Manager.csproj) | WinUI 3/XAML editor and owned dialogs, preferences, asynchronous work, approval and recovery flows. |
| [Cli](../src/EasyEdgeApps.Cli/EasyEdgeApps.Cli.csproj) | Compiled JSON automation, explicit write approval, local-terminal-only protected-kit secrets, isolated test routing. |
| [ImageWorker](../src/EasyEdgeApps.ImageWorker/EasyEdgeApps.ImageWorker.csproj) | One bounded image conversion per process, stdin/stdout protocol, no user interface or website network access. |
| [PackageIndex](../src/EasyEdgeApps.PackageIndex/EasyEdgeApps.PackageIndex.csproj) | Embedded version/architecture/path/size/hash index read with PEReader, not by loading executable code. |

[EasyEdgeApps.slnx](../EasyEdgeApps.slnx) also includes the Core and Windows test projects and a test-only native fixture. The fixture is not a shipped browser, decoder, or production dependency.

The original [EasyEdgeApps.ps1](../EasyEdgeApps.ps1) and [installer launcher](../installer/Launcher.cs) remain supported source surfaces. [Export-NativeSource.ps1](../tools/Export-NativeSource.ps1) mechanically extracts the existing native controller into [Native.generated.cs](../src/EasyEdgeApps.SiteLauncher/Native.generated.cs). `-Verify` detects drift. Changes to shared native behavior belong in the original source followed by regeneration, not independent divergent copies. Extraction and branding generation occur at build time; no compiled entry point compiles C# or hosts PowerShell at runtime.

## Identity and Local Data

Normal roots:

- Successor catalog, preferences, transactions, new website files: `%LOCALAPPDATA%\EasyEdgeApps.Next`.
- Existing legacy application data: `%LOCALAPPDATA%\EasyEdgeApps`.
- Desktop and Start locations are resolved for the current non-elevated Windows user.
- `--isolated-root` supplies separate Data, Desktop, Programs, and Legacy children for synthetic tests.

[AppDefinition.cs](../src/EasyEdgeApps.Core/AppDefinition.cs) creates random 256-bit lowercase-hex IDs for new sites. Migration retains the exact old ID. [CatalogStore.cs](../src/EasyEdgeApps.Persistence/CatalogStore.cs) keeps identities independent of display names and reserves historical names after rename. A tombstone does not authorize adoption or deletion of retained data.

Rename retains the website directory, per-site `fresh-session.exe`, owned icon/configuration, existing shortcut filenames, browser profiles, and `EasyEdgeApps.Website.<id>` AUMID. Display names and shortcut display metadata can change without inventing a new app identity. Removal deletes only proven owned managed artifacts; profiles, downloads, unknown files, and Windows taskbar pins are not swept.

Definitions validate names, full HTTP/HTTPS addresses without credentials, profile identifiers, notes, shortcut placement, and owned-window combinations. New sites default to Dedicated plus RememberLast. Taskbar requires Start and Dedicated. Fresh is independent of the saved Dedicated choice. FullScreen and AlwaysOnTop require an owned route and cannot be selected together. Normal Edge profiles are never copied or cleared.

## Transactions and Recovery

[SafeFiles.cs](../src/EasyEdgeApps.Persistence/SafeFiles.cs) rejects traversal, absolute relative-address fields, alternate data streams, unsafe root escapes, and reparse components. This is managed path validation, not a proof against every concurrent filesystem substitution.

The catalog records schema/protocol, immutable definitions, revisions, aliases, complete owned-slot addresses/hashes, migration metadata, and removed state. Required fields are validated before deserialization can supply misleading defaults. Malformed state is not overwritten merely because it cannot be read.

Catalog commits validate the same 16 MiB, 5,000 retained identity, depth and value limits as the reader before any owned-file transaction begins. Removed records still reserve identities and count toward the limit; reaching it does not authorize pruning retained state. Journals are serialized and checked against the reader's 1 MiB, 1,024-entry, depth and value bounds before creating transaction recovery state.

Writes acquire the existing session-local SID mutex plus a successor exclusive writer file. File transactions follow:

1. Validate all destination addresses, duplicate destinations, expected current hashes, and prepared changes.
2. Persist a Preparing journal before staging original/next bytes.
3. Stream backups and staged copies with bounded buffers and expected SHA256 checks; flush staged files before publishing them.
4. Persist Prepared/Applying state, replace individual owned destinations, then commit the catalog and transaction state.
5. On recoverable failure, validate the whole recovery plan before reverse writes and recheck each destination immediately before restoring it. Outside changes stop recovery rather than being overwritten.

Atomic file replacement uses same-directory staging and File.Replace or move for a new file. It checks the expected destination hash before staging and again before replacement, including retries. It never falls back to deleting the old file before copying. Windows errors 32, 33, and 1175 receive bounded retries only while the stage remains and original destination hash is unchanged. Tests reproduce reader contention with error 32 and an external edit after recovery preflight. These checks narrow ownership races but are not an atomic filesystem compare-and-swap guarantee. They do not diagnose the earlier intermittent error 1175.

Import preflight checks unowned selected shortcut destinations before any selected writes; the locked re-preview checks again. Matching imports rebuild genuinely missing owned artifacts using the same missing-slot adjustment as Repair, without accepting foreign replacement bytes. Favorites adds an approval-bound new-only mode: concurrent saved names or URLs are conflicts, and changing the mode invalidates the fingerprint. Collision-aware candidate naming reserves tombstones, aliases, shortcut paths and legacy folders without adopting their contents.

`SafeFiles.ExportPath` protects source Bookmarks, successor/legacy roots and shortcut destinations from export replacement, including explicitly forced writes. It rejects trailing-dot/space path aliases and applies the normal safe-path checks. These checks do not establish immunity to every hardlink or concurrent path substitution.

Preparing recovery can retire an interrupted preparation only while every target still has its original hash. A directory created immediately before the first journal write can remain without a journal and requires manual investigation. Backups are not pruned automatically. Multi-app imports are not power-loss-atomic: a later unexpected app failure can retain earlier successful apps, and results must be inspected.

## Migration and Rollback

**Live legacy migration and rollback default to disabled.** Only the explicitly isolated manager/CLI enables the experimental handoff. Cross-session predecessor writer exclusion is not proven: a new lock file does not make old code honor it, and a session-local mutex is not a machine-wide fence. This release gate is enforced before live migration writes.

Within a synthetic fixture, migration preview validates the old schema 1/2/3/4 definition, exact identity, legacy-owned files and destination state, then fingerprints the proposed handoff. Apply revalidates approval under the writer lease. It archives all owned original bytes, including unchanged files, records the receipt, retires the legacy manifest, and installs the compiled ownership record. It preserves browser data, launcher location, shortcut identity, and local window/profile semantics.

Rollback uses the stored receipt and transaction archive, verifies current successor-owned hashes and restore destinations, and restores original owned bytes. Owned artifacts added only after migration, such as a newly enabled Desktop or Start shortcut, are removed with their current recorded hashes. The legacy manifest is restored late so an old manager is not invited to use a half-restored definition. Any foreign modification or missing required archive is a conflict. Rollback is not permission to delete new or retained browser data.

The isolated migration cases and shared transaction tests exercise these contracts. Real old/new manager coexistence, session switching, abrupt loss of power, and installer rollback still require [external acceptance](Compiled-Acceptance.md).

## UI and Background Work

[EditorSession.cs](../src/EasyEdgeApps.Core/EditorSession.cs) owns baseline/draft identity, pending icon generation, Save/Discard/Cancel decisions, and success/failure transitions. Raw scheme-less website intent is retained separately from a normalized definition, so failed and cancelled resolution does not silently replace the user's text. Unrelated edits do not dismiss a failed icon operation. Save waits for relevant icon work.

The saved-websites list is disabled during commands, and a late selection event is restored to the active editor identity. Remove confirms the actual saved website name and uses that captured permanent identity. A failed icon preparation exposes a blocking state to both editor Save and the unsaved-draft dialog, with explicit recovery choices; restoring the saved icon retains unrelated edits. These behaviors have an actual isolated WinUI safety regression.

[MainWindow.xaml](../src/EasyEdgeApps.Manager/MainWindow.xaml) provides an editor-first native surface with a saved-websites list or tiles, visible notes/profile/window/icon choices, fixed Save/Open/Remove commands, and direct kit/Favorites/Check controls. Only normal Edge profile details are in the expander. Startup centers and bounds the manager to its display working area. UI orchestration remains in [MainWindow.xaml.cs](../src/EasyEdgeApps.Manager/MainWindow.xaml.cs) and [MainWindow.Tools.cs](../src/EasyEdgeApps.Manager/MainWindow.Tools.cs). File/network/decoder work runs asynchronously; UI changes stay on the dispatcher. HTTP and browsing-mode confirmations default to keeping the draft. Isolated mode disables browser, pin, and network actions.

Favorites has a persistent profile/refresh/selection/placement dialog, visible disabled candidates, and retained choices when import preview is cancelled. The import preview exposes current and effective values, including retained local profile/window choices. Encryption validation uses a ContentDialog button deferral, clears temporary character buffers after every attempt, and permits retry without dismissing the dialog. Cancelled encryption or save-file selection returns to the export name, notes and website selection. Managed strings and PasswordBox internals cannot promise secure erasure; protected kits remain experimental.

[DesktopInspection.cs](../src/EasyEdgeApps.Windows/DesktopInspection.cs) builds native Check Apps results above catalog hash inspection. It checks ICO/configuration/shortcut metadata, current Edge path and bundled launcher hash. Status precedence is Conflict, Blocked, Repairable, Healthy; only repairable active records are selectable. Unfiltered inspection reports bounded unclaimed successor app folders without reading browser contents or creating ownership. Repair starts from the inspected catalog hash. Legacy candidates and corrupt-catalog recovery remain separate, and this inspection never launches Edge.

WinUI theme templates can override inherited FontSize, so the selected size is applied to realized controls and dialogs. The default is 16 DIP. Original 12/14/16/18-point settings map by exactly 4/3, including fractional DIP sizes; successor preferences take precedence without writing during fallback reads. Actual UIA TextPattern measurements verify size, not only a stored preference. The default font/branding hierarchy is retained for intentional display elements. Native live status notifications are emitted on changed status, but no automated property check establishes spoken screen-reader output.

## Native Lifetime

The window controller owns a non-inheritable duplicate of its job handle until its worker finishes, so a timed-out disposal cannot leave callbacks using a caller-closed handle. The launcher explicitly terminates only a job it successfully assigned its new process to, then releases handles even if controller disposal fails. Rejected duplicate launches do not terminate an already-running job. The original embedded PowerShell controller and generated compiled source contain the same changes.

Taskbar assistance terminates its owned helper tree on cancellation and awaits helper exit before returning cancellation. Tests use a repository-bound synthetic helper that never contacts the shell. Identity polling remains at 250 ms for named apps to handle later owned windows; its long-running real-Edge cost is unmeasured. Synthetic handle, child-tree and cancellation checks are not live browser shutdown or pin acceptance.

## Images and Network Boundaries

[WebsiteIconClient.cs](../src/EasyEdgeApps.Core/WebsiteIconClient.cs) uses credential-free requests without browser cookies, automatic redirects, or default Windows credentials. Scheme-less resolution uses HTTPS HEAD first and permits HTTP fallback only for connection/name-resolution failures, not TLS errors. Any HTTP response over HTTPS retains HTTPS. HTML is parsed with AngleSharp, not script execution; candidates and redirect hops are bounded.

Image input is limited to 8 MiB, with PNG/JPEG/GIF/BMP dimensions checked before decode, at most 4096 pixels per side and 16 megapixels. Static SVG has a restricted XML/element/attribute contract and no scripts, DTD, event attributes, external resources, or embedded image loading. Generated output is a bounded 256-pixel classic DIB ICO. These limits deliberately differ from the retained PowerShell downloader's larger-image behavior.

[IconWorkerClient.cs](../src/EasyEdgeApps.Windows/IconWorkerClient.cs) starts a real conversion child, assigns a job before supplying untrusted input, sets one-process/384 MiB/kill-on-close limits, and imposes a 20-second deadline. Active cancellation is tested after the child consumed input. It is resource containment, not a restricted token or AppContainer sandbox. Some validated ICO preview operations still execute in the manager process.

## Updates and Diagnostics

[UpdateClient.cs](../src/EasyEdgeApps.Core/UpdateClient.cs) checks the fixed official release source with bounded, credential-free transport. Checks are opt-in. [PublisherTrust.cs](../src/EasyEdgeApps.Windows/PublisherTrust.cs) requires the authorized publisher and timestamp; hashes alone are insufficient. [PackageMaintenance.cs](../src/EasyEdgeApps.Persistence/PackageMaintenance.cs) verifies signed index trust, exact payload paths/sizes/hashes, and staged-directory contents without loading untrusted assemblies. [InstallerUpdate.cs](../src/EasyEdgeApps.Windows/InstallerUpdate.cs) additionally inspects MSI identity and revalidates the approved artifact before constructing installer handoff.

Malformed release objects, asset objects and supported-asset size fields fail with explicit validation errors before any download. The CLI validates requested Favorites names strictly but ignores unrelated unusable candidate titles during explicit name matching; full source parsing and read-only preview remain unchanged.

The default build publisher pin is empty. These unsigned packages cannot become trusted updates. A future authorized signing pipeline must account for signatures changing file bytes before producing the final index/archive.

[PendingUpdateStore.cs](../src/EasyEdgeApps.Persistence/PendingUpdateStore.cs) persists a strict owned MSI path/hash/version pointer before Install/Later. Reopening it repeats publisher, timestamp, hash, newer-version and MSI-identity validation. The pointer is not authentication. Isolated mode prohibits installer execution.

[PortableDeployment.cs](../src/EasyEdgeApps.Persistence/PortableDeployment.cs) revalidates current/staged indexed trees and expected publisher, binds an approval fingerprint, and uses an adjacent `.Name.updates/<transaction>/receipt.json`. Prepared, PreviousMoved, Activated and Committed transitions retain the previous deployment. RollbackPrepared, NextMoved and RolledBack retain the newer deployment while restoring the previous one. Recovery checks actual verified disk state when the receipt lags a move, and refuses outside-modified files. A separate trusted helper must run with target programs closed. Lock checks and injected interruption tests are not real process-lifecycle or power-loss acceptance. Previous trees are not pruned automatically.

The CLI requires all staged/plan/receipt fields with exact types before deserialization, and confines isolated input-record and deployment paths before inspecting them. It uses the real publisher verifier, not the mock used in transition tests.

[UserPreferences.cs](../src/EasyEdgeApps.Persistence/UserPreferences.cs) stores opt-in settings and bounded category-only UTC logs. Diagnostic failure must not fail the actual operation. [SupportReport.cs](../src/EasyEdgeApps.Windows/SupportReport.cs) emits only allowlisted versions/platform/aggregate health, never saved URLs, notes, names, IDs, browser contents, or machine/user paths. Nothing is uploaded.

Support aggregates currently use catalog owned-hash checks, not the full native `DesktopInspection` result. The difference is deliberate in the documented evidence boundary, not proof of runtime health from support counts.