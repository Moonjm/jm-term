// Sources/JMTerm/Models/JumpHostDraft.swift
import Foundation

/// 연결 폼에서 점프 호스트를 편집하기 위한 가변 표현 (포트를 문자열로 다룸).
struct JumpHostDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var password: String = ""
    var useKey: Bool = false
    var keyPath: String = "~/.ssh/id_ed25519"

    init() {}

    init(from hop: JumpHost, password: String) {
        self.id = hop.id
        self.host = hop.host
        self.port = String(hop.port)
        self.username = hop.username
        self.password = password
        if case .publicKey(let path) = hop.authMethod {
            self.useKey = true
            self.keyPath = path
        } else {
            self.useKey = false
            self.keyPath = "~/.ssh/id_ed25519"
        }
    }

    func toJumpHost() -> JumpHost {
        JumpHost(
            id: id,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: useKey ? .publicKey(path: keyPath) : .password
        )
    }
}
