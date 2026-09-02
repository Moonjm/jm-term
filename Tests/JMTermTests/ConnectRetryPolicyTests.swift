import XCTest
import NIOCore
import NIOPosix
import Citadel
@testable import JMTerm

final class ConnectRetryPolicyTests: XCTestCase {
    private let noWait = ConnectRetryPolicy(delays: [.zero, .zero, .zero])

    // 일시적 TCP 오류는 재시도 끝에 성공하고, 재시도 콜백은 실패 횟수만큼 호출된다.
    func testRetriesTransportErrorUntilSuccess() async throws {
        var calls = 0
        var retries: [Int] = []
        let value = try await noWait.run(onRetry: { retries.append($0) }) {
            calls += 1
            if calls < 3 { throw IOError(errnoCode: EHOSTUNREACH, reason: "connect") }
            return "ok"
        }
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(retries, [1, 2])
    }

    // 인증 실패 같은 비-전송 오류는 재시도 없이 즉시 던진다.
    func testNonTransportErrorIsNotRetried() async {
        var calls = 0
        do {
            _ = try await noWait.run(onRetry: { _ in }) { () -> Int in
                calls += 1
                throw SSHClientError.allAuthenticationOptionsFailed
            }
            XCTFail("throw 되어야 한다")
        } catch {
            XCTAssertEqual(calls, 1)
        }
    }

    // 모든 시도가 실패하면 마지막 오류를 던지고, 시도 횟수는 지연 개수 + 1이다.
    func testThrowsLastErrorAfterAllAttempts() async {
        var calls = 0
        do {
            _ = try await noWait.run(onRetry: { _ in }) { () -> Int in
                calls += 1
                throw IOError(errnoCode: ECONNREFUSED, reason: "connect #\(calls)")
            }
            XCTFail("throw 되어야 한다")
        } catch let e as IOError {
            XCTAssertEqual(calls, noWait.attempts)
            XCTAssertEqual(calls, 4)
            XCTAssertTrue(e.description.contains("#4"), e.description)
        } catch {
            XCTFail("IOError 여야 한다: \(error)")
        }
    }

    // 기본 정책은 macOS 로컬 네트워크 권한 프롬프트에 응답할 시간(10초 이상)을 준다.
    func testDefaultPolicyWaitsLongEnoughForPermissionPrompt() {
        let total = ConnectRetryPolicy.default.delays.reduce(Duration.zero, +)
        XCTAssertGreaterThanOrEqual(total, .seconds(10))
    }

    // 실제 연결 시도가 실패한 NIOConnectionError(refused)는 재시도 대상이다.
    func testConnectionAttemptFailureIsRetryable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let port = try reservedClosedLoopbackPort()
        do {
            _ = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
            XCTFail("연결이 성공하면 안 된다")
        } catch {
            XCTAssertTrue(ConnectRetryPolicy.isRetryable(error), "\(error)")
        }
        try await group.shutdownGracefully()
    }

    // DNS 조회만 실패한 NIOConnectionError(해석 불가 호스트명)는 결정적 실패이므로 재시도하지 않는다.
    func testDNSOnlyFailureIsNotRetryable() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            _ = try await ClientBootstrap(group: group).connect(host: "nonexistent.invalid", port: 22).get()
            XCTFail("연결이 성공하면 안 된다")
        } catch {
            XCTAssertTrue(error is NIOConnectionError, "\(type(of: error))")
            XCTAssertFalse(ConnectRetryPolicy.isRetryable(error), "\(error)")
        }
        try await group.shutdownGracefully()
    }

    // 최악 소요 시간 = 시도별 TCP timeout × 시도 횟수 + 지연 합. 테스트 연결의 바깥 timeout 은 이보다 길어야 재시도가 잘리지 않는다.
    func testWorstCaseDurationCoversAllAttemptsAndDelays() {
        let policy = ConnectRetryPolicy(delays: [.seconds(1), .seconds(2)], attemptTimeout: .seconds(4))
        XCTAssertEqual(policy.worstCaseDuration, .seconds(3 * 4 + 3))
        XCTAssertGreaterThanOrEqual(
            SSHSession.defaultTestConnectionTimeout(for: ConnectRetryPolicy.default),
            ConnectRetryPolicy.default.worstCaseDuration
        )
    }

    // 전송 계층 오류만 재시도 대상이다.
    func testIsRetryableClassifiesErrors() {
        XCTAssertTrue(ConnectRetryPolicy.isRetryable(IOError(errnoCode: EHOSTUNREACH, reason: "connect")))
        XCTAssertTrue(ConnectRetryPolicy.isRetryable(ChannelError.connectTimeout(.seconds(1))))
        XCTAssertFalse(ConnectRetryPolicy.isRetryable(SSHClientError.allAuthenticationOptionsFailed))
        XCTAssertFalse(ConnectRetryPolicy.isRetryable(SSHSessionError.hostKeyRejected))
    }
}
