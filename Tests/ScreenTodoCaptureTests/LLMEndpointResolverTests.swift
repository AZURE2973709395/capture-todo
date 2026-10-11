import Foundation
@testable import ScreenTodoCapture
import Testing

final class LLMEndpointResolverTests {
    @Test
    func testChatCompletionsURLResolvesConfiguredBaseURLVariants() throws {
        let cases = [
            ("https://example.com/v1", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
            ("https://example.com/v1/chat/completions/", "https://example.com/v1/chat/completions"),
            ("https://example.com/chat/completions", "https://example.com/chat/completions"),
            ("https://example.com/v1?api-version=2026-01-01", "https://example.com/v1/chat/completions?api-version=2026-01-01")
        ]

        for (input, expected) in cases {
            let resolved = LLMEndpointResolver.chatCompletionsURL(from: try #require(URL(string: input)))
            #expect(resolved.absoluteString == expected, "Failed to resolve \(input)")
        }
    }
}
