# Window Controls Review: 1.4.0

Review date: 2026-09-09 UTC. This is a bounded engineering review, not a security certification. The scope is owned website-window controls, compatible profile defaults, the earlier readiness gaps, and release validation. The coordinator alone edited files and ran commands. All five discovery reports were recovered from their retained final responses; configured model names do not establish runtime model-family independence.

## Decisions and delivered changes

| Area | Decision and evidence |
| --- | --- |
| Legacy ownership | Retain historical maximized argument defaults and recognize local schemas 1/2/3. Add schema 4 only for new apps or explicit new-setting adoption. [Launch settings tests](../tests/Test-EasyEdgeAppsLaunchSettings.ps1), [core tests](../tests/Test-EasyEdgeApps.ps1), and [CLI tests](../tests/Test-EasyEdgeAppsCli.ps1) pass in both hosts. |
| Profile route | New apps use a separate persistent profile; existing shared apps require explicit conversion. Normal Edge cookies are never copied. Fullscreen/topmost management is unavailable for shared windows because a shared Edge process does not prove per-app ownership. Taskbar retains Start and dedicated routing even with Fresh. |
| Placement | A bounded, identity-bound `.eea-window` record lives outside browser data, manifests, and kits. It excludes minimized/fullscreen bounds, clamps to current work areas, refuses invalid existing data, and never recreates a removed directory. [Placement tests](../tests/Test-EasyEdgeAppsWindowState.ps1) and real reopen-at-exact-bounds checks pass. Concurrent Fresh closes use the last completed write. |
| Browser lifetime | Controller startup does not depend on an app name. Its STA message loop owns the hook and timer. Cross-process window changes are asynchronous, native display-query errors are nonfatal, shutdown joins are bounded, and completion messages are examined only when dequeued successfully. These are source checks in `RunProcess` and `Controller` in [EasyEdgeApps.ps1](../EasyEdgeApps.ps1), not a proof against every hung-driver scenario. |
| Fullscreen and Escape | Native Edge fullscreen does not reliably retain topmost. Reject that combination in generation/save and disable it in setup. Pass original input onward; post Escape work and recheck exact job/window, foreground, modifiers, fullscreen and shutdown before F11. Native foreground and scheduling races remain. |
| Startup Escape | Real persistent acceptance found Escape arriving before the 250 ms discovery timer. Verify the uncached foreground window against the same strict owned-window predicate, then recheck before action. A test-only disabled discovery timer passes in Fresh and persistent modes; disabling the fallback makes that test fail at Escape exit. See [window acceptance](../tests/Test-EasyEdgeAppsWindowBrowser.ps1). |
| Editor and approval | Protect dirty drafts on New, selection, tools and Close; retain drafts by default. Wire all local choices through saved and pending editor snapshots. Bind new import approvals to the complete canonical definition while retaining legacy tokenless caller compatibility. [Editor tests](../tests/Test-EasyEdgeAppsEditorState.ps1) and [kit tests](../tests/Test-EasyEdgeAppsKits.ps1) pass. |
| Retained data | Missing settings plus a nonempty app folder is a conflict before writes, even when a profile marker exists. Do not infer ownership or removal intent from leftover data. Removal remains data-preserving; same-name recreation can require trusted settings recovery or a different name. |
| Accessibility | Unique editor mnemonics, StatusBar/ProgressBar roles, Busy state, and native name/value/state/description notifications, including idle transition. Modern WinForms notification gating required control-scoped `NotifyWinEvent`, not a process-wide AppContext change. A wrong StateChange event mutation failed exactly at the Busy notification assertion. Spoken output is not established. |
| Resources and display | Dispose replaced owned fonts after updating consumers. Refit setup on working-area/DPI notifications without repeated growth on an unchanged area. Choose the smallest adequate ICO frame. Focused native regressions pass; physical mixed-DPI and live 4K input/decoder stress remain separate checks. |
| Trust and support | Add [allowlisted support information](../tools/Get-SupportInfo.ps1) and [fail-closed signer verification](../tools/Test-PublisherSignature.ps1). Neither supplies a certificate or audit. Actual unsigned fixtures fail verification; positive signer fixtures are mocks. Encrypted kits remain experimental. |
| Release pipeline | Move retained MSI upload to the pinned Node24 action, add authentic 1.3.3 alongside 1.3.2 predecessor checks, retain the installer mutation, and parse whole YAML as well as embedded PowerShell. Publish the exact successful tag-run MSI, not a rebuild. Historical source, MSIs, and build directories remain. |

