# C# and WinUI Migration Progress

## Latest Readiness Delivery: p4

The additional readiness pass supersedes the snapshots below. The current runnable folder is [p4/build-result.json](../artifacts/p4/build-result.json); all older deliveries remain intact. The [current report](Compiled-Validation.md#current-delivery-p4) records hashes, commands, regressions, screenshots and external blockers. **Local gates pass; production readiness and one-for-one acceptance remain unestablished.**

- [x] Fresh Tier 4 reports returned from Claude Opus 5 Expert (editor/CLI), GPT-6 Astra Expert (durable state), GPT-5.3-Codex Expert (parsing/trust), Gemini 3.8 Flash Expert (test/release gates) and Grok 4.6 Expert (native lifetime). Zero reviewer calls; runtime model independence unverified. No redispatch is owed.
- [x] Reproduced and fixed catalog/journal reader-limit violations, recovery overwriting late external changes, and rollback leaving later-enabled shortcuts.
- [x] Reproduced and fixed malformed update metadata and invalid excluded Favorites titles poisoning valid explicit CLI selection.
- [x] Actual GUI regressions now lock busy selection, confirm the captured saved Remove target, block icon-failed Save routes and preserve notes through saved-icon recovery.
- [x] Native controller owns its duplicate job handle until worker exit; launcher explicitly terminates only its assigned job, including failure with another handle open. Embedded legacy and generated source match.
- [x] Taskbar cancellation awaits its synthetic helper's exit. Old code passed the timing baseline; a no-termination mutation failed the intended assertion, then the restored implementation passed. No actual pin occurred.
- [x] Package/MSI checks share the selected build record and reject a conflicting override. Disproved SVG-root, stale-native-error, missing-legacy-CI and absent-normal-shutdown premises were not turned into speculative changes.
- [x] Full current Core: 182 passed. Full Windows: 84 passed, one explicit hosted-topmost skip. Retained PowerShell: 19 suites in each host, 38 passed.
- [x] Built current unsigned `p4` folder/ZIP/MSI; exact package/native-source/notice checks passed. No production source change followed packaging.
- [x] Eight published GUI workflows passed: full 16-DIP Original and 24-DIP Light including protected-kit pickers, safety at both sizes, enlarged Favorites/window choices, legacy-14-point Settings and System appearance. Eleven hash-matched capture copies preserve current states.
- [x] Final tracked diff and 106 new text files audited; 12 PowerShell files parsed, documentation checks and touched-file diagnostics passed, native/published-script parity and hashes rechecked. No owned GUI-test process or fixture remained. Analyzer comparison found no new errors, but the retained script still has three existing errors and one added naming warning; nothing was suppressed.
- [ ] Complete separately authorized disposable Edge/shell/installer/cross-session/accessibility/signing/audit gates before enabling live migration or claiming production parity.

The first full Core run exposed fixture cleanup racing a live staged writer; the test now always joins its writer before cleanup. The first Windows run had five failures, one explicitly due to disk exhaustion at 236 MB free. Only inspected regenerable build outputs were reclaimed; all delivery and failure evidence was preserved. Without production edits, six affected cases and then the full Windows suite passed. This supports disk pressure for the generic CLI failures without inventing their individual exceptions. Both initial results remain linked in the validation report.

Current measured payload: 427,222,548 bytes. Per-site launcher: 141,518,994 bytes; retained Framework target: 48,128 bytes. Full GUI peaks: 656,527,360-661,307,392 bytes. Identity polling remains 250 ms for later windows, with long-running real-Edge cost unmeasured. These are material costs, not benchmarks. Live migration remains disabled; packages are unsigned and not publisher-authenticated.

All lower sections are chronological history, not assertions that an earlier result accepts current source. No deliberate mutation remains. No signing, installation, real browser/profile/pin, publication, commit or push occurred.

## Historical Parity Delivery: p3

This section superseded the earlier snapshots at the `p3` handoff. Its runnable folder is recorded in [p3/build-result.json](../artifacts/p3/build-result.json); `compiled-delivery` and `p2` are older still. The [historical p3 report](Compiled-Validation.md#historical-p3-delivery) retains exact hashes, screenshots and measurements. No new expert was dispatched during that parity-resume work; the original five reports did not review those subsequent edits. The fresh readiness council and `p4` fixes are recorded above.

- [x] Restored editor-first controls, original/System appearance, exact legacy text mapping, startup working-area fit, settings/defaults and saved-icon/failed-draft behavior.
- [x] Implemented native Check Apps metadata/runtime/template inspection, unowned successor-folder diagnostics, disabled non-repairable rows and stale-inspection repair rejection without adopting retained data.
- [x] Restored Favorites profile/refresh/placements/exclusions, retained cancelled preview, collision-aware naming, new-only approvals and before/after import settings.
- [x] Fixed matching-kit missing-owned-file repair and unowned shortcut preflight; retained missing-custom-icon and foreign-file protections.
- [x] Added retryable encrypted-dialog validation and cancelled-export draft retention, CLI named selection/icon/taskbar/Favorites choices, guarded exports and strict portable CLI records with real publisher verification.
- [x] Rebuilt current self-contained portable ZIP/MSI and retained original distribution under `p3`; exact payload/ZIP/read-only MSI/native launcher tests passed.
- [x] Current full Core suite: 171 passed. Current full Windows suite: 75 passed, one explicit hosted-topmost skip. Retained PowerShell: all 19 suites on both hosts, 38 passes.
- [x] Exact published GUI: full default 16-DIP Original and 24-DIP Light, focused enlarged Favorites, legacy-14-point Settings, enlarged window choices and System appearance all passed. Nine versioned screenshot copies preserve historical captures, including the enlarged protected import preview.
- [x] Actual protected-kit Save/Open round trips passed at 16/24 DIP, including save-picker cancellation, encrypted output, wrong-password retry, correct unlock, reviewed import and unchanged catalog/source bytes. The focused cancellation mutation failed at the intended lost-draft assertion and passed after restoration; see the [current evidence](Compiled-Validation.md#current-executed-gates). Both optional picker modes are documented and remain outside CI.
- [x] CI now includes the four focused GUI gates and retains their evidence. Structured YAML and all four embedded PowerShell blocks passed; no remote workflow was run.
- [ ] Complete externally constrained Edge/shell/installer/cross-session/signing/audit acceptance before enabling live migration or declaring production parity. Other picker locales/provider versions and exhaustive keyboard/speech coverage remain unverified.

New failure evidence remains visible. Matching kit repair failed for all five owned slots before the ownership adjustment. Encryption validation dismissed the modal; import preview omitted actual comparisons; startup was not centered. New-only guard mutations allowed concurrent update/duplicate URL and were restored. Four forced export cases initially replaced synthetic protected files. All these changes have focused failing/passing evidence and current full gates.

The first full `p3` Windows run had a writer-mutex collision and two 90-second Windows PowerShell interoperability timeouts. Serializing the Windows test assembly removed the shared-resource collision but not crypto timeouts. Safe stage timings showed completed work, so only the bidirectional crypto worker received a three-minute bound. Subsequent full results passed, but stage timings do not account for all observed latency. No production mutex, cryptography or decoder deadline was changed. Historical File.Replace 1175 and other undiagnosed native/filesystem failures remain open.

Picker harness diagnostics established misleading UIA pane/read-only providers, distinct native filename hierarchies and a synchronous Save timeout. Exact owner/class/path checks, bounded cross-process text read-back and queued native command clicks now pass without global input. Early full-workflow mutation attempts failed before the target assertion and do not count as sensitivity evidence. The focused fixture fixed its initial Save-readiness race; the subsequent precise mutation failure and restored pass are retained. Earlier full-workflow UIA/input failures are still unexplained.

Current measured payload is 427,216,088 bytes; launcher 141,518,994 bytes per site; full GUI peak 653,668,352-663,093,248 bytes. These are material costs, not performance parity. All deliberate mutations are restored. No signing, installation, live browser profile, real pin, publication, commit or push occurred.

## Authorized Scope

- Goal: preserve v1.4.0 while delivering a compiled C# manager, CLI, website launcher, WinUI 3 UI, tests, and local packages.
- Workspace: this EasyEdgeApps repository only. Synthetic test data and isolated application roots only.
- Prohibited: publication, pushes, merges, installed-product changes, real browser profiles, credentials, and external filesystem exploration.
- Preserve the original PowerShell distribution and all pre-existing code unless removal is separately authorized.
- No production-readiness claim without the required external Windows, shell, upgrade, and signing evidence.

## Baseline (2026-09-09)

- Origin: https://github.com/blakedrumm/EasyEdgeApps.git.
- HEAD: 14d6cea3a88febeb296c0eccfd883d8ea92e25e0, main, v1.4.0.
- Reviewed revision and checkout are identical. Initial tracked/untracked worktree was clean.
- Available: .NET SDK 10.0.303, runtime 10.0.11, Windows PowerShell 5.1.26100.8875, PowerShell 7.6.5.
- Existing isolated suite runner: `tests/Invoke-Tests.ps1 -BothHosts`.
- Evidence labels used here: SOURCE, UNIT/MOCK, AUTOMATED, WINDOWS, EDGE, PACKAGE, UNVERIFIED, BLOCKED, PROHIBITED.

## Council Assessment

Tier 4, five read-only experts, no nested review. Runtime model independence is unverified.

- [x] Claude Opus 5 Expert: RETURNED. Preview omitted effective window validation; owned-launcher behavior is embedded in the main script, not installer/Launcher.cs.
- [x] GPT-6 Astra Expert: RETURNED. Isolated catalog and explicit ownership transfer; permanent IDs and historical aliases; reject old writers and stale approvals.
- [x] GPT-5.3-Codex Expert: RETURNED. Preserve strict parsing, redacted diagnostics, experimental encryption; production updates require authentic signer and timestamp, not checksums.
- [x] Gemini 3.8 Flash Expert: RETURNED. Separate core/editor automation from real WinUI UIA and disposable Edge/shell acceptance; preserve undiagnosed timeout evidence.
- [x] Grok 4.6 Expert: RETURNED. Preserve per-site image paths/AUMIDs; prebuild identical launchers; measure runtime footprint and keep MSI away from website data.
- [x] Coordinator: verified the defect by source and both-host execution. Remaining platform/version and design claims require the checks recorded below, not expert agreement.

## Milestones

- [x] Reproduce import-preview incompatibility with failing FullScreen/topmost, false/omitted/schema-1 and batch regressions.
- [x] Share effective-setting validation between preview and apply; validate on both PowerShell hosts.
- [x] Record parity matrix, architecture, baseline failures and unresolved Windows acceptance.
- [x] Build compiled core, persistence, Windows integration, launcher, CLI, and WinUI projects using supported tooling.
- [ ] Implement stable identity and rename, deliberate migration/backups, coexistence and rollback.
- [ ] Preserve launch, profile, taskbar and placement contracts without runtime PowerShell/source compilation.
- [ ] Implement edit recovery, accessible setup, themes, diagnostics, flexible icons, maintenance, and optional websites view.
- [ ] Preserve kits, Favorites, repair, logs, attribution, licenses and automation compatibility.
- [x] Add and execute focused regression tests, mutation checks, build validation, and local equivalents of CI gates; remote CI remains unrun.
- [x] Produce unsigned local installer/portable artifacts with strict production-signing rejection and documentation; positive signing remains blocked.
- [x] Record measured performance, actual native screenshots, and exact external acceptance targets.
- [x] Review the final tracked diff, new-file inventory and requirement coverage; publish no artifacts externally. The parity matrix retains incomplete requirements.

## Decisions and Assumptions

- The checkout, not older assessments, controls behavior and compatibility.
- The import fix must report predictable conflicts before any selected entry changes. Unexpected runtime failures retain documented partial success; no atomic-batch claim.
- No silent enabling of dedicated profiles or removal of destination-local window preferences.
- New formats must not allow an old manager to silently rewrite successor state. Migration is explicit and preserves stable IDs and browser data.
- Signing credentials are unavailable unless an already-authorized signing mechanism is established without inspecting credentials. Local test artifacts will be explicitly unsigned.
- Council architecture recommendation: separate successor catalog, explicit migration, immutable IDs, aliases reserved after rename. An in-place schema bump alone breaks legacy enumeration; a schema-4 mirror alone permits old writers. Ownership fencing must be tested before enabling handoff.
- Council deployment recommendation: identical per-site prebuilt executables at the existing fresh-session.exe path, with separately validated configuration. Shared-image pin behavior is unverified, so it is not the initial design.
- Council conflict: deployment proposed a .NET Framework launcher to minimize size; architecture proposed LTS .NET. Resolve after compiling the existing controller and measuring deployment, not by voting. Manager/core use installed .NET 10 LTS SDK 10.0.303.
- Council security resource-limit recommendation applies to the new bounded image-import contract; do not silently alter the original PowerShell network download contract.
- No reviewer calls were made. Model-family independence remains unverified. Some report example commands and version claims are proposals, not executed or independently verified facts.

## Results and Blockers

- SOURCE: Git baseline and existing isolated suite entry point confirmed.
- AUTOMATED: initial fixture failed at COM shortcut metadata because its path contained '..'; canonicalizing the synthetic root fixed this test defect.
- AUTOMATED: unfixed Windows PowerShell 5.1 and PowerShell 7 each showed all four cases as preview Update,Update and apply Updated,Failed. First-app manifest, launcher, and shortcuts changed. This is now an executed defect, not only source inference.
- AUTOMATED: fixed regression passes in both hosts: Update,Conflict and Not attempted,Conflict; all selected file hashes unchanged. Both window modes, explicit false/omission, schema-1 preservation and repair covered.
- SOURCE: docs/Window-Controls-Review.md read. Historic observed Edge acceptance and one undiagnosed persistent shutdown timeout are not current-run passes or a diagnosed race. Narrator, physical DPI, real pins, clean installs and signing remain external acceptance.
- AUTOMATED: native controller extraction and net48/net10.0-windows launcher builds passed. The controller algorithms remain mechanically linked to the original implementation; build-time extraction is not a runtime dependency.
- AUTOMATED: Core/Persistence reached 51 passing tests, including 96 owned-window combinations, permanent identities, alias resolution, stale approvals, transaction rollback, retained files, schema 1-4 migration and draft recovery.
- AUTOMATED: the later 55-test core run had 54 passes and one journal File.Replace IOException. All six migration tests passed unchanged on the focused rerun. The intermittent replacement failure is undiagnosed, not erased by the rerun.
- WINDOWS: 14 Windows tests passed, including native shortcut/AUMID metadata, actual prebuilt launcher --health, ICO/PNG/JPEG rendering, unsigned publisher rejection and support-report privacy. No real Edge launch or taskbar pin was requested.
- AUTOMATED: WinUI manager builds on .NET 10 with Windows App SDK 2.4.0 and SDK BuildTools 10.0.26100.4654. The older BuildTools pin failed dependency validation and was corrected. Actual UI execution remains unverified.
- AUTOMATED: compiled CLI builds; its command behavior still needs execution tests. Added portable encryption, Favorites, opt-in update checks, signed-index staging, preferences and allowlisted logs; these have varying test coverage and are not complete acceptance.
- AUTOMATED: the Fresh-session fixture had a cmd.exe quoting failure with repository-local paths containing spaces. The test-only quoting repair passed the full Fresh suite on both hosts.
- UNVERIFIED: broad 19-suite/both-host baseline completion. Retained output stops during Kits without a final result; do not claim 38 suite passes. Recover or run the remaining suites with durable output.
- UNVERIFIED: cross-session predecessor exclusion, power-loss recovery, compiled-host native window/process acceptance, complete C#/PowerShell crypto interoperability, image decoder isolation, signed/timestamped positive verification, package staging tamper tests, WinUI UIA, packaging and performance.
- IMPLEMENTED/PARTIAL: explicit schema 1-4 handoff/rollback, separate catalog, reserved aliases, stable paths, writer leases and journaled file changes. Migration is not ready for real user data until coexistence and disposable-system gates pass.
- IMPLEMENTED/PARTIAL: manager save/rename/remove/repair, themes, file icon picking and draft prompts. Kits, Favorites, migration/recovery, support, maintenance, drag/drop, responsive layout and accessibility still need UI integration and execution.
- BLOCKED: production signing needs an authorized expected signer and timestamped artifacts; encrypted kits require an independent cryptographic audit. Unsigned hashes do not authenticate a publisher.
- PROHIBITED: installed MSI execution, real-profile/browser tests, live shell changes, publishing, remote writes.

## Earlier Executed Evidence

This section supersedes the earlier milestone snapshots above; the earlier failures remain part of the record.

- AUTOMATED: all 19 isolated legacy suites passed in both Windows PowerShell 5.1 and PowerShell 7.6.5. The 38 exit codes and timings are retained in `artifacts/legacy-migration-verified/results.json`, with one log per suite. Temporary test data stayed under repository artifacts. A longer fixture root caused the legacy shortcut ownership check to fail; the identical Tools GUI suite passed with a shorter root. This is a legacy path-length limitation, not a privacy-warning regression.
- AUTOMATED: the last full Core run passed 67 tests. Subsequent focused slices passed: 13 migration/transaction, 8 package, and 7 editor tests. The current full inventory must be rerun after all changes.
- WINDOWS: the last combined Windows run passed 22 tests, including both-host encrypted-kit interoperability. Later focused slices passed: 2 CLI recovery/workflow, 2 profile/default, and 3 maintenance checks. Current combined inventory is not inferred from those numbers.
- AUTOMATED: newly expanded migration tests failed for all four legacy schemas when an unchanged icon was omitted from the archive and replaced after migration. Complete migration archives now restore original icon bytes; ordinary saves still skip identical payloads. All 13 migration/transaction tests passed after the fix.
- AUTOMATED: the failed-icon regression failed when an unrelated notes edit dismissed the failure. It now remains until retry/replacement/cancellation/discard; all 7 editor tests passed. Corrupt-catalog CLI recovery/support/settings also have observed red/green evidence.
- AUTOMATED: package tests reproduced Windows device-name acceptance and ignored extra staged files. Both are fixed. Mock publisher verification proves ordering only, not real Authenticode trust. Published RFC 7518 Appendix B.3 and experimental encryption interoperability passed; independent cryptographic audit remains required.
- WINDOWS: actual WinUI startup, saved website labels, defaults, save, stable rename, dirty Cancel/Discard, compact layout and clean close passed through UI Automation. Captures are `artifacts/compiled-ui/desktop.png` and `compact.png`. Original logo and generated site icon were visually inspected. No Edge or taskbar pin was requested.
- WINDOWS: one observed native UI run recorded startup 1,598 ms, first save 9,049 ms, rename 2,969 ms, working set 197,705,728 bytes and peak working set 621,580,288 bytes. These are single-run observations, not clean-machine benchmarks; save latency and memory remain material limitations.
- WINDOWS: actual bounded image worker rendered static SVG pixels and rejected script/DTD input and pre-cancellation; raster headers are checked before native decode. The process has memory, active-process and time limits, but is not an AppContainer or a security sandbox. HTML discovery uses AngleSharp 1.5.0; 1.4.0 was rejected after its NuGet advisory. Offline transport tests passed; live website acceptance was not performed.
- PACKAGE: an unsigned portable ZIP and per-user MSI were built under `artifacts/compiled`. WiX validation passed after deterministic component GUIDs replaced unsupported automatic GUIDs. MSI product/version/per-user metadata was read without installation. These initial artifacts predate later changes and must be rebuilt.
- DECISION: the compiled distribution uses the self-contained .NET 10 per-site launcher to avoid a separately installed runtime. Actual Framework and LTS provisioning/identity/health tests passed. Measured launcher sizes: Framework 47,616 bytes; LTS 141,518,994 bytes (134.96 MiB per site). The smaller Framework build remains a compatibility target. Runtime-family independence of council reports remains unverified.
- IMPLEMENTED: manager/CLI image imports use the decoder worker; Favorites has read-only profile discovery, new drafts use the profile preference, import refreshes the selected baseline, tile/list choice is persisted, and successful manager operations emit optional best-effort category logs.
- IMPLEMENTED/PARTIAL: update UI downloads only with a build-pinned publisher, checks Authenticode/timestamp and MSI identity, revalidates approval, then offers Windows Installer. Unsigned builds cannot use the handoff. Portable staging is verified but has no automatic activation. Taskbar assistance constructs the existing owned launcher's `--pin` request; actual shell behavior remains external acceptance.
- UNVERIFIED: the earlier journal File.Replace failure is not diagnosed by later passing tests. Cross-session predecessor writers, power-loss preparation recovery, compiled native process/window fixtures, full tool-dialog automation, large text/high contrast/spoken accessibility and clean-machine deployment still require the specific remaining gates.

## Next Action

The local delivery guides, packages, current combined suites and published-UI gates are recorded in [Compiled-Validation.md](Compiled-Validation.md). Complete the remaining parity work and separately authorized disposable-Windows/signing/audit gates before claiming a completed migration. No repeated council dispatch is needed for already-returned scopes.

## Subsequent Validation And Safety Work

- AUTOMATED: complete current Core and Windows runs passed 75 and 28 tests respectively before the later durability and native-fixture additions. Machine-readable evidence is under `artifacts/compiled-tests-current`.
- PACKAGE: a complete pipeline now performs locked solution restore, native extraction verification, brand generation, both launcher targets, self-contained manager/CLI/worker publish, original distribution build, exact notices, embedded release index, ZIP, MSI and checksums. `artifacts/compiled-current/build-result.json` records the completed package build. The 427,027,980-byte payload and 141,518,994-byte per-site launcher are measured, unsigned artifacts. Later source changes require another final package build.
- AUTOMATED/WINDOWS: the first complete portable publish crashed with code 0xC000027B because generated XAML and PRI resources were omitted. The same build output passed. Explicit XBF/PRI publishing fixed the published manager; the complete merged portable folder passed actual UI automation. A package regression fails against the retained pre-fix archive and passes against the corrected archive. All indexed payload/ZIP hashes and MSI metadata were checked; the real publisher verifier rejected the unsigned archive and MSI.
- PACKAGE: the deterministic notice collector retained manifest, declared license and supplied license/notice files for 29 exact restored production/build packages, including runtime packs. Expression-only AngleSharp attribution is included; existing SVG.NET/ExCSS license texts are preserved. This is retention evidence, not a legal opinion or publisher authentication.
- CI: `.github/workflows/compiled.yml` adds pinned-action Windows build, test, published WinUI and artifact-evidence jobs. Structured YAML parsing and all embedded PowerShell blocks passed locally. No workflow was pushed or executed remotely. The original workflow remains present.
- AUTOMATED: recovery now writes a Preparing journal before backups, validates the entire journal before writes, and retires interrupted preparation only if destination hashes remain original. Null records and duplicate indexes had observed failing tests; 19 transaction/migration checks then passed. A crash before the initial journal exists still fails closed for manual investigation.
- AUTOMATED: omitted IDs and profile choices, null nested catalog records and incomplete ownership metadata had observed red tests. Stored catalog shape is now mandatory and active artifact ownership complete. All 40 combined catalog/transaction/migration checks passed after the subsequent replacement-contention fix.
- WINDOWS: a held reader reproduced sharing violation 0x80070020. Bounded retries now handle Windows errors 32, 33 and 1175 only while the staged file remains and the original destination hash is unchanged. Transient-reader recovery and persistent-lock preservation have actual red/green tests. Snapshot readers allow delete sharing. The earlier intermittent "Unable to remove the file to be replaced" cause is still not proven by the different-HRESULT reproduction.
- SAFETY GATE: live legacy migration and rollback now default to disabled. Manager/CLI enable them only for explicitly isolated fixture roots. The seven migration checks include default-deny/no-write evidence and all four schemas with explicit synthetic opt-in. Cross-session old-writer exclusion is an unresolved release prerequisite, not an implicit user acknowledgment.
- AUTOMATED: CLI isolated mode now rejects actual browser launch and network update checks before reading a selected site or opening a client. Its complete isolated save/rename/export/remove workflow still passes.
- AUTOMATED: missing custom-icon repair now requires explicit replacement, rather than silently generating bytes under Custom metadata. Explicitly choosing a replacement restores only the missing owned icon. All 20 catalog tests passed.
- WINDOWS: expanded native UI automation now proves Advanced/Notes scroll reachability, forced writer-lock save failure with unchanged catalog, retained draft/selection, successful retry, Cancel/Discard and compact layout. Captures and observations are under `artifacts/compiled-ui-recovery`. This is not spoken accessibility, physical DPI or all-dialog acceptance.
- WINDOWS: the original child-process fixture now also runs against the compiled .NET 10 controller. Child-tree lifetime, active-job cleanup exclusion, supervisor interruption, leased allocation and long-path cleanup passed. A temporary mutation from active-process-zero to process-start completion failed because the child was terminated before readiness; restoring the original event passed. Both original host fixtures passed again, and native extraction verification confirmed restoration. No Edge process was opened.

## Latest Focused Evidence

These results supersede earlier descriptions of the corresponding slices, not the earlier failed evidence. No final combined-suite count is inferred from focused runs.

- AUTOMATED: 16 offline website/address cases pass, including refused HTML page favicon fallback, header-only HTTPS probing, explicit URLs without requests, TLS/cancellation non-downgrade, trimmed explicit HTTPS, redirect safety and body bounds. Missing fallback and whitespace safety each had observed red/green tests. Fallback metadata and TLS handling mutations were detected and restored. A ResponseContentRead mutation did not make HEAD read a body and is not claimed as a failing mutation.
- AUTOMATED: 20 catalog, seven migration and 18 transaction cases passed together. Required nested journal Area/Index had observed red/green tests. Backup/apply/rollback now stream staged files with expected SHA256 rather than materializing another full launcher array. Bypassing the stage-hash comparison failed its preservation regression; the comparison was restored.
- AUTOMATED: five preference and seven editor cases pass. Text size and default shortcut placement persist; invalid/null preference fields preserve the original file. Failed/cancelled saves preserve raw scheme-less address intent separately from the normalized definition.
- WINDOWS: nine compiled native process/placement/Escape cases pass, with identity, Escape, process-completion and placement mutations detected and restored. An actual synthetic owned native window restored/captured placement, shut down promptly, and left an unrelated synthetic window untouched.
- UNVERIFIED: topmost did not appear on this hosted desktop, including after a direct SetWindowPos request returned success. No controller root cause is established. The explicit topmost test is skipped unless EEA_TEST_TOPMOST=1 is set in an authorized disposable environment. It is not a passing topmost acceptance result.
- WINDOWS: seven image-worker cases pass, including real GIF/BMP pixels, oversized raster headers, static SVG, pre-cancellation and cancellation after a synthetic decoder consumed input. Temporarily skipping cancellation cleanup made the test fail with an owned child still alive; cleanup was restored and the full slice passed. Direct deadline/memory exhaustion remains unverified.
- WINDOWS: the isolated CLI save/rename/export/remove workflow now requires opted-in UTC/Operation/Outcome-only logs and succeeds when the log is exclusively locked. The missing-log test was observed failing before implementation. Recovery/support with a corrupt catalog also passes. Manager save cancellation/conflict/failure records only fixed categories and never lets diagnostics replace the operation outcome.
- WINDOWS: actual WinUI checks now include browsing-mode approval with cancellation, explicit HTTP approval, isolated scheme-less failure without writes, retained raw input, failed-save retry, visible export selection, real 24-DIP control text, Preferences scrolling, Light-theme dialogs and cleared status after New. An inherited-font-only implementation failed the UIA font assertion and was corrected. Latest inspected large-text captures are under artifacts/compiled-ui-profile-green; the subsequent Light-theme/Preferences gate also passed under artifacts/compiled-ui-light-large.
- WINDOWS: the inspected large-text profile run observed startup 763 ms, save 3,615 ms, rename 2,958 ms, working set 212,520,960 bytes and peak 482,922,496 bytes. These are individual workflow measurements, not controlled benchmarks. No real Edge or global keyboard input was used.
- CI: the compiled workflow now retains default-size and 24-DIP Light-theme published UI evidence. Structured YAML parsing found six steps and all three embedded PowerShell blocks parsed successfully. An initial validator assumed the wrong job shape and was corrected; it did not establish a workflow failure.
- SOURCE: the Windows test project contains exactly one NativeFixture project reference. No duplicate was found on the latest read.
- OUTSTANDING: packages still predate these edits. Current full counts, final published UI, latest shared legacy fixture, complete guides, clean-checkout build inputs, final diff and local package evidence remain to be checked. External Windows/signing/audit gates remain unchanged.

## Local Delivery Results

This section supersedes the prior OUTSTANDING package/test snapshot, not the failed evidence.

- AUTOMATED: final full Core 119 passed. Final full Windows project 57 passed and one explicit topmost skip, zero failed. All 19 retained PowerShell suites passed in both hosts again, including the final shared native fixture. That last run used PowerShell 7.6.6 rather than the earlier 7.6.5.
- WINDOWS: eight decoder tests pass, now including actual 20-second deadline expiry and child-query verification of the applied one-process/384 MiB/kill-on-close job limits. Extending the deadline caused the expected test failure; the original limit was restored. Memory exhaustion was not directly forced.
- PACKAGE: the final payload is artifacts/compiled-delivery/build-19b0623b1a0e488d8734f6ad2f836f7f/portable. The current ZIP/MSI/build record and exact hashes are in [Compiled-Validation.md](Compiled-Validation.md). Payload 427,056,875 bytes; per-site launcher 141,518,994 bytes. Five final package/maintenance checks pass against that exact output. No installation or signing occurred.
- AUTOMATED/PACKAGE: a source-only snapshot of 154 files, excluding bin/obj/artifacts and generated branding, completed the whole locked build and package pipeline from a short repository-local root. The first, longer root reached 261-character payload paths and WiX cabinet compression failed. The generator now rejects such paths early; both failure and shorter successful build are retained. Only regenerable bin/obj directories in those two owned snapshots were later cleaned for disk space.
- WINDOWS: final published default and 24-DIP Light UI workflows pass after command readiness, transient UIA presence and dialog font realization were addressed. The manager refreshes enabled state before a command. Tests wait for actual presence, readiness, typography and scroll state; they do not suppress arbitrary provider errors.
- WINDOWS: actual Preferences font was 10.5 points at a 24-DIP setting, and its new regression failed. Loaded-content sizing fixed it. A subsequent plain-string HTTP callback race failed after restoration of an earlier mutation; explicit loaded text content resolved it. The final editor, Preferences and HTTP confirmation font assertions all pass, with captures retained under docs/images/compiled and artifacts/compiled-ui-delivery[-large].
- WINDOWS: final published default run observed startup/save/rename 946/6,662/2,866 ms and peak 483,213,312 bytes. Large-text Light observed 702/4,797/2,895 ms and peak 483,622,912 bytes. These are individual workflow observations, not controlled benchmarks.
- SOURCE: README now distinguishes the original published 1.4.0 instructions from the compiled preview. Parity, architecture/data recovery, CLI, acceptance, exact local validation and supplied dependency-notice guides are present. Remaining unfinished implementation and external acceptance are explicit; no production-readiness claim is made.
- AUTOMATED/SOURCE: final documentation validation passed 104 local links, 14 PowerShell examples, title punctuation and both delivery hashes. Tracked diff whitespace and conflict markers in 96 new text files passed. Compiled-source searches found no PowerShell-hosting/source-compiler calls. Final touched-file diagnostics were clean.
- OUTSTANDING: full compiled CLI/appearance/preference parity, portable activation/rollback and Later-resume; cross-session predecessor exclusion; real Edge/shell/installer/clean-machine/physical-DPI/spoken-accessibility acceptance; trusted signing positives and independent crypto/license review. Live migration remains disabled.