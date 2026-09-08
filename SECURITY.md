# Security

## Supported releases

Security fixes target the latest published release. Keep Windows and Microsoft Edge updated separately.

## Report a concern

Use this repository's private vulnerability reporting under the **Security** tab for vulnerabilities. Use public issues only for reports that contain no private or security-sensitive details.

Do not include credentials, tokens, personal website addresses, account screenshots, Edge bookmark files, App Kits (even encrypted), passwords, or unredacted app settings and transaction journals. Reproduce issues with `https://example.com/` and a temporary test directory where possible.

## Trust model

- Only run a reviewed copy obtained from the official repository or its releases. The PowerShell script is unsigned.
- Installation is current-user only and intentionally requires no administrator elevation.
- Only HTTPS URLs are accepted. Passwords and browser flags cannot be supplied as launch options.
- No remote code or dependencies are downloaded by setup. Website icon retrieval, introduced in version 1.2.0, is an explicit, optional HTTPS operation.
- URLs are stored locally, including any query strings or fragments. Never configure a URL containing a secret.
- Saved metadata is validated; persistent paths do not control writes or deletion. Existing artifacts are checked before replacement or removal.
- Ownership checks are accident-prevention measures, not a sandbox against another process running as the same user, an administrator, or a compromised browser.
- Browser security, profile selection, cookies, and credentials remain in Edge's control. An app window is not kiosk isolation.
- Multi-file changes support caught-error rollback, not guaranteed power-failure atomicity. Preserve recovery files when setup requests help.

## Website icon retrieval

**Get icon** sends HTTPS GET requests to the typed website and its declared icon or redirect destinations. It uses normal certificate validation, no browser session, no cookies, no default Windows or proxy credentials, and no authorization or referrer header. There is no third-party favicon lookup service. Hosts and system proxies can still observe these requests; the requested path and query are sent to their destination. Use trusted sites and never enter addresses containing secrets. A website can direct requests to other HTTPS hosts reachable from this computer; icon lookup is not a network-isolation boundary.

Nothing is requested automatically while typing, starting setup, checking apps, or importing a kit. Network responses remain in memory. Page bodies are bounded to 512 KiB and icon bodies to 1 MiB, including streamed and decompressed data. Each resource allows at most three redirects and has an 8-second cancellation deadline within a 20-second overall lookup deadline. Redirects must remain HTTPS without embedded credentials. The HTML scan extracts bounded icon link metadata without a browser or script execution; unsupported SVG and other active formats are not decoded.

ICO directory dimensions and offsets, PNG dimensions (at most 1024 by 1024), and native image decoding are validated before converting to a bounded 128-pixel Windows bitmap icon. The existing ICO validator runs again before preview and installation. Native .NET image decoding remains an attack surface, so keep Windows and .NET patched. Downloaded bytes are not saved until the user explicitly adds or saves the website. Cancellation, failure, or a changed editor discards pending results without replacing the saved icon. The image becomes an ordinary custom icon in settings and App Kits; there is no automatic refresh or saved remote-icon dependency.

## App Kit boundaries

Kits are versioned, bounded, data-only JSON. Exact allowlisted fields and types, normalized unique names, HTTPS URLs, placement flags, helper notes, and bounded decoded icons are validated before installation. Imported paths and commands are never accepted. Existing files must pass the original ownership and safe-path checks. Read-only Edge discovery does not migrate history, cookies, saved passwords, or credentials.

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