import CryptoKit
import Foundation
import os

/// Records a single diagnostic line. Injected so tests can observe what would be logged.
typealias DiagnosticRecorder = @Sendable (String) -> Void

/// Temporary instrumentation for attributing Claude rate limits to a specific endpoint.
///
/// Public evidence for HTTP 429 is strong for `api.anthropic.com/api/oauth/usage` and weak for
/// `platform.claude.com/v1/oauth/token`, and the two are routinely conflated in community reports.
/// Removing the refresh path only helps if the local symptom originates at the token endpoint, so
/// the symptom is attributed before that change is made. See
/// `docs/superpowers/specs/2026-09-06-claude-readonly-credentials-design.md`.
///
/// Read the output with:
/// ```
/// log show --predicate 'subsystem == "com.ovidiuadorian.CodingAIUsage"' --last 12h --style compact
/// ```
enum DiagnosticLog {
    static let subsystem = "com.ovidiuadorian.CodingAIUsage"

    private static let claudeLogger = Logger(subsystem: subsystem, category: "claude")

    /// Logs at `.notice` rather than `.info`: `.info` is retained in memory only and would not
    /// survive to `log show`. The interpolation is marked `.public` because os.Logger redacts
    /// dynamic strings as `<private>` by default — the usual reason instrumentation like this
    /// comes back empty. Callers must therefore never pass secret material; use `fingerprint(_:)`.
    static let claude: DiagnosticRecorder = { message in
        claudeLogger.notice("\(message, privacy: .public)")
    }

    /// A short, stable, non-reversible fingerprint of a token, for telling two tokens apart in the
    /// log without recording either. Correlating fingerprints across events shows whether the
    /// stored refresh token changed between refreshes.
    static func fingerprint(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
    }

    /// Formats a `Retry-After` value, recording its absence explicitly. Sources disagree on whether
    /// the header is sent at all, so "not present" is itself a finding worth capturing.
    static func retryAfter(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "absent" }
        return value
    }
}
