# App Kit Format

This is the version 1 App Kit contract introduced in Easy Edge Apps 1.1.0. Runtime delivery remains one PowerShell script with only Windows/.NET dependencies. The same portable data works in Windows PowerShell 5.1 and PowerShell 7 on Windows. Encrypted exports remain experimental and require independent security review before production use.

## Standard payload

A standard kit is a UTF-8 JSON object. A leading UTF-8 BOM is accepted for files; writers emit no BOM. The filename for exports ends in `.eeakit.json` and has a valid 1-to-60-character name before that suffix. Examples below are synthetic, not private data.

```json
{
  "Product": "EasyEdgeApps.AppKit",
  "SchemaVersion": 1,
  "Name": "Family websites",
  "Notes": "Plain-text kit notes.",
  "Apps": [
    {
      "Name": "My News",
      "Url": "https://example.com/news?view=large#/home",
      "Desktop": true,
      "StartMenu": true,
      "Notes": "Plain-text app notes.",
      "Icon": { "Kind": "Generated", "Version": 1 }
    }
  ]
}
```

Required kit fields are `Product`, `SchemaVersion`, `Name`, and `Apps`. Required app fields are `Name`, `Url`, `Desktop`, `StartMenu`, and `Icon`. `Notes` is the only optional field at either level and defaults to an empty string. Field names, product markers, and enum values are case-sensitive. Unknown fields, duplicate JSON fields (including case-only variants), and type metadata are rejected. There are no imported paths or commands.

| Field | Validation |
| --- | --- |
| Product | Exact string `EasyEdgeApps.AppKit` |
| SchemaVersion | Integer `1`, not a string, Boolean, or decimal value |
| Name | String, trimmed and normalized to Unicode Form C; 1 to 60 UTF-16 code units; safe Windows shortcut name, no hidden controls, path separators, reserved device names, or trailing dot |
| Apps | JSON array with 1 to 100 app objects; unique case-insensitive, normalized name identities |
| Url | String containing an absolute, well-formed HTTPS address; no embedded credentials, whitespace/control/format characters, quotes, or backslashes; original and canonical address at most 2048 characters |
| Desktop, StartMenu | Actual JSON Booleans; at least one true |
| Notes | Plain string, at most 4000 UTF-16 code units; hidden controls/format characters rejected; CR, LF, and TAB allowed; never executed or rendered as markup |

URL hosts are canonicalized with `Uri`/`UriBuilder` and IDN ASCII host representation. Query strings and fragments are preserved subject to normal URI canonicalization. Exact canonical URL equality determines Favorites duplicates; app identity remains based on the normalized name. Kit notes are shown during import but are not a separate persisted kit catalog. App notes are saved with each installed app.

Payload JSON files and compact canonical payloads are limited to 16 MiB. JSON reading uses the bounded .NET JSON reader, preserving strings such as date-looking notes rather than coercing them into runtime dates. App Kit nesting is limited to 16 reader levels and 4096 values, counted in a streaming pass before constructing objects. Edge metadata uses separate limits of 256 reader levels and 250,000 values; Favorites traversal additionally limits the bar to 10,000 entries/folders and 64 levels. Malformed UTF-8, trailing commas, comments, duplicate fields, and unsupported scalar values are rejected before domain validation.

## Portable icons

Automatic icons use exactly:

```json
{ "Kind": "Generated", "Version": 1 }
```

This requests the local version 1 letter-icon generator using the app name. Native font/rasterization differences can affect pixels between machines; the metadata is portable, not a promise of identical rendered bytes.

Custom icons use exactly:

```json
{ "Kind": "Embedded", "Data": "<canonical standard Base64 ICO bytes>", "Sha256": "<64 lowercase hexadecimal characters>" }
```

`Data` must decode to an ICO file between 22 bytes and 1 MiB. The encoded length is bounded before decoding. Base64 uses the standard alphabet and required padding; whitespace, noncanonical encodings, or invalid lengths are rejected. SHA-256 must match decoded bytes. The validator checks the ICO directory, 1 to 32 frames, bounded offsets/lengths, dimensions up to 256 pixels, and supported PNG IHDR or DIB headers. It then decodes and draws with the host's native icon library in memory. An icon the host cannot decode is rejected; historical PNG-only icons may differ in .NET Framework compatibility. Keep Windows and .NET patched when importing untrusted media.

Icons are embedded data, never paths or download instructions. The total compact payload still must fit 16 MiB. Legacy app records lacking `IconKind` are treated conservatively as custom for export and require their verified local icon bytes.

## Encrypted envelope

The encrypted file is UTF-8 JSON up to 24 MiB with exactly these fields. All strings below have exact case. Numeric fields must be integers.

```json
{
  "Product": "EasyEdgeApps.EncryptedKit",
  "SchemaVersion": 1,
  "Algorithm": "A256CBC-HS512",
  "Kdf": "PBKDF2-HMAC-SHA256",
  "Iterations": 600000,
  "Salt": "<canonical Base64 of 16 random bytes>",
  "Iv": "<canonical Base64 of 16 random bytes>",
  "Ciphertext": "<canonical Base64 of ciphertext>",
  "Tag": "<canonical Base64 of 32 authentication bytes>"
}
```

Only this version, algorithm, and KDF are supported. Import accepts 600,000 through 1,200,000 iterations, inclusive; export emits 600,000. Reject invalid versions, types, bounds, Base64 lengths, salt/IV/tag lengths, and ciphertext block alignment **before** key derivation. Ciphertext is at least 16 bytes and at most 16 MiB plus 16 bytes, divisible by 16. It encrypts the entire compact UTF-8 standard payload with no BOM, including all names, notes, placements, URLs, and icons.

