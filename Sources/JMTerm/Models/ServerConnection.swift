// Sources/JMTerm/Models/ServerConnection.swift
import Foundation

enum AuthMethod: Codable, Hashable, Sendable {
    case password
    case publicKey(path: String)
}

struct JumpHost: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod

    init(id: UUID = UUID(), host: String, port: Int = 22, username: String, authMethod: AuthMethod = .password) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }

    /// Keychain 계정 키 (기존 규칙과 동일: username@host:port)
    var keychainAccount: String { "\(username)@\(host):\(port)" }
}

struct ServerConnection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var jumpHosts: [JumpHost]
    /// 구형 서버 호환: SHA-1 KEX 등 레거시 알고리즘 허용 (기본 꺼짐 — 다운그레이드 공격 방지).
    var allowLegacyAlgorithms: Bool

    init(name: String, host: String, port: Int = 22, username: String, authMethod: AuthMethod = .password, jumpHosts: [JumpHost] = [], allowLegacyAlgorithms: Bool = false) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.jumpHosts = jumpHosts
        self.allowLegacyAlgorithms = allowLegacyAlgorithms
    }

    /// Keychain 계정 키 (기존 규칙과 동일: username@host:port)
    var keychainAccount: String { "\(username)@\(host):\(port)" }

    // 합성 Codable 은 키 누락 시 기본값을 쓰지 않고 throw 한다.
    // 기존 connections.json(jumpHosts 키 없음) 하위호환을 위해 디코딩을 직접 구현한다.
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, jumpHosts, allowLegacyAlgorithms
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        authMethod = try c.decode(AuthMethod.self, forKey: .authMethod)
        jumpHosts = try c.decodeIfPresent([JumpHost].self, forKey: .jumpHosts) ?? []
        allowLegacyAlgorithms = try c.decodeIfPresent(Bool.self, forKey: .allowLegacyAlgorithms) ?? false
    }
    // encode(to:) 는 합성된 것을 사용한다.
}
