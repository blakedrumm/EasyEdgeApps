# Production Readiness Review: 1.3.3

This is a bounded engineering review, not security certification or a claim of universal superiority to Edge's native app installation. It covers the manager, owned website launchers, icon retrieval, maintenance/import workflows, tests, and release process. No pre-existing source or artifact was removed. Model-family independence was not verified.

## Decisions and delivered changes

| Area | Finding and decision | Evidence |
| --- | --- | --- |
| Startup | Fixed 1000x700 client size caused editor scrolling at saved 12/14/16/18-point text despite a 2560x1392 working area. Fit the realized editor after layout, clamp to working area, retain compact scrolling, and focus the name field. Keep the existing Settings flow-layout workaround. | `Set-EeaSetupWindowSize`; saved-startup regressions in `tests/Test-EasyEdgeAppsGui.ps1` |
| Placement | Preferences could clear a disabled Start menu choice while Taskbar remained checked. Preserve the required entry. | Regression failed before the one-line invariant repair and passed afterward. |
| Painting | The generated frame was already capped at 1920. Stretching and repeated native painting, not uncapped frame generation, dominated synthetic 4K cost. Use opaque pixel sampling, explicit clip rectangles, restored graphics state, and paint-aware pacing. | `StarfieldForm.PaintScene`, `RefreshScene`; opacity, alignment, clipping, and lifecycle tests |
| Icons | The application's actual credential-free ChatGPT page/favicon/manifest/proposed-PNG requests all returned HTTP 403. No decoder defect was established for that site. Explain refusal with safe categories and preserve the current icon. | Live final worker returned `Blocked`; deterministic direct/worker/GUI denial and mixed-failure tests |
| Maintenance | Add derived configured/current/after-import browsing summaries. Fresh takes precedence, Taskbar remains local, schema-1 kits preserve existing Fresh, and schema-2 false/missing disables Fresh. | Four-mode and both-kit-version outcome matrix in `tests/Test-EasyEdgeAppsKits.ps1`; native details-pane tests |
| Retained data | A missing manifest cannot distinguish intentional removal from damage. Keep a visible non-repairable conflict and report uncertainty; do not infer health from a profile marker. | Removed and damaged synthetic folders tested through named and full Check, with unchanged data hashes. |
| Transactions | A read-only staging file raises access denied after commit. Treat it like existing locked-file cleanup, keeping the completion marker and retry semantics. | Real filesystem regression in `tests/Test-EasyEdgeApps.ps1` failed before repair and passed afterward. |

## Council collaboration log

All discovery branches were research-only; the coordinator alone edited files and executed checks. Four targeted leaf reviews followed discovery and tool-backed verification.

| Branch | Assigned scope | Contribution | Status |
| --- | --- | --- | --- |
| Claude Opus 5 Expert | Usability, startup, accessibility, taskbar editor | Saved-font/startup gap and Taskbar/Start invariant; preferred-content fitting proposal | RETURNED |
| GPT-6 Astra Expert | Architecture, compatibility, stale artifacts, value | Retained-data ambiguity, authentic-upgrade gap, conservative artifact inventory, mode-summary proposal | RETURNED |
| GPT-5.3-Codex Expert | Security, ownership, recovery, durable data | Access-denied cleanup gap; reparse and policy-type compatibility cautions | RETURNED |
| Gemini 3.8 Flash Expert | Icon retrieval and regressions | Silent failure diagnosis, missing all-denied tests, manifest and resource-limit proposals | RETURNED |
| Grok 4.6 Expert | Rendering and operational performance | Paint costs excluded from timer budget; nested scaled-paint multiplier; benchmark proposal | RETURNED |
| Gemini 3.8 Flash Reviewer | Startup fitting | Favored post-layout growth over baseline autoscaling and warned against changing the verified Settings workaround | RETURNED |
| Claude Opus 5 Reviewer | Rendering | Challenged attribution of the 4K timing jump and visual neutrality of interpolation; requested just-above-cap, alpha, and alignment checks | RETURNED |
| GPT-5.3-Codex Reviewer | Icon diagnostics | Rejected guessed manifest routes and unapproved byte caps; required safe worker metadata and deterministic failure precedence | RETURNED |
| GPT-6 Astra Reviewer | Mode and retained-data diagnostics | Supported derived mode summaries; rejected interpreting markers as proof of intentional removal | RETURNED |

