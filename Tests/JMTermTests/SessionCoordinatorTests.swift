import XCTest
@testable import JMTerm

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCoordinator(savedCount: Int) -> SessionCoordinator {
        let store = ConnectionStore(fileURL: tempDir.appendingPathComponent("connections.json"))
        for i in 0..<savedCount {
            store.add(ServerConnection(name: "srv\(i)", host: "10.0.0.\(i)", username: "u"))
        }
        return SessionCoordinator(connectionStore: store)
    }

    // 저장된 서버가 없으면 ⌘T는 새 서버 폼으로 폴백한다.
    func testQuickConnectFallsBackToFormWhenNoSavedServers() {
        let coordinator = makeCoordinator(savedCount: 0)
        coordinator.openQuickConnect()
        XCTAssertEqual(coordinator.connectionDialogMode, .newServer)
    }

    // 저장된 서버가 있으면 ⌘T는 목록을 연다.
    func testQuickConnectShowsListWhenServersExist() {
        let coordinator = makeCoordinator(savedCount: 2)
        coordinator.openQuickConnect()
        XCTAssertEqual(coordinator.connectionDialogMode, .quickConnect)
    }

    // 다이얼로그가 이미 떠 있으면 ⌘T가 모드를 갈아치우지 않는다 —
    // 입력 중인 새 서버 폼(비밀번호 포함)이 날아가는 것을 방지.
    func testQuickConnectDoesNotReplaceOpenDialog() {
        let coordinator = makeCoordinator(savedCount: 2)
        coordinator.connectionDialogMode = .newServer
        coordinator.openQuickConnect()
        XCTAssertEqual(coordinator.connectionDialogMode, .newServer)
    }
}
