// Sources/JMTerm/Services/ConnectRetryPolicy.swift
import Foundation
import NIOCore
import NIOPosix

/// TCP 단계 연결 실패(경로 없음·거부·타임아웃)에 대한 재시도 정책.
///
/// macOS 15는 앱이 로컬 네트워크에 처음 접근할 때 권한 프롬프트를 띄우고, 사용자가 응답하기 전까지
/// connect()가 EHOSTUNREACH 로 실패한다. 기본 정책은 사용자가 프롬프트에 답할 시간을 주도록 지연을 점증시킨다.
/// 인증 실패·호스트 키 거부 같은 비-전송 오류는 재시도하지 않고 즉시 던진다.
struct ConnectRetryPolicy: Sendable {
    /// 각 실패 후 다음 시도까지 기다리는 시간. 총 시도 횟수는 `delays.count + 1`.
    let delays: [Duration]
    /// 시도별 TCP 연결 timeout. Citadel 기본값(30초)은 테스트 연결의 바깥 timeout 보다 길어
    /// 패킷이 버려지는 호스트에서 timeout 이 재시도 정책에 도달하기 전에 잘리므로 짧게 잡는다.
    let attemptTimeout: Duration

    init(delays: [Duration], attemptTimeout: Duration = .seconds(4)) {
        self.delays = delays
        self.attemptTimeout = attemptTimeout
    }

    var attempts: Int { delays.count + 1 }

    /// 모든 시도가 TCP timeout 으로 끝났을 때의 총 소요 시간.
    var worstCaseDuration: Duration {
        attemptTimeout * attempts + delays.reduce(.zero, +)
    }

    /// `SSHClient.connect(connectTimeout:)` 에 넘길 값.
    var attemptTimeoutAmount: TimeAmount {
        let (seconds, attoseconds) = attemptTimeout.components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }

    /// 지연 합 약 10.5초 + 시도별 4초 → 최악 34.5초.
    static let `default` = ConnectRetryPolicy(
        delays: [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3), .seconds(4)]
    )

    /// 전송 계층(소켓 연결) 오류만 재시도 대상이다.
    /// DNS 조회만 실패한 `NIOConnectionError`(해석 불가 호스트명)는 결정적 실패라 재시도하지 않는다.
    static func isRetryable(_ error: Error) -> Bool {
        if let nio = error as? NIOConnectionError { return !nio.connectionErrors.isEmpty }
        if error is IOError { return true }
        if let channelError = error as? ChannelError, case .connectTimeout = channelError { return true }
        return false
    }

    /// `operation`을 성공할 때까지 정책에 따라 재시도한다.
    /// `onRetry`는 실패한 시도 번호(1부터)를 받아 상태 표시 등에 쓴다.
    func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        onRetry: (Int) async -> Void,
        _ operation: () async throws -> sending T
    ) async throws -> sending T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < attempts, Self.isRetryable(error) else { throw error }
                await onRetry(attempt)
                try await Task.sleep(for: delays[attempt - 1])
                attempt += 1
            }
        }
    }
}
