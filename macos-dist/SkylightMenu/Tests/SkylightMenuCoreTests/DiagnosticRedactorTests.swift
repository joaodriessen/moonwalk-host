import Testing
@testable import SkylightMenuCore

@Test func redactsSecretsAndIdentifiersButKeepsUsefulFacts() {
    let input = """
    version=0.4.0-alpha.1 build=42 arch=arm64
    Authorization: Bearer secret-token-value
    pin=1234 username=alice client_name=Living Room Mac uuid=550e8400-e29b-41d4-a716-446655440000
    home=/Users/example/Library/Application Support/Skylight
    ipv4=192.168.1.42 ipv6=2001:db8::1 mac=aa:bb:cc:dd:ee:ff
    -----BEGIN PRIVATE KEY-----
    secret-key-material
    -----END PRIVATE KEY-----
    """
    let output = DiagnosticRedactor.redact(input)
    for secret in ["secret-token-value", "1234", "alice", "Living Room Mac", "550e8400", "example", "192.168.1.42", "2001:db8::1", "aa:bb:cc:dd:ee:ff", "secret-key-material"] {
        #expect(!output.contains(secret))
    }
    #expect(output.contains("version=0.4.0-alpha.1"))
    #expect(output.contains("arch=arm64"))
    #expect(output.contains("pin="))
}

@Test func redactionIsIdempotent() {
    let once = DiagnosticRedactor.redact("token=top-secret ip=10.0.0.4")
    #expect(DiagnosticRedactor.redact(once) == once)
}

@Test func omitsRequestValuesAndSettingValuesFromOlderLogs() {
    let input = """
    [00:05:09]: Debug: authorization -- Basic example-creds
    [00:05:09]: Debug: file -- sensitive-document.txt
    x-session-token -- generated-test-token
    Authorization: Basic basic-example
    [00:05:09]: Info: config: 'sunshine_name' = Private Room
    [00:05:10]: Info: session 1280x720 @ 60 fps
    """
    let output = DiagnosticRedactor.redact(input)
    for value in ["example-creds", "sensitive-document", "generated-test-token", "basic-example", "Private Room"] {
        #expect(!output.contains(value))
    }
    #expect(output.contains("sunshine_name"))
    #expect(output.contains("1280x720 @ 60 fps"))
}

@Test func removesCompressedAndScopedAddressesWithoutChangingTimings() {
    let input = """
    Connect [fe80::abcd%en0]:47984 ff02::fb 2001:db8:: ::ffff:192.0.2.7 ::1
    Last address was fe80::def0.
    Measured 12.5 ms at 12:34:56
    """
    let output = DiagnosticRedactor.redact(input)
    for address in ["fe80", "en0", "ff02", "2001:db8", "::ffff", "192.0.2.7", "::1"] {
        #expect(!output.contains(address))
    }
    #expect(output.contains("[REDACTED_IP]:47984"))
    #expect(output.contains("[REDACTED_IP]."))
    #expect(output.contains("12.5 ms at 12:34:56"))
    #expect(DiagnosticRedactor.redact(output) == output)
}

@Test func removesPartialCertificatesAndOlderRequestUrls() {
    let first = """
    response remainder
    -----END CERTIFICATE-----
    Request https://example:example-credentials@host.invalid:47984/pair?token=example-token
    -----BEGIN PRIVATE KEY-----
    incomplete fixture
    """
    let output = DiagnosticRedactor.redact(first)
    for value in ["response remainder", "example-credentials", "example-token", "incomplete fixture"] {
        #expect(!output.contains(value))
    }
    #expect(output.contains("host.invalid:47984/pair"))
}
