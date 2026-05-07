import Foundation

enum CredentialSanitizer {
    static let maxErrorBodyLength = 500
    private static let sensitiveFieldPattern = #"(?:api[_-]?key|apiKey|x-api-key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|token|secret|password)"#

    static func sanitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text

        result = replacePattern(
            in: result,
            pattern: #"(?i)(Authorization|authorization)\s*:\s*Bearer\s+\S+"#,
            replacement: "$1: Bearer <REDACTED>"
        )

        result = replacePattern(
            in: result,
            pattern: #"(?i)(x-api-key)\s*:\s*\S+"#,
            replacement: "$1: <REDACTED>"
        )

        result = replacePattern(
            in: result,
            pattern: #"(?i)"(Authorization|authorization)"\s*:\s*"Bearer\s+[^"]*""#,
            replacement: #""$1": "Bearer <REDACTED>""#
        )

        result = replacePattern(
            in: result,
            pattern: #"(?i)"(x-api-key)"\s*:\s*"[^"]*""#,
            replacement: #""$1": "<REDACTED>""#
        )

        result = replacePattern(
            in: result,
            pattern: #"(?i)("(?:\#(sensitiveFieldPattern))"\s*:\s*")([^"]*)(")"#,
            replacement: "$1<REDACTED>$3"
        )

        result = replacePattern(
            in: result,
            pattern: #"(?i)\b(\#(sensitiveFieldPattern))(\s*[=:]\s*)([^\s&;,]+)"#,
            replacement: "$1$2<REDACTED>"
        )

        return result
    }

    static func sanitizeForError(_ text: String) -> String {
        let sanitized = sanitize(text)
        guard sanitized.count > maxErrorBodyLength else { return sanitized }
        return String(sanitized.prefix(maxErrorBodyLength)) + "..."
    }

    private static func replacePattern(in text: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
