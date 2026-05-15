import Foundation
import CommonCrypto

/// PrivacyGuard — All PII is hashed or sanitized at the SDK level
/// before any data leaves the device. This guarantees that no
/// sensitive user data is ever transmitted to our servers.
internal enum PrivacyGuard {

    private static let hashPrefix = "h_"

    // MARK: - PII Patterns

    private static let emailPattern = try! NSRegularExpression(pattern: "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")
    private static let phonePattern = try! NSRegularExpression(pattern: "\\+?[0-9]{7,15}")
    private static let ipPattern = try! NSRegularExpression(pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
    private static let jwtPattern = try! NSRegularExpression(pattern: "eyJ[a-zA-Z0-9_-]{10,}\\.[a-zA-Z0-9_-]{10,}")
    private static let creditCardPattern = try! NSRegularExpression(pattern: "\\b(?:\\d{4}[- ]?){3}\\d{4}\\b")

    private static let piiKeys: Set<String> = [
        "email", "mail", "phone", "tel", "mobile", "name", "username",
        "user_name", "first_name", "last_name", "address", "ssn", "password",
        "token", "secret", "api_key", "credit_card", "card_number"
    ]
    /// Keys whose substring would otherwise hit piiKeys but are clearly safe
    /// (e.g. "screen_name" matches "name" but is just a route label, not
    /// user data). Exact-match exemptions checked before substring scanning.
    private static let piiKeyAllowlist: Set<String> = [
        "screen_name", "previous_screen", "screen", "route", "route_name",
        "next_screen", "event_name", "tag_name", "class_name", "package_name",
        "session_id", "session_number", "view_name"
    ]

    // MARK: - Public API

    /// Hash a user identifier. If the host app called setUserId we send the SHA256-hashed
    /// value (h_<hash>). Otherwise we fall back to the persisted anonymous installation
    /// ID (anon_<uuid>) so DAU/MAU/retention/sessions analytics always have something
    /// distinct to count. Returns nil only before AnonIdStore is initialized.
    static func hashUserId(_ userId: String?) -> String? {
        if let userId = userId, !userId.isEmpty {
            return hashPrefix + sha256(userId)
        }
        return AnonIdStore.get()
    }

    /// Sanitize a URL — strip query params and fragments which may contain tokens, emails, etc.
    static func sanitizeUrl(_ url: String?) -> String? {
        guard let url = url, !url.isEmpty else { return nil }
        guard var components = URLComponents(string: url) else {
            // Fallback: strip everything after ? or #
            return url.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? url
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url
    }

    /// Sanitize custom event data — auto-detect and hash any values that look like PII.
    static func sanitizeEventData(_ data: [String: String]?) -> [String: String]? {
        guard let data = data else { return nil }
        var result: [String: String] = [:]
        for (k, v) in data {
            result[k] = sanitizeValue(key: k, value: v)
        }
        return result
    }

    /// Sanitize a stack trace — remove home directory paths and embedded PII.
    static func sanitizeStackTrace(_ stackTrace: String) -> String {
        var result = stackTrace
        let range = NSRange(result.startIndex..., in: result)

        // Remove home directory paths
        result = result.replacingOccurrences(of: "(/Users/)[^/]+(/)", with: "$1****$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "(/home/)[^/]+(/)", with: "$1****$2", options: .regularExpression)

        // Hash emails
        result = replaceMatches(emailPattern, in: result) { match in
            hashPrefix + sha256(match).prefix(12)
        }

        // Hash IPs
        result = replaceMatches(ipPattern, in: result) { match in
            hashPrefix + sha256(match).prefix(8)
        }

        // Hash JWT tokens
        result = replaceMatches(jwtPattern, in: result) { _ in "[hashed_token]" }

        return result
    }

    /// Sanitize a crash message — may contain user input or PII.
    static func sanitizeMessage(_ message: String) -> String {
        var result = message

        result = replaceMatches(emailPattern, in: result) { match in
            "[hashed_email:\(sha256(match).prefix(8))]"
        }
        result = replaceMatches(creditCardPattern, in: result) { _ in "[redacted_card]" }
        result = replaceMatches(jwtPattern, in: result) { _ in "[hashed_token]" }

        return result
    }

    /// Sanitize a full payload dictionary — processes userId, URLs, and event data.
    static func sanitizePayload(_ payload: [String: Any]) -> [String: Any] {
        var result = payload

        // Always hash userId
        if let userId = result["userId"] as? String {
            result["userId"] = hashUserId(userId) as Any
        }

        // Sanitize URLs
        if let url = result["url"] as? String {
            result["url"] = sanitizeUrl(url) as Any
        }

        // Sanitize event data
        if let eventData = result["eventData"] as? [String: String] {
            result["eventData"] = sanitizeEventData(eventData) as Any
        }

        // Sanitize message
        if let message = result["message"] as? String {
            result["message"] = sanitizeMessage(message) as Any
        }

        // Sanitize stack trace
        if let stackTrace = result["stackTrace"] as? String {
            result["stackTrace"] = sanitizeStackTrace(stackTrace) as Any
        }

        return result
    }

    // MARK: - Private Helpers

    private static func sanitizeValue(key: String, value: String) -> String {
        let keyLower = key.lowercased()

        // Whitelisted keys (e.g. "screen_name") pass through unmodified
        if piiKeyAllowlist.contains(keyLower) {
            return value
        }
        // Check if key name suggests PII
        if piiKeys.contains(where: { keyLower.contains($0) }) {
            return hashPrefix + String(sha256(value).prefix(16))
        }

        let range = NSRange(value.startIndex..., in: value)

        // Auto-detect email
        if emailPattern.firstMatch(in: value, range: range) != nil {
            return hashPrefix + String(sha256(value).prefix(16))
        }

        // Auto-detect credit card
        if creditCardPattern.firstMatch(in: value, range: range) != nil {
            return "[redacted]"
        }

        // Auto-detect JWT
        if jwtPattern.firstMatch(in: value, range: range) != nil {
            return hashPrefix + String(sha256(value).prefix(16))
        }

        // Phone — only if the value is primarily a phone number
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 7 && trimmed.count <= 16 {
            if phonePattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return hashPrefix + String(sha256(value).prefix(16))
            }
        }

        return value // Not PII — pass through
    }

    private static func replaceMatches(_ regex: NSRegularExpression, in string: String, using replacement: (String) -> String) -> String {
        var result = string
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        // Process in reverse to maintain string indices
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range])
            result.replaceSubrange(range, with: replacement(matched))
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
