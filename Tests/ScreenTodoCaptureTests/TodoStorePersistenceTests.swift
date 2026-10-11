import Foundation
import ScreenTodoCaptureCore
@testable import ScreenTodoCapture
import XCTest

final class TodoStorePersistenceTests: XCTestCase {
    func testSavingMultipleDraftsWithSameTimestampDoesNotOverwriteMarkdown() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let store = TodoStore(rootDirectoryOverride: temporaryRoot)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_400)

        let first = TodoDraft(
            title: "第一条作业通知",
            originalText: "周五前提交第一份作业",
            sourceApplication: "测试",
            createdAt: createdAt
        )
        let second = TodoDraft(
            title: "第二条作业通知",
            originalText: "周五前提交第二份作业",
            sourceApplication: "测试",
            createdAt: createdAt
        )

        let firstStored = try store.save(draft: first, image: nil)
        let secondStored = try store.save(draft: second, image: nil)

        XCTAssertNotEqual(firstStored.todoURL, secondStored.todoURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstStored.todoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStored.todoURL.path))

        let records = try TodoRecordLoader(store: store, sortMode: .createdDesc).load()
        XCTAssertEqual(Set(records.map(\.title)), Set(["第一条作业通知", "第二条作业通知"]))
    }
}