## Council deliberation

All discovery branches agreed that runtime and external acceptance must not be inferred from source inspection. Shared compatibility and trust facts supplied in their briefs count as one evidence origin, not five. The coordinator verified the changed behavior with source reads, both-host suites, real Edge acceptance, and deliberate failing regressions.

- **Claude Opus 5 Expert:** preserve exact legacy shortcut arguments, keep Fresh geometry outside disposable profiles, sample it while the owned window exists, and test native fullscreen/Escape rather than assuming Chromium behavior. Also flagged startup focus, shell polling, and the bounded icon handle; those distinctions are retained below.
- **GPT-6 Astra Expert:** distinguish shared from dedicated persistent browsing, preserve local settings across Repair/import, bind complete preview definitions, protect drafts, and reject ambiguous retained-profile adoption. These drove the state/editor contracts and regression tests.
- **GPT-5.3-Codex Expert:** signing and crypto audit are external blockers; support information needs an explicit allowlist. Proposed broader integral policy handling and highlighted unknown reparse tags. A real REG_DWORD probe returned Int32, so speculative type widening was not accepted as a demonstrated defect.
- **Gemini 3.8 Flash Expert:** native event observation and keyboard checks were missing; static accessible names and offscreen layouts do not prove spoken output or physical mixed-DPI behavior. Also separated English prompt probes, enterprise controls, SSO, and ARM64 from supported automated coverage.
- **Grok 4.6 Expert:** distinguish measured synthetic painting from live DWM/input latency; fix owned-font replacement and oversized ICO-frame selection; update the deprecated artifact action. Keep the existing large-download contract and do not erase historical build evidence.
- **Claude Opus 5 Reviewer:** rejected the initial controller safety claim because synchronous window changes, fatal transient monitor errors, and an unbounded join could disrupt browsing. Async flags, nonfatal Win32 handling, and bounded shutdown addressed those source defects. Its assumption that original Escape was swallowed does not describe the final always-CallNextHookEx path. Its proposed retained-file deletion was not adopted.
- **Grok 4.6 Reviewer:** found no actionable defect in the revised uncached Escape scope, but requested deterministic pre-discovery coverage. That changed the validation: the disabled-timer test and fallback mutation were subsequently run. Foreground/input and low-level-hook timing uncertainty remain.

## Council collaboration log

| Branch | Assigned scope | Key contribution | Status |
| --- | --- | --- | --- |
| Claude Opus 5 Expert | Owned window runtime | Legacy argument ownership, geometry lifecycle, native acceptance | RETURNED |
| GPT-6 Astra Expert | Durable state and editor compatibility | Explicit profile migration, schema/kit boundaries, draft and approval integrity | RETURNED |
| GPT-5.3-Codex Expert | Security and trust | Signing/audit limits, support allowlist, policy/reparse cautions | RETURNED |
| Gemini 3.8 Flash Expert | Acceptance and accessibility | Native notifications, mnemonics, physical/platform test boundaries | RETURNED |
| Grok 4.6 Expert | Performance and release operations | Fonts, ICO selection, artifact action and operational limits | RETURNED |
| GPT-5.3-Codex Reviewer | Initial Escape/geometry challenge | No usable final report retained; outcome unknown, not corroboration | STALLED |
| GPT-6 Astra Reviewer | Initial migration/data challenge | No usable final report retained; outcome unknown, not corroboration | STALLED |
| Gemini 3.8 Flash Reviewer | Initial acceptance challenge | No usable final report retained; outcome unknown, not corroboration | STALLED |
| Claude Opus 5 Reviewer | Implemented controller | Async-window, monitor-error and bounded-shutdown corrections | RETURNED |
| Grok 4.6 Reviewer | Startup Escape fallback | Strict ownership supported; missing pre-discovery test exposed | RETURNED |

