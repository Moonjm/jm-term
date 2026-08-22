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

// 워치독과 다운로드는 동시에 진행되므로, 어느 한쪽이 promise를 확정하면
// 다른 쪽은 반드시 아무 일도 하지 않아야 한다.
final class DragPromiseStateTests: XCTestCase {
    // Codex 리뷰 지적: 타임아웃으로 실패를 보고한 뒤에 다운로드가 시작되면
    // 쓰이지 않을 파일을 받느라 대역폭을 쓰고 이후 전송이 busy로 막힌다.
    func testDownloadDoesNotStartAfterTimeout() {
        let state = DragPromiseState()
        XCTAssertTrue(state.claimTimeout())
        XCTAssertFalse(state.claimDownload(), "워치독이 확정한 뒤에 다운로드가 시작됐다")
    }

    // 다운로드가 시작된 뒤에는 워치독이 끼어들면 안 된다 — 큰 파일 전송이
    // 3초를 넘겼다고 실패로 보고해 버리면 정상 드래그가 깨진다.
    func testTimeoutDoesNotFireAfterDownloadStarts() {
        let state = DragPromiseState()
        XCTAssertTrue(state.claimDownload())
        XCTAssertFalse(state.claimTimeout(), "다운로드 시작 후 워치독이 발동했다")
    }

    func testCompletionIsClaimedOnlyOnce() {
        let state = DragPromiseState()
        XCTAssertTrue(state.claimDownload())
        XCTAssertTrue(state.claimCompletion())
        XCTAssertFalse(state.claimCompletion(), "completion이 두 번 호출될 수 있다")
    }

    func testCompletionIsNotClaimedAfterTimeout() {
        let state = DragPromiseState()
        XCTAssertTrue(state.claimTimeout())
        XCTAssertFalse(state.claimCompletion(), "타임아웃 후 다운로드 결과가 보고됐다")
    }

    // 두 경로가 실제로 동시에 달려들어도 정확히 하나만 이겨야 한다.
    func testExactlyOneClaimWinsUnderContention() {
        for _ in 0..<500 {
            let state = DragPromiseState()
            let wins = ManagedCriticalState(0)
            let group = DispatchGroup()
            for claim in [state.claimDownload, state.claimTimeout] {
                DispatchQueue.global().async(group: group) {
                    if claim() { wins.withLock { $0 += 1 } }
                }
            }
            group.wait()
            XCTAssertEqual(wins.withLock { $0 }, 1, "동시 경쟁에서 승자가 정확히 하나가 아니다")
        }
    }
}
