import Darwin
import Foundation

public enum DiagnosticRedactor {
    public static func redact(_ input: String) -> String {
        var output = input
        let replacements: [(String, String)] = [
            (#"(?s)-----BEGIN [^-]+-----.*?(?:-----END [^-]+-----|\z)"#, "[REDACTED_PEM]"),
            (#"(?s)\A.*?-----END [^-]+-----"#, "[REDACTED_PEM]"),
            (#"(?i)(\b[a-z][a-z0-9+.-]*://)[^/\s@]+@"#, "$1[REDACTED_TOKEN]@"),
            (#"(?i)(\b[a-z][a-z0-9+.-]*://[^\s"'<>?]+)\?[^\s"'<>]+"#, "$1 [REDACTED_QUERY]"),
            (#"(?i)(authorization\s*:\s*(?:basic|bearer)\s+)[^\s]+"#, "$1[REDACTED_TOKEN]"),
            (#"(?im)^((?:\[[^\r\n\]]+\]:\s*debug:\s*)?[a-z][a-z0-9_-]*\s+--\s+)[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?im)(\bconfig:\s*'[^'\r\n]+'\s*=\s*)[^\r\n]+"#, "$1[REDACTED]"),
            (#"(?i)\b(token|password|passwd|pin|username)\s*=\s*[^\s]+"#, "$1=[REDACTED]"),
            (#"(?i)\b(client_name|device_name)\s*=\s*[^\r\n]+"#, "$1=[REDACTED_NAME]"),
            (#"(?i)\buuid\s*=\s*[0-9a-f-]{16,}"#, "uuid=[REDACTED_UUID]"),
            (#"/Users/[^/\s]+"#, "/Users/[REDACTED_USER]"),
            (#"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"#, "[REDACTED_MAC]"),
        ]
        for (pattern, replacement) in replacements {
            output = output.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return redactIPv6(output).replacingOccurrences(
            of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "[REDACTED_IP]",
            options: .regularExpression
        )
    }

    private static let ipv6Candidates = try! NSRegularExpression(
        pattern: #"(?<![\w:])[a-fA-F0-9:]*:[a-fA-F0-9:.]+(?:%[\w.-]+)?(?![\w:])"#
    )

    private static func redactIPv6(_ text: String) -> String {
        let source = text as NSString
        let output = NSMutableString(string: text)
        let matches = ipv6Candidates.matches(in: text, range: NSRange(location: 0, length: source.length))
        // Validate matches so ordinary timestamps and port numbers stay in the log.
        for match in matches.reversed() {
            var range = match.range
            var candidate = source.substring(with: range)
            while candidate.last == "." {
                candidate.removeLast()
                range.length -= 1
            }
            let address = String(candidate.prefix(while: { $0 != "%" }))
            var parsed = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &parsed) }) == 1 else { continue }
            if range.location > 0, NSMaxRange(range) < source.length {
                let left = source.substring(with: NSRange(location: range.location - 1, length: 1))
                let right = source.substring(with: NSRange(location: NSMaxRange(range), length: 1))
                if left == "[", right == "]" {
                    range.location -= 1
                    range.length += 2
                }
            }
            output.replaceCharacters(in: range, with: "[REDACTED_IP]")
        }
        return output as String
    }
}
