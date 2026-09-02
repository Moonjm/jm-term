// Sources/JMTerm/Services/ConnectionErrorText.swift
import Foundation
import NIOCore
import NIOPosix

/// 연결 오류를 사용자에게 보여줄 문구로 바꾼다.
///
/// SwiftNIO의 `NIOConnectionError` 같은 순수 Swift 에러는 `LocalizedError`가 아니라서
/// `localizedDescription`이 "The operation couldn't be completed. (NIOPosix.NIOConnectionError error 1.)"처럼
/// 원인이 사라진 문구가 된다. 여기서는 그런 타입의 `description`(errno 문자열 포함)을 대신 쓴다.
enum ConnectionErrorText {
    /// 원인이 드러나는 한 줄 설명.
    static func describe(_ error: Error) -> String {
        if error is LocalizedError { return error.localizedDescription }

        if let nio = error as? NIOConnectionError {
            // 한쪽 주소 계열(A/AAAA) 조회만 실패하고 실제 연결 시도가 있었다면 그 실패가 진짜 원인이다.
            if let last = nio.connectionErrors.last {
                return "\(nio.host):\(nio.port) 연결 실패: \(describe(last.error))"
            }
            if let dns = nio.dnsAError ?? nio.dnsAAAAError {
                return "\(nio.host) 주소 조회 실패: \(describe(dns))"
            }
        }

        // NSError 계열은 localizedDescription 이 이미 사람이 읽을 수 있는 문구다.
        if type(of: error) is NSError.Type { return error.localizedDescription }
        if let described = error as? CustomStringConvertible { return described.description }
        return error.localizedDescription
    }

    /// 연결 실패 원인을 단계(해석·TCP·인증·호스트키)별 친화 메시지로 분류.
    /// `port`는 안내 문구에 표시할 포트 문자열(빈 문자열이면 22).
    static func diagnose(_ error: Error, port: String) -> String {
        // SSHSessionError 는 errorDescription 이 한국어라 아래 영문 키워드 매칭이 안 된다.
        // 따라서 우리 타입은 case 로 먼저 분류하고, 그 외(Citadel/NIO 영문 에러)만 키워드로 분류한다.
        // 참고: 테스트 연결은 nonPromptingValidator(.acceptAnything)을 쓰므로 미지 호스트에서는
        // hostKeyRejected 가 발생하지 않는다(주로 신뢰 키 불일치 시에만).
        if let e = error as? SSHSessionError {
            switch e {
            case .connectionTimeout: return "연결 시간 초과 — 호스트·포트·방화벽을 확인하세요"
            case .hostKeyRejected: return "호스트 키 거부됨 — 신뢰할 수 없는 호스트 키"
            case .hostKeyUnverified: return "미등록 호스트 — 비밀번호 테스트는 한 번 정식 연결해 호스트 키를 저장한 뒤 가능합니다"
            case .passwordRequired: return "비밀번호가 필요합니다"
            case .invalidKeyFormat, .unsupportedKeyType: return "키 형식 오류 — SSH 키 파일을 확인하세요"
            case .notConnected: return "연결할 수 없습니다"
            }
        }

        let d = describe(error).lowercased()
        if d.contains("no route") || d.contains("host is down") || d.contains("network is unreachable") {
            return "호스트에 도달할 수 없습니다 — 네트워크 연결과 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 JMTerm 허용 여부를 확인하세요"
        }
        if d.contains("refused") {
            return "연결 거부됨 — 포트(\(port.isEmpty ? "22" : port))·방화벽을 확인하세요"
        }
        if d.contains("nodename") || d.contains("not known") || d.contains("resolve") || d.contains("hostname") || d.contains("주소 조회") {
            return "호스트를 찾을 수 없습니다 — 주소(DNS)를 확인하세요"
        }
        if d.contains("permission denied") || d.contains("auth") || d.contains("password") {
            return "인증 실패 — 사용자·비밀번호·키를 확인하세요"
        }
        if d.contains("host key") || d.contains("hostkey") {
            return "호스트 키 문제 — 신뢰할 수 없는 호스트 키"
        }
        if d.contains("timed out") || d.contains("timeout") {
            return "연결 시간 초과 — 네트워크·방화벽을 확인하세요"
        }
        return describe(error)
    }
}
