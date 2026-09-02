import XCTest
@testable import JMTerm

/// 최초 TCP 연결 진입점(테스트 연결, 점프 체인 첫 홉)에도 재시도 정책이 적용되는지 확인한다.
/// 루프백의 닫힌 포트로 붙어 refused 를 유발하고, 짧은 지연 정책으로 재시도가 실제로 일어났는지(경과 시간)를 본다.
@MainActor
final class SSHSessionRetryTests: XCTestCase {
    private let twoRetries = ConnectRetryPolicy(delays: [.milliseconds(300), .milliseconds(300)])

    func testTestConnectionRetriesTCPFailure() async throws {
        let port = try reservedClosedLoopbackPort()
        let conn = ServerConnection(name: "t", host: "127.0.0.1", port: port, username: "u")
        let creds = ResolvedCredentials(passwords: [conn.id: "x"])

        let start = ContinuousClock.now
        do {
            try await SSHSession.testConnection(conn, credentials: creds, timeout: .seconds(10), retryPolicy: twoRetries)
            XCTFail("throw 되어야 한다")
        } catch {
            XCTAssertTrue(ConnectionErrorText.describe(error).lowercased().contains("refused"), "\(error)")
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(600))
    }

    // 패킷이 조용히 버려지는 호스트(accept 큐 포화 리스너): 시도별 TCP timeout 이 정책값으로 짧게 걸리고, timeout 도 재시도된다.
    func testTestConnectionRetriesTCPTimeoutPerAttempt() async throws {
        let blackhole = try BlackholeListener()
        let policy = ConnectRetryPolicy(delays: [.milliseconds(200)], attemptTimeout: .milliseconds(300))
        let conn = ServerConnection(name: "t", host: "127.0.0.1", port: blackhole.port, username: "u")
        let creds = ResolvedCredentials(passwords: [conn.id: "x"])

        let start = ContinuousClock.now
        do {
            try await SSHSession.testConnection(conn, credentials: creds, timeout: .seconds(10), retryPolicy: policy)
            XCTFail("throw 되어야 한다")
        } catch {
            XCTAssertFalse(error is SSHSessionError, "바깥 timeout 이 아니라 TCP timeout 이어야 한다: \(error)")
            XCTAssertTrue(ConnectionErrorText.describe(error).lowercased().contains("timeout"), "\(error)")
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(800))   // 300 + 200 + 300
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    func testJumpChainFirstHopRetriesTCPFailure() async throws {
        let port = try reservedClosedLoopbackPort()
        let jump = JumpHost(host: "127.0.0.1", port: port, username: "u")
        let conn = ServerConnection(name: "t", host: "10.255.255.1", username: "u", jumpHosts: [jump])
        let session = SSHSession(connection: conn)
        session.retryPolicy = twoRetries
        let creds = ResolvedCredentials(passwords: [jump.id: "x", conn.id: "x"])

        let start = ContinuousClock.now
        do {
            try await session.connect(credentials: creds)
            XCTFail("throw 되어야 한다")
        } catch {
            XCTAssertTrue(ConnectionErrorText.describe(error).lowercased().contains("refused"), "\(error)")
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(600))
        XCTAssertEqual(session.state, .disconnected)
    }
}
