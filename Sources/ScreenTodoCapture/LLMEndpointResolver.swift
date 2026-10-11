import Foundation

/// Resolves a user-configured OpenAI-compatible base URL into the concrete
/// Chat Completions endpoint used by every LLM caller in the app.
///
/// Settings may store either an API root such as `/v1` or the full
/// `/chat/completions` endpoint. This boundary keeps URL normalization out of
/// request-building code and preserves query items used by compatible providers.
enum LLMEndpointResolver {
    static func chatCompletionsURL(from baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        let pathSegments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let normalizedTail = pathSegments.suffix(2).map { $0.lowercased() }

        if normalizedTail == ["chat", "completions"] {
            components.percentEncodedPath = "/" + pathSegments.joined(separator: "/")
            return components.url ?? baseURL
        }

        let resolvedSegments = pathSegments + ["chat", "completions"]
        components.percentEncodedPath = "/" + resolvedSegments.joined(separator: "/")
        return components.url ?? baseURL.appendingPathComponent("chat/completions")
    }
}
