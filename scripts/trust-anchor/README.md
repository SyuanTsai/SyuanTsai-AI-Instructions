# Trust-anchor key tools

These interactive tools generate, convert, and fingerprint the RSA public keys used by the Standard trust-anchor boundary. Run them only from a user-controlled terminal against a protected-main commit. Never run them in CI, an agent-controlled terminal, or a Git worktree.

- `New-TrustAnchorKeyPair.ps1` creates a 3072-bit RSA key, stores only encrypted PKCS#8 (AES-256-CBC, PBKDF2-SHA256, 600000 iterations), and writes canonical public XML.
- `ConvertTo-TrustAnchorPublicKeyXml.ps1` converts a `PUBLIC KEY` PEM to canonical XML.
- `Get-TrustAnchorFingerprint.ps1` reports canonical-XML and SPKI SHA-256 fingerprints for public XML, public PEM, or an encrypted private key.

Passwords are read interactively as `SecureString`; no command accepts a password, password file, or `SecureString` parameter. Private-key paths must be outside every Git worktree. Existing targets, symlink/reparse ancestors, hard-linked keys, non-owner keys, Unix modes broader than `0600`, and unsafe Windows DACLs are rejected.

The public key files and pinned hashes under `docs/standards/trust-anchors/` are deliberately not changed by these tools. Trust-anchor rotation is a separate approval-boundary change and may merge only after the user verifies its fingerprints with an independent tool.
