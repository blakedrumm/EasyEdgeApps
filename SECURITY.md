# Security

## Supported releases

Security fixes target the latest published release. Keep Windows and Microsoft Edge updated separately.

## Report a concern

Use this repository's private vulnerability reporting under the **Security** tab for vulnerabilities. Use public issues only for reports that contain no private or security-sensitive details.

Do not include credentials, tokens, personal website addresses, account screenshots, or unredacted app settings and transaction journals. Reproduce issues with `https://example.com/` and a temporary test directory where possible.

## Trust model

- Only run a reviewed copy obtained from the official repository or its releases. The PowerShell script is unsigned.
- Installation is current-user only and intentionally requires no administrator elevation.
- Only HTTPS URLs are accepted. Passwords and browser flags cannot be supplied as launch options.
- No remote code, external icons, or dependencies are downloaded by setup.
- URLs are stored locally, including any query strings or fragments. Never configure a URL containing a secret.
- Saved metadata is validated; persistent paths do not control writes or deletion. Existing artifacts are checked before replacement or removal.
- Ownership checks are accident-prevention measures, not a sandbox against another process running as the same user, an administrator, or a compromised browser.
- Browser security, profile selection, cookies, and credentials remain in Edge's control. An app window is not kiosk isolation.
- Multi-file changes support caught-error rollback, not guaranteed power-failure atomicity. Preserve recovery files when setup requests help.