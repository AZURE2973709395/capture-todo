import Foundation
@testable import ScreenTodoCapture
import XCTest

final class LLMEndpointResolverTests: XCTestCase {
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
            let resolved = LLMEndpointResolver.chatCompletionsURL(from: try XCTUnwrap(URL(string: input)))
            XCTAssertEqual(resolved.absoluteString, expected, "Failed to resolve \(input)")
        }
    }
}
