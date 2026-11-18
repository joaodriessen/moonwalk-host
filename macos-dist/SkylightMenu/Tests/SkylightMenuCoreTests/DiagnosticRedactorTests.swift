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
