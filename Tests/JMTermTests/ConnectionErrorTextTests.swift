import XCTest
import NIOCore
import NIOPosix
import Citadel
@testable import JMTerm

final class ConnectionErrorTextTests: XCTestCase {
    private struct PlainSwiftError: Error, CustomStringConvertible {
        var description: String { "plain description" }
    }

    // LocalizedError(우리 타입)는 한국어 errorDescription을 그대로 쓴다.
    func testDescribeKeepsLocalizedErrorDescription() {
        let text = ConnectionErrorText.describe(SSHSessionError.passwordRequired)
        XCTAssertEqual(text, SSHSessionError.passwordRequired.localizedDescription)
    }

    // LocalizedError가 아닌 Swift 에러는 "The operation couldn't be completed. (X error 1.)" 대신 description을 쓴다.
    func testDescribeUsesDescriptionForNonLocalizedSwiftError() {
        let text = ConnectionErrorText.describe(PlainSwiftError())
        XCTAssertEqual(text, "plain description")
    }

    // IOError는 errno 문자열(No route to host)을 포함해야 한다.
    func testDescribeIOErrorIncludesErrnoReason() {
        let text = ConnectionErrorText.describe(IOError(errnoCode: EHOSTUNREACH, reason: "connect"))
        XCTAssertTrue(text.contains("No route to host"), text)
    }

    // 실제 NIOConnectionError(루프백 닫힌 포트 → refused)를 사람이 읽을 수 있는 원인으로 풀어낸다.
    func testDescribeNIOConnectionErrorExposesUnderlyingCause() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let port = try reservedClosedLoopbackPort()
        do {
            _ = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
            XCTFail("연결이 성공하면 안 된다")
        } catch {
            XCTAssertTrue(error is NIOConnectionError, "\(type(of: error))")
            let text = ConnectionErrorText.describe(error)
            XCTAssertFalse(text.contains("NIOConnectionError error"), text)
            XCTAssertTrue(text.lowercased().contains("refused"), text)
        }
        try await group.shutdownGracefully()
    }

    // DNS 조회만 실패한 NIOConnectionError 는 주소 조회 실패로 설명된다.
    func testDescribeDNSOnlyFailureMentionsLookup() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            _ = try await ClientBootstrap(group: group).connect(host: "nonexistent.invalid", port: 22).get()
            XCTFail("연결이 성공하면 안 된다")
        } catch {
            XCTAssertTrue(error is NIOConnectionError, "\(type(of: error))")
            let text = ConnectionErrorText.describe(error)
            XCTAssertTrue(text.contains("nonexistent.invalid 주소 조회 실패"), text)
        }
        try await group.shutdownGracefully()
    }

    // 경로 없음(EHOSTUNREACH)은 로컬 네트워크 권한 안내를 포함한 진단 문구로 분류된다.
    func testDiagnoseNoRouteMentionsLocalNetworkPermission() {
        let msg = ConnectionErrorText.diagnose(IOError(errnoCode: EHOSTUNREACH, reason: "connect"), port: "22")
        XCTAssertTrue(msg.contains("로컬 네트워크"), msg)
    }

    // 연결 거부는 포트 안내 문구로 분류된다.
    func testDiagnoseRefusedMentionsPort() {
        let msg = ConnectionErrorText.diagnose(IOError(errnoCode: ECONNREFUSED, reason: "connect"), port: "2222")
        XCTAssertTrue(msg.contains("연결 거부됨"), msg)
        XCTAssertTrue(msg.contains("2222"), msg)
    }

    // 우리 타입은 case 기준으로 분류된다.
    func testDiagnoseSessionErrorByCase() {
        let msg = ConnectionErrorText.diagnose(SSHSessionError.connectionTimeout, port: "")
        XCTAssertTrue(msg.contains("연결 시간 초과"), msg)
    }
}
