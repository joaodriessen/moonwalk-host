import Foundation

public enum DiagnosticRedactor {
    public static func redact(_ input: String) -> String {
        var output = input
        let replacements: [(String, String)] = [
            (#"(?s)-----BEGIN [^-]+-----.*?-----END [^-]+-----"#, "[REDACTED_PEM]"),
            (#"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#, "$1[REDACTED_TOKEN]"),
            (#"(?i)\b(token|password|passwd|pin|username)\s*=\s*[^\s]+"#, "$1=[REDACTED]"),
            (#"(?i)\b(client_name|device_name)\s*=\s*[^\r\n]+"#, "$1=[REDACTED_NAME]"),
            (#"(?i)\buuid\s*=\s*[0-9a-f-]{16,}"#, "uuid=[REDACTED_UUID]"),
            (#"/Users/[^/\s]+"#, "/Users/[REDACTED_USER]"),
            (#"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"#, "[REDACTED_MAC]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[REDACTED_IP]"),
            (#"\b(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F:]{1,}\b"#, "[REDACTED_IP]"),
        ]
        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return output
    }
}