### Password and key derivation

1. New export passwords and confirmation are supplied as `SecureString`, with 12 to 1024 UTF-16 code units. Unlock accepts 1 to 1024 to permit exact matching without imposing a new strength rule on an existing file. No trimming or Unicode normalization is applied.
2. Encode the exact password as strict UTF-8, rejecting invalid surrogate input. Use a new cryptographically random 16-byte salt for every export.
3. Derive 64 bytes with PBKDF2-HMAC-SHA256 using the envelope's bounded iteration count.
4. Following RFC 7518 section 5.2.5, the first 32 derived bytes are the HMAC key and the final 32 are the AES-256 key. This is the RFC's combined key layout, not key reuse between algorithms.
5. Generate a fresh cryptographically random 16-byte IV. Encrypt with platform AES in CBC mode and PKCS#7 padding.

The salt and IV are independently filled by `RandomNumberGenerator`. The password is not a stored key, and the format does not depend on DPAPI, an account, or a machine. Windows PowerShell 5.1 does not expose `AesGcm`; the standard A256CBC-HS512 construction is deliberately used in both hosts for interoperability.

### Authenticated bytes

Associated data `A` is ASCII for these six lines joined by a single LF byte (`0A`), with **no trailing LF**, BOM, spaces, or CR bytes:

```text
EasyEdgeApps.EncryptedKit
1
A256CBC-HS512
PBKDF2-HMAC-SHA256
600000
<canonical Base64 salt>
```

The fifth line is the actual iteration count, rendered in invariant decimal without grouping or leading zeros. The final line is the exact validated canonical Base64 salt. All permitted values are ASCII, so delimiters are unambiguous. JSON field order, indentation, and whitespace are not authenticated; the validated semantic metadata is.

Let `AL` be an unsigned 64-bit, big-endian encoding of the bit length of `A`. The tag is:

```text
first 32 bytes of HMAC-SHA512(macKey, A || IV || ciphertext || AL)
```

Here `IV` and `ciphertext` are raw bytes, not their Base64 strings. This follows RFC 7518's A256CBC-HS512 authentication construction. The algorithm/version/KDF/iteration/salt header, IV, ciphertext, and associated-data length are all authenticated.

On unlock, derive the key, compute the expected tag, and compare all 32 bytes before AES decryption. The embedded comparison helper requires fixed lengths, accumulates XOR differences without early mismatch return, and uses `NoInlining`/`NoOptimization` attributes. Its runtime constant-time assumptions remain an independent-review concern. A wrong password or authentication/decryption failure reports `Incorrect password or damaged kit.` Unsupported formats and malformed bounds have separate input-validation errors.

Only after successful authentication and decryption does the tool parse the UTF-8 JSON and run the complete standard-kit validation. Valid encryption is not permission to trust commands, paths, malformed icons, or unsafe URLs.

## Files and installation

Export computes the selected representation in memory and stages only that representation beside the destination. A protected export never stages the readable payload. A new destination uses no-overwrite movement; replacement requires explicit approval, a checked prior-file hash, and the existing same-directory atomic replacement helper. Failure attempts cleanup of only the created staging file. Exceptional filesystem failures can still prevent cleanup.

Unlocking creates no decrypted kit file. After approval, installation intentionally writes ordinary cleartext app settings and direct `.lnk` shortcuts through the existing owned-file transaction path. Secrets are never appropriate in URLs or notes. There is no password storage, plaintext fallback, auto-login, or website probing.

Imports do not remove apps absent from a kit. Identical normalized app definitions with healthy owned files are unchanged. Each selected batch is fully validated and preflighted, then rechecked under the current-user/current-session mutex. Each app has staged writes and caught-error rollback; earlier successful apps remain after a later failure. Recovery, cross-session races, and power-loss limitations are unchanged.

## References and review

- [RFC 7518 section 5.2, especially 5.2.5](https://www.rfc-editor.org/rfc/rfc7518.html#section-5.2): authenticated AES-CBC/HMAC construction and A256CBC-HS512 parameters.
- [RFC 7518 Appendix B.3](https://www.rfc-editor.org/rfc/rfc7518.html#appendix-B.3): the exact known-answer ciphertext and tag exercised in both hosts.
- [OWASP Cryptographic Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html): authenticated encryption, key separation, randomness, and encrypt-then-MAC when an authenticated mode is unavailable.
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html): PBKDF2-HMAC-SHA256 work-factor guidance. This implementation uses 600,000 iterations; review future recommendations before changing format bounds.
- [.NET Rfc2898DeriveBytes](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rfc2898derivebytes): platform byte-password/hash-selecting PBKDF2 implementation.
- [.NET CryptographicOperations.FixedTimeEquals](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.cryptographicoperations.fixedtimeequals): comparison considerations; the API is unavailable in the supported .NET Framework host, so a small fixed-length helper is included.
- [.NET JsonReaderWriterFactory](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.serialization.json.jsonreaderwriterfactory): bounded platform JSON reader used without data-contract object instantiation.

The tests include authenticated metadata and ciphertext tampering, wrong passwords, unsupported limits and formats, malformed authenticated plaintext, custom-icon transfers, failure-safe replacement, encrypted-only staging, and real bidirectional encrypted file transfers between the two PowerShell hosts. This is not a third-party audit. Review crypto composition, parser/media handling, bounds, memory behavior, and filesystem races independently. Physical accessibility, real-site sign-in, and real cross-machine/redirected-folder acceptance remain necessary.