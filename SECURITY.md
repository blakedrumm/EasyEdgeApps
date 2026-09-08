# Security

## Supported releases

Security fixes target the latest published release. Keep Windows and Microsoft Edge updated separately.

## Report a concern

Use this repository's private vulnerability reporting under the **Security** tab for vulnerabilities. Use public issues only for reports that contain no private or security-sensitive details.

Do not include credentials, tokens, personal website addresses, account screenshots, Edge bookmark files, App Kits (even encrypted), passwords, or unredacted app settings and transaction journals. Reproduce issues with `https://example.com/` and a temporary test directory where possible.

## Trust model

- Only run a reviewed copy obtained from the official repository or its releases. The PowerShell script is unsigned.
- Installation is current-user only and intentionally requires no administrator elevation.
- HTTPS is preferred; explicit HTTP destinations are supported and unencrypted. Passwords and browser flags cannot be supplied as launch options.
- No remote code or dependencies are downloaded by setup. Website icon retrieval and scheme resolution, introduced in version 1.2.0, contact submitted destinations only after an explicit command. SVG rendering dependencies and their license notices are embedded.
- URLs are stored locally, including any query strings or fragments. Never configure a URL containing a secret.
- Saved metadata is validated; persistent paths do not control writes or deletion. Existing artifacts are checked before replacement or removal.
- Ownership checks are accident-prevention measures, not a sandbox against another process running as the same user, an administrator, or a compromised browser.
- Browser security, profile selection, cookies, and credentials remain in Edge's control. An app window is not kiosk isolation.
- Multi-file changes support caught-error rollback, not guaranteed power-failure atomicity. Preserve recovery files when setup requests help.

## Website icon retrieval

**Get icon** sends GET requests to the submitted website and its declared icon or redirect destinations. It uses normal certificate validation, no browser session, no cookies, no default Windows or proxy credentials, and no authorization or referrer header. There is no third-party favicon lookup service. Hosts and system proxies can still observe these requests; the requested path and query are sent to their destination. Use trusted sites and never enter addresses containing secrets. A website can direct requests to other hosts reachable from this computer; icon lookup is not a network-isolation boundary.

For a setup address without a scheme, **Get icon** and **Add website** or **Save changes** first issue a credential-free HEAD request to HTTPS. Any received HTTPS response, even an HTTP error status, keeps HTTPS. Connection failure can fall back to HTTP; certificate or TLS authentication failure does not. Explicit schemes are preserved without probing. HTTPS icon links and redirects never downgrade to HTTP. HTTP fallback is shown in the editor and direct GUI saves require confirmation. An active network attacker can cause connection failure, so automatic fallback is not proof of HTTP safety. Do not send passwords or sensitive information to HTTP sites. CLI operations and kits require explicit schemes, do not probe, and rely on the caller's approval of those destinations. Favorites import stays HTTPS-only.

Nothing is requested automatically while typing, starting setup, checking apps, or importing a kit. HTML discovery reads at most a 512 KiB prefix; it does not reject a page solely because the complete page is larger. Image downloads have no fixed byte-size cutoff. Streamed and decompressed bytes go to a uniquely named, exclusive temporary file opened with `DeleteOnClose`, then are resized into a small icon. Disk capacity and native decoder resources can still be exhausted by a hostile or excessively large response. Temporary image files are not encrypted, and the application's same-user filesystem trust boundary still applies.

Scheme probes have a 5-second cancellation deadline, HTML requests 8 seconds, and image transfers 60 seconds, within a 90-second lookup cancellation budget. Fetched resources allow at most three redirects without embedded credentials. Cancellation is cooperative; synchronous image decoding is not a forcibly terminated sandbox. Pending work runs outside the UI thread, with an activity spinner and cancellation control. Closing the download stream deletes its temporary file on success, conversion failure, or cancellation.

Windows imaging downscales raster sources; supported static SVG graphics are rendered with embedded SVG.NET 3.4.8 and ExCSS 4.2.3. XML DTDs and entity resolution are prohibited. SVG validation allowlists static shapes, paths, groups, gradients, and their attributes; rejects scripts, CSS, external resources, image/use elements, and event handlers; and permits only local nonrecursive gradient references. Geometry is limited to 4096 elements, depth 32, 64 attributes per element, 262144 characters per attribute, and 1048576 total attribute characters. Original download size and declared image dimensions are not the stored-icon limits. See [Third-Party Notices](THIRD-PARTY-NOTICES.md) for dependency licenses.