## Conflict matrix

| ID | Position A | Position B | Resolution |
| --- | --- | --- | --- |
| C1 | Construct at 12 points then autoscale saved size. | Keep saved-font construction and grow the realized content within the work area. | Chose B as the smaller change. Real saved-font startup and compact-layout tests pass; alleged autoscaling focus effects were not accepted as proven. |
| C2 | Clip-aware painting alone might solve maximized cost. | Full-surface invalidation still pays scaled painting. | Both matter. Added clipping for partial repaints and measured the stretch path separately; did not claim clipping alone produced the gain. |
| C3 | SourceCopy is a pixel-neutral first optimization. | Scaled edges and interpolation can change output. | SourceCopy alone barely improved scaled speed and produced translucent edges. Nearest-neighbor/Half sampling plus SourceCopy passed opaque-edge and exact panel-alignment checks. |
| C4 | Manifest probing could fix ChatGPT retrieval. | The site is refusing credential-free requests, including proposed alternatives. | Actual client returned 403 for every tested route. No guessed probes or access-control workaround shipped. |
| C5 | Add a fixed icon-source byte ceiling. | That changes documented large-source behavior. | Kept existing streaming/deadline contract. Resource exhaustion remains documented; changing the contract needs separate approval. |
| C6 | Retained profile markers could identify intentionally removed apps. | The same artifacts can exist after missing/damaged settings. | Kept visible Conflict/CanRepair=false, with honest uncertainty and unchanged-data tests. |

## Measured rendering evidence

Measurements used Windows PowerShell 5.1, the actual native control tree offscreen, paused motion, and `DrawToBitmap`. Post-change measurements used five warmups plus 30 samples. They omit live DWM presentation and physical input latency; timings are machine-specific.

| Client size | Generated frame | Generation mean | Full-tree painting mean | Painting p95 |
| --- | --- | --- | --- | --- |
| Before: 1000x700 | 1000x700 | 3.9 ms | 11.0 ms | Not recorded |
| Before: 1920x1080 | 1920x1080 | 5.9 ms | 16.9 ms | Not recorded |
| Before: 3840x2160 | 1920x1080 | 5.7 ms | 575.7 ms | Not recorded |
| After: fitted 1000x709 | 1000x709 | 3.8 ms | 9.5 ms | 17.3 ms |
| After: 1920x1080 | 1920x1080 | 5.7 ms | 17.5 ms | 25.4 ms |
| After: 3840x2160 | 1920x1080 | 5.6 ms | 50.8 ms | 56.2 ms |

At otherwise fixed settings, direct painting rose from 2.46 ms at 1920x1080 to 53.08 ms at 1936x1089, isolating the stretch transition. At 4K, bilinear/Half averaged 207.01 ms, nearest-neighbor/Half 18.75 ms, and high-quality bilinear/Half 70.48 ms. Nearest-neighbor retained sampled alpha 255; the smooth modes produced partially transparent edge pixels. Fast scaling is an explicit visual tradeoff for this procedural background, not a recommendation for photographic images.

## Evidence ledger

| Claim | Type | State | Evidence or next check |
| --- | --- | --- | --- |
| Saved-font startup fit, initial focus, and compact fallback | EMPIRICAL | VERIFIED | GUI suites on 5.1 and 7, including 1024x768 constraints and 12/14/16/18-point startup |
| Background opacity, clipping, panel alignment, drawing-state restoration, pacing | EMPIRICAL | VERIFIED | Above-cap/4K pixel tests, frame-budget regression, animation/accessibility lifecycle tests |
| ChatGPT automated retrieval succeeds | EMPIRICAL | NOT ESTABLISHED | Actual final worker reports Blocked; manual icon selection is the supported alternative |
| Icon failure privacy and saved-state preservation | EMPIRICAL | VERIFIED | Both-host direct/worker/GUI cases; shared updater regression remains passing |
| Mode preview matches resulting data | EMPIRICAL | VERIFIED | Mode/kit matrix and native Check/import details tests |
| Access-denied post-commit cleanup preserves saved state | EMPIRICAL | VERIFIED | Read-only staging file, completion marker, subsequent cleanup retry |
| MSI authoring retains the previous-folder lookup | EMPIRICAL | VERIFIED | A disposable MSI copy with the AppSearch entry removed failed the exact structural assertion; the untouched candidate passed. No local installation was performed. |
| Retained-only folders can be silently classified healthy | INTERPRETIVE | REJECTED | No trustworthy removal-intent evidence; both damaged and removed cases stay non-repairable |
| No existing files are safe to remove based solely on this review | INTERPRETIVE | CONSERVATIVE DECISION | Positive runtime/test/docs/build uses and unresolved external/dynamic consumers; no removal performed |

