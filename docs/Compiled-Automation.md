# Compiled CLI and Build Commands

The compiled `eea.exe` is a new automation interface. Existing PowerShell parameters are not silently reinterpreted; the [original automation guide](Automation.md) and PowerShell entry point remain available. This is an unsigned preview with the [acceptance limits](Compiled-Preview.md) described separately.

## CLI Contract

[Program.cs](../src/EasyEdgeApps.Cli/Program.cs) is the dispatcher. Commands and option names are case-sensitive. Unknown/duplicate options, missing values, and combined `--preview --yes` are rejected. JSON is written to stdout for data commands; help/version are text and errors go to stderr.

| Exit | Meaning |
| --- | --- |
| 0 | Success; inspect per-app results where supplied. |
| 2 | Cancelled; any already completed per-app changes remain. |
| 3 | Invalid input, conflict, stale approval, or blocked operation. |
| 4 | Runtime failure with a safe message. |

`help`, `--help`, `-h`, `-?`, or no arguments show help. `--version` prints the preview version. The name `version` is not a command. `--isolated-root DIRECTORY` redirects Data/Desktop/Programs/Legacy roots and disables actual browser launch, website icon requests, taskbar pin requests, and live update checks. For this development work, keep that directory inside repository artifacts. Isolation is test routing, not an OS sandbox for arbitrary input paths.

| Command | Required and useful options | Effect |
| --- | --- | --- |
| `list` | none | Active validated definitions, including permanent IDs. |
| `save` | `--file DEFINITION` or `--name NAME`, plus `--preview` or `--yes`; named input accepts `--url`, `--notes`, `--edge-profile`, profile/session/window choices, placement booleans, and `--taskbar true/false`; either input accepts `--icon IMAGE`, `--fetch-icon`, or `--reset-icon`, plus `--launch` | Existing named saves preserve omitted local choices and permanent identity. New sites require a full URL. Network access is explicit through `--fetch-icon`. Isolated network/save-and-launch requests are rejected before writes. |
| `rename` | `--id ID --name NAME`, then `--preview` or `--yes` | Preserve ID/profile/launcher/shortcut filenames while changing display name. |
| `remove` | `--id ID` or `--name NAME`, then `--preview` or `--yes` | Remove proven owned managed files; retain browser data and unrelated files. Does not unpin. |
| `check` | optional `--id ID`, `--name NAME`, or `--app-names JSON_ARRAY` | Read-only hash, icon, configuration, shortcut metadata, current Edge path, and launcher-template inspection: Healthy, Repairable, Blocked, or Conflict. Unfiltered checks also report unclaimed successor app folders and missing runtime with an empty catalog. No browser is launched. |
| `repair` | `--id ID`, `--name NAME`, or `--app-names JSON_ARRAY`, then `--preview` or `--yes` | Check/rebuild eligible owned artifacts. A missing custom icon requires an explicit replacement through save. |
| `launch` | `--id ID` or `--name NAME`, then `--preview` or `--yes` | Inspect or start the owned launcher. Actual launch is blocked in isolated mode. |
| `pin` | `--id ID` or `--name NAME`, then `--preview` or `--yes` | Validate the owned Taskbar/Start/dedicated-profile configuration and request Windows approval. Actual requests are blocked in isolated mode. Existing pins are retained. |
| `kit-preview` | `--file KIT`; optional `--app-names JSON_ARRAY` | Return selected rows and approval fingerprint; any selected conflict returns exit 3. The entire input kit is still validated. |
| `kit-import` | `--file KIT --approval FINGERPRINT --yes`; optional `--app-names JSON_ARRAY` | Re-preview approved selection/destination/default-profile state. Inspect per-app results for partial success. |
| `kit-export` | `--output FILE`; optional `--name TITLE --notes TEXT --id ID --app-names JSON_ARRAY --encrypted --force` | Export all active sites or an explicit selection. Existing output requires `--force`; ID and name-array selectors cannot be combined. |
| `profiles` | none | Read-only local profile discovery. Isolated mode uses synthetic `Data/EdgeProfiles`. |
| `favorites-preview` | optional `--file BOOKMARKS` or `--edge-profile PROFILE`, `--app-names JSON_ARRAY` | Read Favorites-bar candidates, including disabled HTTP/duplicate rows. Omitted source uses the saved default or one unambiguous discovered profile. |
| `favorites-kit` | source options above, `--output FILE`; optional `--app-names`, `--desktop true/false`, `--start-menu true/false`, `--force` | Write selected available HTTPS candidates as a kit. |
| `favorites-import` | source/selection/placement options above, `--preview` or `--approval FINGERPRINT --yes` | Direct new-only Favorites import. The approval binds mode, selected kit contents, destination and effective defaults. A changed selected source or a concurrent name/URL match cannot overwrite an existing website. |
| `migration-list` | none | Inspect legacy candidates. |
| `migration-preview` | `--id ID` | Read-only handoff proposal and fingerprint. |
| `migrate` | `--id ID --approval FINGERPRINT --yes` | Isolated synthetic handoff only; live roots are rejected. |
| `rollback-migration` | `--id ID --yes` | Ownership-checked isolated restore only; live roots are rejected. |
| `recovery-list` | none | List transaction directory names, not a diagnosis that every directory is pending. |
| `recover` | `--transaction GUID --yes` | Validate and recover one transaction without force-overwriting changed files. |
| `support` | optional `--output NEWFILE --yes` | Print allowlisted report, or explicitly write it to a new file. No upload. |
| `settings` | optional `--file PREFERENCES` plus `--preview` or `--yes` | Read, validate, or save preferences. |
| `clear-logs` | `--yes` | Clear only the owned category logs. |
| `check-updates` | none | Credential-free official release lookup; blocked in isolated mode. |
| `verify-publisher` | `--file ARTIFACT --publisher THUMBPRINT` | Require the expected Authenticode signer/timestamp. An unsigned file must fail. |
| `stage-update` | `--file ZIP --publisher THUMBPRINT --current-version VERSION --yes` | Authenticate and stage an exact indexed package. Does not activate or install it. |
| `portable-preview` | `--file STAGED_JSON --directory CURRENT --publisher THUMBPRINT` | Revalidate both indexed versions/publisher and return an immutable plan. No deployment writes. |
| `portable-activate` | `--file APPROVED_PLAN_JSON --publisher THUMBPRINT --yes` | Revalidate and activate a stopped deployment, retaining the previous tree and receipt beside it. |
| `portable-rollback` | `--directory CURRENT --receipt RECEIPT_JSON --publisher THUMBPRINT --yes` | Restore the verified previous tree and retain the newer tree. Outside modifications block rollback. |
| `portable-recover` | same options as rollback | Reconcile an interrupted transition using the owned receipt and verified actual directory state. |