Output is an aspect-preserving, transparent 128-pixel Windows bitmap ICO, validated again before preview and installation. Native and bundled image parsers remain attack surfaces, so keep Windows/.NET and the application updated. Saved app files change only on explicit save. Cancellation, failure, or a changed editor discards pending results without replacing the saved icon; a pending save is not resumed if the user changed its fields during resolution. The image becomes an ordinary custom icon in settings and App Kits; there is no automatic refresh or saved remote-icon dependency.

## App Kit boundaries

Kits are versioned, bounded, data-only JSON. Exact allowlisted fields and types, normalized unique names, explicit HTTPS or HTTP URLs, placement flags, helper notes, and bounded decoded icons are validated before installation. Imported paths and commands are never accepted. Existing files must pass the original ownership and safe-path checks. Read-only Edge discovery does not migrate history, cookies, saved passwords, or credentials.

Read-only previews and Check Apps do not test websites or make repairs. Application needs separate approval. A fresh snapshot is checked before applying an approved import or repair. Conflicting or modified files and pending recovery fail closed. The current-user/current-session mutex serializes cooperating changes in that session, not other sessions or hostile processes. Multiple apps are not a single atomic transaction; earlier successful apps remain after a later failure.

For command-line automation, `-Unattended` explicitly approves the requested operation, including destination changes in a trusted kit. It suppresses confirmation and setup dialogs, not validation or ownership protections. It does not implicitly authorize replacing an export file. Review inputs before unattended use and use `-Preview` or `-WhatIf` for dry runs. An automation caller can load a `SecureString` from its own secret store; the tool does not load or persist that store. Caller-managed Windows DPAPI password files are account/computer-bound and are separate from portable App Kits.

## Encrypted exports

**Independent security review is required before production use.** Tests and published standard vectors are evidence of interoperability and regression coverage, not a cryptographic audit. The encrypted format was introduced in version 1.1.0 and remains experimental pending independent review.

The entire App Kit payload is encrypted using platform primitives with RFC 7518 A256CBC-HS512, a fresh random 16-byte salt and IV, and PBKDF2-HMAC-SHA256 at 600,000 iterations. Import bounds the KDF to 600,000 through 1,200,000 iterations before deriving keys. Windows PowerShell 5.1 lacks the modern `AesGcm` API, so this version uses the same documented CBC/HMAC authenticated construction in both hosts, not unauthenticated CBC or homegrown key mixing.

The MAC covers unambiguous version/algorithm/KDF/salt metadata, IV, ciphertext, and associated-data length. Authentication precedes decryption and any interpretation of plaintext. Tag comparison checks every byte in a fixed-length accumulator with no early mismatch exit. Only recognized versions/algorithms and exact input bounds are accepted. See [App Kit Format](docs/App-Kit-Format.md) for the byte-level contract and references.

Protected-export staging contains only the encrypted representation. Decrypted kits are held in memory and pass the same validation as standard kits; no plaintext decrypted-kit file is created. Incorrect-password, malformed-data, authentication, cancellation, and preflight failures do not install. Passwords are never cached between imports, saved in settings, or accepted as ordinary string parameters. There is no account-bound DPAPI portable format, recovery key, remote service, or plaintext fallback.

Limits that remain important:

- Password strength matters. An exported file permits offline guessing; the KDF is not a substitute for a strong unique passphrase. At least 12 and at most 1024 UTF-16 code units are required for new export passwords. Share passwords separately and preserve them securely; lost passwords cannot be recovered.
- Salt, IV, algorithm, KDF parameters, ciphertext size, and the filename are public. Use non-sensitive filenames.
- Authentication detects modification by someone without the password. It does not identify a sender, establish whether websites are trustworthy, or prevent a password holder from replacing kit content. Review old and new destinations, especially domain changes.
- GUI password text, serialized strings, runtime copies, previews, and returned objects exist in managed memory. Clearable buffers and unmanaged allocations are cleared where feasible, but perfect erasure, swap/crash-dump secrecy, or protection from a compromised same-user process is not promised.
- Installed URLs, notes, icons, shortcuts, rollback files, readable exports, and CLI output are not encrypted. Browser storage, sessions, websites, and network monitoring remain outside this protection. Never put credentials, tokens, reset links, or session secrets in configured URLs or helper notes.
- Atomic replacement depends on the destination filesystem. OneDrive synchronization, network filesystems, antivirus/file locks, cross-session changes, machine crashes, and power loss require target-machine checks. Staging cleanup is best-effort after exceptional filesystem failures; preserve recovery evidence.

Review should examine the crypto composition and metadata bytes, password encoding, parser and decoded-icon attack surface, bounds before expensive allocation/KDF work, constant-time comparison assumptions in supported runtimes, managed-memory exposure, and transaction race/failure behavior. Keep Windows, .NET, and Edge patched independently.