import XCTest
import UniformTypeIdentifiers
@testable import JMTerm

// 앱 종료(⌘Q) 시 AppKit은 NSApplicationWillTerminateNotification 처리 중
// CFPasteboardResolveAllPromisedData로 남아 있는 드래그 promise를 확정하려고
// 메인 스레드를 중첩 런루프에 가둔 채 동기 대기한다.
// 그 상황에서도 promise는 유한 시간 안에 반드시 완료돼야 한다 —
// 아니면 앱이 영원히 멈춰 강제종료로만 끌 수 있다.
@MainActor
final class SFTPDragPromiseTests: XCTestCase {
    private func makeProvider() -> NSItemProvider {
        let connection = ServerConnection(name: "t", host: "127.0.0.1", username: "u")
        let session = SSHSession(connection: connection)
        let viewModel = SFTPViewModel(session: session)
        let node = FileNode(
            name: "sample.txt", path: "/tmp/sample.txt",
            isDirectory: false, size: 1, permissions: nil
        )
        return viewModel.dragProvider(for: node)
    }

    func testDragPromiseCompletesWhileMainThreadIsBlocked() {
        let provider = makeProvider()
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { _, _ in
                done.signal()
            }
        }

        // 메인 스레드를 막은 채 대기 — 종료 시 중첩 런루프 상황을 재현한다.
        XCTAssertEqual(
            done.wait(timeout: .now() + 8), .success,
            "메인 스레드가 막혀 있는 동안 드래그 promise가 완료되지 않았다 (⌘Q 무한 대기 재발)"
        )
    }
}

// 종료 정리가 pasteboard의 lazy promise(= 소유자가 나중에 채워주는 항목)를
// 실제로 제거하는지 확인한다. 이게 남아 있으면 ⌘Q가 무한 대기에 빠진다.
final class AppTerminationCleanupTests: XCTestCase {
    private final class LazyOwner: NSObject, NSPasteboardTypeOwner {
        func pasteboard(_ sender: NSPasteboard?, provideDataForType type: NSPasteboard.PasteboardType) {
            // 일부러 아무것도 제공하지 않는다 — 확정되지 않는 promise 재현.
        }
    }

    func testCleanupRemovesPendingPromises() {
        let pasteboard = NSPasteboard(name: .init("JMTermTests-\(UUID().uuidString)"))
        let owner = LazyOwner()
        pasteboard.declareTypes([.string], owner: owner)
        XCTAssertFalse(pasteboard.types?.isEmpty ?? true, "테스트 전제: promise가 등록돼 있어야 한다")

        AppTerminationCleanup.discardPendingPasteboardPromises(on: pasteboard)

        XCTAssertTrue(pasteboard.types?.isEmpty ?? true, "종료 정리 후에도 promise가 남아 있다")
        pasteboard.releaseGlobally()
    }
}