`--app-names` is a bounded JSON array such as `'["Mail","Work, Portal"]'`, with 1-100 distinct normalized names. It avoids ambiguous comma splitting. Named save accepts `--profile-mode Dedicated|Shared`, `--session-mode Fresh|Normal`, `--launch-mode RememberLast|Maximized|FullScreen`, and explicit true/false values for `--always-on-top`, `--desktop`, `--start-menu`, and `--taskbar`. Omitting these on an existing named site preserves them. An explicit empty normal-profile string clears that selection. Historical aliases resolve the same permanent identity, not a new website.

Selecting Taskbar supplies Start and Dedicated when those choices are omitted; explicit incompatible choices fail validation. Saving a Taskbar website requests Windows approval after the save commits. Pin failure does not undo a successful save, and clearing Taskbar does not remove existing pins or clear the retained Start/Dedicated choices. The standalone `pin` command reports the actual helper outcome; a successful command is not by itself proof that Windows approved a pin.

Icon choices are mutually exclusive. Preview does not fetch or decode an image. Apply runs the bounded image worker before saving. Website discovery tries later candidates when an image fails validation and retains the resolved website address. Explicit reset selects a generated icon; omitting icon options retains the saved choice.

Portable maintenance must execute from a separate trusted helper directory, with target programs closed. Required staged/plan/receipt fields and types are checked before publisher inspection. Current, staged, receipt and input-record paths must remain within the fixture root in isolated mode; lexical confinement precedes filesystem inspection. Both indexed versions require real expected-publisher verification; the unsigned preview cannot exercise a positive authenticated activation. Interrupted recovery and rollback have synthetic filesystem/mock-publisher coverage, not installed-product or sudden-power-loss acceptance. No automatic previous-version pruning occurs.

Favorites names reserve active and retired names/aliases, existing Desktop/Start paths and legacy name-hash folders, including empty folders. No existing directory is adopted. Native `check` does not inspect account sign-in, execute Edge, or consolidate legacy migration candidates. `migration-list` remains separate; support-report aggregate counts still use the lower-level owned-hash inspection.

The named save, selection, icon, taskbar, Favorites and maintenance commands are implemented. This is not a parameter-for-parameter replacement for the original PowerShell interface; its entry point remains supported.