## Stale artifact disposition

- Keep the callable Explorer pin-assistance helper and source-hashed runtime helpers. Local callers/tests exist, and external dot-sourced consumers cannot be ruled out.
- Keep source artwork, generation tools, embedded dependency notices, fixtures, and release history. These support regeneration, compatibility, distribution, or provenance.
- Keep historical 1.3.0/1.3.2 MSIs for authentic upgrade testing. They are not obsolete solely because a newer package exists.
- Keep `.wix` and build caches needed for `-SkipRestore`/offline builds. Historical `artifacts/build-*` folders are archive candidates only after provenance and recoverability checks, not deletion candidates approved by this review.
- Generate a fresh release checksum manifest from final assets. Do not treat an old ignored checksum file as authoritative for new binaries, or delete historical artifacts to make the directory look clean.

## Dissent and deferred proposals

- No wholesale reparse-point rejection was added to PowerShell path checks. Session/profile paths already reject reparses more strictly; redirected/cloud-folder compatibility and uncommon reparse tags need a separate targeted threat/compatibility test. Existing symbolic-link/junction rejection remains.
- No widening of browser-policy numeric types was made. Strict rejection of unknown non-null policy representations is safer than accepting additional types without the policy contract and registry fixtures.
- No guessed manifest lookup, fixed source-image cap, browser-cookie import, or third-party favicon fallback was added. Declared-manifest support may be evaluated separately; it is not demonstrated to fix the observed ChatGPT refusal.
- Unsaved-edit prompts, accessibility live-status announcements, and an explicit redacted support report remain proposals, not delivered features. Their interaction, disclosure, and cancellation contracts need focused approval/tests.
- No baseline-font rewrite, control-tree flattening, or removal of existing APIs was necessary for the measured fixes.

## Release gates and unresolved risks

Final release gates are the complete fourteen-suite run on both hosts, real Edge Fresh/persistent smoke checks, installer structure/lifecycle, authentic 1.3.2 upgrade, exact-source asset hashes, main/tag CI, and downloaded-release verification. Their final results belong in the release validation record; partial or earlier runs do not prove final-byte success.

The review account already had the manager installed, and the lifecycle guard correctly refused to alter it. CI runs the actual synthetic and checksum-verified 1.3.2 upgrades in a disposable Windows runner and retains its tested MSI. Local structural/mutation checks are not represented as a completed local lifecycle test.

Hosted Windows sessions exposed the taskbar API but denied manager activation with `E_ACCESSDENIED`. The integration probe reports only that exact activation failure as skipped; owned identities, request routing, and the launcher's bounded no-pin/no-browser state query still run. The real local shell checks passed on both hosts, and interactive pin acceptance remains a separate requirement. Layout assertions require no scrolling when there is room and a full-height, scrollable, reachable editor on shorter desktops; both-host 730-pixel tests and a deliberately undersized negative fixture verified this distinction.

The scripts/MSI/launchers remain unsigned. Code signing and publisher reputation require an appropriate signing identity and distribution process; checksum files alone are not publisher authentication. Protected App Kits remain experimental pending independent cryptographic review. A multi-model source review does not satisfy that requirement.

Remaining target-machine checks include physical accessibility and screen readers, mixed-DPI multi-monitor placement, visible 4K input latency/GPU behavior, managed Edge/Windows policies, non-English shell prompts, site sign-in/SSO, ARM64, cloud/network storage behavior, and cross-computer handover. Automatic icon retrieval remains dependent on site access policy. Native taskbar pinning remains dependent on Windows approval, capability, foreground rules, and cached shell state.