The three unusable initial reviews were not silently repeated or counted as agreement. Their coverage gaps were addressed only to the extent established by the coordinator's tests and the later bounded controller reviews; they are not recovered independent reviews.

## Conflict matrix

| ID | Position A | Position B | Settled by |
| --- | --- | --- | --- |
| C1 | Initial controller is ready for scoped Escape/topmost. | Claude reviewer: synchronous calls and fatal display errors invalidate that claim. | Source changed to asynchronous window operations, caught transient Win32 errors and bounded join. Final both-mode native acceptance passed; arbitrary native stalls remain unverified. |
| C2 | Fullscreen and topmost should both be accepted by the initial test. | Observed Edge fullscreen does not retain topmost. | Reject the combination in product and tests, not merely loosen the assertion. Both-host invalid-combination tests and real window checks pass. |
| C3 | Codex expert: equivalent policy integer representations justify widening accepted types. | Coordinator: no observed supported registry representation fails. | Actual REG_DWORD read returned Int32, already accepted. Preserve fail-closed handling; fleet-specific representations remain an acceptance question. |
| C4 | Claude reviewer: delete retained placement/temp records to permit same-name recreation. | Coordinator: retained nonempty folders can contain browser data and ambiguous history. | Preserve the explicit no-adoption/no-sweep contract. Core retained-data regressions pass; same-name recreation is a documented limitation, not silently repaired. |
| C5 | Passing real Escape runs cover startup discovery. | Grok reviewer: ordinary tests do not force the empty cache path. | Disabled-timer acceptance passed in both modes; disabling only the fallback caused the expected Escape failure. Coverage gap closed locally. |

## Evidence ledger

| Claim | Type | Status | Evidence or exact remaining check |
| --- | --- | --- | --- |
| Final application compatibility and regressions | EMPIRICAL | VERIFIED | All 18 isolated suites on 5.1.26100.8875 and 7.6.5 after the last controller edit; 36 local suite runs. |
| Window modes and topmost | EMPIRICAL | VERIFIED locally | Edge 152.0.4191.66 on Windows 11 26200.9106; exact-job Fresh/persistent bounds, reopen, maximized, topmost-off, fullscreen, Escape and shutdown. |
| Pre-discovery Escape regression detects the original gap | EMPIRICAL | VERIFIED | `-ExerciseEscape -BeforeDiscovery`, Fresh and persistent; negative fallback mutation failed at Escape exit, then restored code passed. |
| Browser data contracts remain intact | EMPIRICAL | VERIFIED locally | Three Fresh launches start empty and clean independently; three persistent launches retain cookies/storage/cache and reuse a running window. [Browser data acceptance](../tests/Test-EasyEdgeAppsFreshSessionBrowser.ps1). |
| Native accessibility event contract | EMPIRICAL | VERIFIED | Exact HWND/object/child/event filtering, Busy entry and idle exit on both hosts; incorrect StateChange mutation failed for the intended event. |
| Spoken status and physical display interaction | EMPIRICAL | UNVERIFIED | Run Narrator/NVDA with a real user and drag/resize across physical mixed-DPI monitors; synthetic events/geometry are insufficient. |
| Local MSI content and authoring | EMPIRICAL | VERIFIED | WiX 5.0.2 build with validation; both-host structural checks passed, without installing over the user's existing copy. |
| Hosted lifecycle and exact released bytes | EMPIRICAL | RELEASE GATE | Required main/tag CI, authentic 1.3.2/1.3.3 and synthetic upgrades, artifact retention and downloaded-asset hash comparisons. Final run URLs/hashes are in the release's VALIDATION.md and SHA256SUMS.txt. |
| Trusted publisher and audited encryption | EMPIRICAL / external review | UNVERIFIED | Obtain a trusted timestamped signing identity and an independent cryptographic audit. Current unsigned artifacts and model reports do not meet these gates. |
| All risks eliminated | INTERPRETIVE | REJECTED | Native, filesystem, policy, operational and external acceptance limits remain below. |

