import XCTest
@testable import JMTerm

final class ModelTests: XCTestCase {

    // 기존 connections.json(필드 없음)이 jumpHosts == [] 로 디코딩되어야 한다.
    func testDecodesLegacyJSONWithoutJumpHosts() throws {
        let conn = ServerConnection(name: "srv", host: "1.2.3.4", port: 22, username: "u", authMethod: .password)
        let data = try JSONEncoder().encode(conn)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "jumpHosts")
        let legacy = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(ServerConnection.self, from: legacy)

        XCTAssertEqual(decoded.jumpHosts, [])
        XCTAssertEqual(decoded.host, "1.2.3.4")
        XCTAssertEqual(decoded.username, "u")
    }

    // jumpHosts 가 있으면 라운드트립으로 보존되어야 한다.
    func testRoundTripWithJumpHosts() throws {
        var conn = ServerConnection(name: "srv", host: "10.0.0.5", port: 22, username: "u", authMethod: .password)
        conn.jumpHosts = [
            JumpHost(host: "bastion", port: 22, username: "jump", authMethod: .password),
            JumpHost(host: "mid", port: 2222, username: "m", authMethod: .publicKey(path: "~/.ssh/id_ed25519")),
        ]
        let data = try JSONEncoder().encode(conn)
        let decoded = try JSONDecoder().decode(ServerConnection.self, from: data)
        XCTAssertEqual(decoded.jumpHosts, conn.jumpHosts)
    }

    // keychain 계정 문자열 규칙 (username@host:port).
    func testKeychainAccountString() {
        let hop = JumpHost(host: "h", port: 2200, username: "u", authMethod: .password)
        XCTAssertEqual(hop.keychainAccount, "u@h:2200")
        let conn = ServerConnection(name: "n", host: "host", port: 22, username: "user", authMethod: .password)
        XCTAssertEqual(conn.keychainAccount, "user@host:22")
    }

    // allowLegacyAlgorithms 키가 없는 기존 JSON은 false로 디코딩되어야 한다.
    func testLegacyJSONDefaultsAllowLegacyAlgorithmsToFalse() throws {
        let conn = ServerConnection(name: "srv", host: "1.2.3.4", port: 22, username: "u", authMethod: .password)
        let data = try JSONEncoder().encode(conn)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "allowLegacyAlgorithms")
        let legacy = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(ServerConnection.self, from: legacy)
        XCTAssertFalse(decoded.allowLegacyAlgorithms)

        // 플래그가 켜진 연결은 라운드트립으로 보존된다.
        var on = conn
        on.allowLegacyAlgorithms = true
        let roundTrip = try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(roundTrip.allowLegacyAlgorithms)
    }

    // Draft <-> JumpHost 변환.
    func testDraftConversion() {
        let hop = JumpHost(host: "h", port: 2222, username: "u", authMethod: .publicKey(path: "/k"))
        let draft = JumpHostDraft(from: hop, password: "")
        XCTAssertEqual(draft.host, "h")
        XCTAssertEqual(draft.port, "2222")
        XCTAssertTrue(draft.useKey)
        XCTAssertEqual(draft.keyPath, "/k")

        let back = draft.toJumpHost()
        XCTAssertEqual(back.id, hop.id)         // id 보존
        XCTAssertEqual(back.port, 2222)
        XCTAssertEqual(back.authMethod, .publicKey(path: "/k"))

        // 잘못된 포트는 22로 폴백.
        var d2 = JumpHostDraft()
        d2.host = "x"; d2.username = "y"; d2.port = "abc"
        XCTAssertEqual(d2.toJumpHost().port, 22)
        XCTAssertEqual(d2.toJumpHost().authMethod, .password)
    }
}
