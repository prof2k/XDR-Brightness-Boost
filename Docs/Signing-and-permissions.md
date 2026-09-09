# Local updates and brightness-key permissions

On 2026-09-09, the installed 0.7.13 build reported `Signature=adhoc` and a
designated requirement containing only its code hash. This explains why
rebuilding could invalidate the existing permission entry despite using
the same bundle identifier and application path.

Apple documents that ad-hoc code identity is tied to that particular code
version, while updates should satisfy a consistent designated requirement:
[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/).

Version 0.7.14 restores the existing local development certificate. The
machine's certificate choice is stored in `.local-signing-identity`, which
is ignored and excluded from source archives. It contains only the
certificate identifier, never a private key. `XDR_CODESIGN_IDENTITY` remains
an explicit per-build override. Without either setting, source validation
can build ad-hoc, but the installer refuses to install that bundle.

The installer checks both code integrity and identity before quitting the
installed app or staging its replacement. Once an installed app has a
certificate-backed identity, its replacement must satisfy that app's
designated requirement. Switching back to ad-hoc or a different identity
fails installation. The one-time migration from ad-hoc to certificate
signing is allowed and reports that macOS may require renewed approval.

Validation: `python3 Tests/SigningIdentityTests.py` signs two disposable
fixture versions with the configured certificate and checks update
compatibility. It also checks ad-hoc migration, rejects an ad-hoc update,
and rejects a different app identity. These tests use the real `codesign`
requirement evaluator; they do not grant or reset macOS privacy permissions.

The installed 0.7.14 app passed signature/hash verification. Its key-capture
log initially reported `session tap=false`. The user must approve the
corrected installed app through macOS Settings; successful certificate
verification alone does not demonstrate working key capture. No TCC
database edits, permission resets, or automatic permission grants were made.

Follow-up: 0.7.15 passed the installed 0.7.14 designated requirement, with
identical certificate-backed requirements verified before replacement.
The 0.7.15 startup log reported `session tap=true`, also reflected by the
enabled key-control switch in the live settings UI. The new "Keys can
enable boost" preference and its description were visually checked in
that installed UI. Physical brightness-key behavior still needs user
confirmation; the policy tests cover both preference modes.

Local signing is not Developer ID distribution or notarization. Migrating
to a future distribution certificate needs an explicit identity plan and
permission-retention testing.