Protected kits accept secrets only at a real local terminal with echo suppressed. Escape cancels. Passwords cannot be passed in arguments or redirected stdin. Enter secrets directly into the terminal, never through chat or an automation log. The interoperable encryption remains experimental pending independent audit.

## Synthetic Save and Rename

Run from the repository root in PowerShell 7 after [building the preview](Compiled-Preview.md#build-and-run-an-isolated-preview). This example writes only under repository artifacts and does not open Edge:

```powershell
$build = Get-Content .\artifacts\compiled-preview-local\build-result.json -Raw | ConvertFrom-Json
$cli = Join-Path $build.PortableDirectory 'eea.exe'
$root = Join-Path $PWD 'artifacts\cli-example'
[void][IO.Directory]::CreateDirectory($root)
$id = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
$definition = Join-Path $root 'definition.json'
@{
    Id = $id
    DisplayName = 'Synthetic Mail'
    Url = 'https://example.com/'
    Notes = 'Synthetic acceptance data only'
} | ConvertTo-Json | Set-Content -LiteralPath $definition -Encoding utf8

& $cli save --file $definition --preview --isolated-root $root
if ($LASTEXITCODE -ne 0) { throw 'Definition preview failed.' }
& $cli save --file $definition --yes --isolated-root $root
if ($LASTEXITCODE -ne 0) { throw 'Synthetic save failed.' }
& $cli rename --id $id --name 'Renamed Mail' --yes --isolated-root $root
if ($LASTEXITCODE -ne 0) { throw 'Synthetic rename failed.' }
& $cli list --isolated-root $root
& $cli launch --id $id --preview --isolated-root $root
```

Schema defaults make new websites Dedicated/RememberLast with Desktop and Start, not shared-profile sites. Names and addresses are stored in clear text; do not put secret links, passwords, or recovery codes into definitions or helper notes. A custom icon can be supplied with `--icon` and is converted by the bounded worker.

## Kit Approval

Exports create a new file unless `--force` explicitly authorizes replacement. The shared export-path guard rejects the source Bookmarks path, successor/legacy managed roots, shortcut destinations, unsafe paths, and trailing-dot/space aliases even with `--force`. This is not proof against every hardlink or concurrent filesystem substitution. A reviewed fingerprint binds the kit, selection, destination state and relevant default profile, not just a list of names:

```powershell
$kit = Join-Path $root 'synthetic.eeakit.json'
& $cli kit-export --id $id --name 'Synthetic kit' --output $kit --isolated-root $root
if ($LASTEXITCODE -ne 0) { throw 'Export failed.' }
$previewJson = & $cli kit-preview --file $kit --isolated-root $root
if ($LASTEXITCODE -ne 0) { throw 'Resolve the preview conflicts before importing.' }
$plan = $previewJson | ConvertFrom-Json
$plan.Rows | Format-Table
& $cli kit-import --file $kit --approval $plan.Fingerprint --yes --isolated-root $root
if ($LASTEXITCODE -ne 0) { throw 'Inspect the import results; completed apps may remain.' }
```

Do not reuse a fingerprint after files, definitions, or the kit change. Schema 1 preserves existing Fresh choice; schema 2 applies its explicit/default-false Fresh choice while preserving destination-local profile/window/taskbar settings. A resulting FullScreen/topmost ownership conflict must block the selected batch before writes.

Matching imports rebuild missing owned Desktop, Start, launcher, configuration and generated-icon files. Missing custom icons still require an explicit replacement. Occupied unowned shortcut destinations are checked before the selected batch writes and again under the writer lease. Ordinary kit imports may update approved matches; Favorites approvals are new-only and cannot be switched to ordinary import without invalidating the fingerprint.

## Build Inputs and Maintenance

[Build-Compiled.ps1](../tools/Build-Compiled.ps1) is the supported full build path. Directly compiling the manager from a clean tree first requires generated original-brand assets and the prebuilt website launcher; the wrapper supplies both. NuGet lockfiles are checked in, while bin/obj/generated artifacts are excluded. Restore can write ordinary tool caches; synthetic application data and build outputs remain in repository artifacts.

Use the [acceptance commands](Compiled-Acceptance.md) for full tests and actual published UI. Avoid combining native commands without checking each `$LASTEXITCODE`. For a PowerShell script call, check `$?` or its terminating error, not a stale native exit code. No command in this guide authorizes publication, an MSI installation, real-profile changes, or a taskbar pin.