One post-Escape persistent shutdown attempt timed out. Subsequent focused, both-mode normal, and both-mode pre-discovery runs completed; no root cause for that single timeout was established. Acceptance logs retain it rather than interpreting later success as a diagnosis.

## Dissent register

- Do not globally remove `--start-maximized` or silently migrate legacy shortcuts: their bytes participate in ownership. Additive defaults/schema-aware routes were tested instead.
- Do not apply the owned controller to shared normal Edge processes: current job ownership cannot prove a per-name window. Explicit dedicated/Fresh routing is required.
- Do not claim Edge Escape behavior from arguments alone. Observed failure required the approved narrow handler and an additional startup regression.
- Do not widen policy types without a failing supported registry case, replace cloud-folder handling wholesale, or add a fixed icon-source byte cap contrary to the existing download contract. These proposals remain bounded compatibility/resource questions.
- Do not delete retained geometry/browser folders or historical build artifacts to make re-creation or disk usage appear resolved. Restore trusted metadata, choose another name, or separately approve a verified cleanup.
- Shell identity-poll caching and the static 32-pixel icon handle were explicitly outside the geometry change in the discovery report. The handle is bounded by launcher lifetime; no claim of measured shell-poll savings or improved small-icon quality is made.

## Unresolved risks and acceptance

| Risk | Why still open and impact | Exact check or action |
| --- | --- | --- |
| Publisher identity | No trusted certificate; users cannot authenticate the publisher through Authenticode. | Obtain/sign/timestamp release artifacts, then run the signer tool on real signed files and validate on a clean target. Never bypass SmartScreen or managed controls. |
| Encrypted kits | No independent audit; vectors prove interoperability, not security assurance. | Independent review of format, metadata authentication, KDF/parser limits, key handling and failure paths before sensitive production use. |
| Physical/platform acceptance | No proof of spoken announcements, mixed-DPI/4K input, ARM64, locale, enterprise enforcement or cross-PC handover. | Exercise intended workflows on those actual configurations; retain Windows x64 support claims only. |
| Foreground and hook scheduling | Check/input races and LowLevelHooksTimeout are native limits. A rapid second persistent click before the first window appears, or denied foreground activation, may not focus it. | Instrument a disposable delayed-start app and a deliberately busy UI; verify first launch, subsequent focus, Escape and no unrelated input. No AttachThreadInput or synthetic focus bypass. |
| Filesystem and retained data | Same-user races, unusual reparse/cloud/network behavior, crash/locks and retained-name conflicts cannot be treated as a sandbox or secure erase. | Test specific target filesystems and fault cases; preserve recovery data and restore trusted settings rather than adopting or deleting unknown files. |
| Image and disk resources | Streaming/deadlines and smaller frame choice do not sandbox native decoders or bound all disk/RAM use. | Trusted synthetic extreme-size/malformed-image stress on a disposable system; do not impose a new byte contract without approval. |
| Shutdown and shell overhead | One undiagnosed shutdown timeout; ongoing identity polling and a process-lifetime icon handle remain. | Reproduce with owned-job/launcher diagnostics, measure native shell cost, and propose a separate bounded change if repeatable. |
| Build retention | Historical/local GUID build folders consume disk; preserved for provenance, not automatically pruned. | Inventory verified obsolete build outputs and obtain specific cleanup approval; keep published MSIs and the exact tested release artifact. |

See [release notes](releases/v1.4.0.md), [security boundaries](../SECURITY.md), and the unchanged historical [1.3.3 review](Production-Readiness-Review.md). Final distribution evidence belongs to the release validation asset so the committed review does not pretend to know a future CI run or asset hash.