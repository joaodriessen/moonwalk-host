# Public test fixtures

`tests/unit/test_http_pairing.cpp` contains a complete private key so the pairing
tests can exercise deterministic challenges. It is a public test fixture, not a
credential to use for a real host or client.

On 12 November 2026, its PEM block was compared byte-for-byte with the fixture in
[Sunshine's pairing test](https://github.com/SunshineStream/Sunshine/blob/master/tests/unit/test_http_pairing.cpp).
The upstream file's Git blob was `142e3d59fac7b720b783da187448f0775a40c7a0`.
The SHA-256 of the block from `-----BEGIN PRIVATE KEY-----` through
`-----END PRIVATE KEY-----`, including internal newlines but no trailing newline, is:

```text
cb3c1dd0b7418aebd91109a35b867dfeb45e5be0db3499ba4ba69db7b42c500b
```

The local test file has other changes; the comparison covers the key block, not
whole-file identity. The diagnostic-redaction tests instead use deliberately
invalid placeholder key text to check that private material is removed.

When a secret scanner flags this fixture, verify the exact fingerprint and test
location. Do not suppress all private keys, entire test directories or new keys.
This provenance does not clear unrelated files, historical credentials or release
assets. Follow the [release review](releasing.md) and [security policy](../SECURITY.md).
