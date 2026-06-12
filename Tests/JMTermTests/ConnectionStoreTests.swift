import XCTest
@testable import JMTerm

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("connections.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func backupFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("corrupt") }
    }

    // 정상 파일은 그대로 로드된다.
    func testLoadsValidFile() throws {
        let conn = ServerConnection(name: "srv", host: "1.2.3.4", username: "u")
        let data = try JSONEncoder().encode([conn])
        try data.write(to: fileURL)

        let store = ConnectionStore(fileURL: fileURL)
        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections.first?.host, "1.2.3.4")
        XCTAssertNil(store.loadFailureMessage)
    }

    // 완전히 깨진 파일: 백업본이 생성되고, 원본 데이터가 소실되지 않아야 한다.
    func testCorruptFileIsBackedUpBeforeOverwrite() throws {
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        let store = ConnectionStore(fileURL: fileURL)
        XCTAssertEqual(store.connections.count, 0)
        XCTAssertNotNil(store.loadFailureMessage)

        // 백업본이 존재하고 원본 내용을 담고 있어야 한다.
        let backup = try XCTUnwrap(backupFiles().first)
        XCTAssertEqual(try Data(contentsOf: backup), garbage)

        // 이후 add()로 save가 일어나도 백업본은 유지된다.
        store.add(ServerConnection(name: "new", host: "h", username: "u"))
        XCTAssertEqual(try backupFiles().count, 1)
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
    }

    // 깨진 원소가 객체가 아니라 스칼라(숫자/문자열)여도 뒤따르는 정상 레코드를 복구해야 한다.
    func testScalarCorruptElementDoesNotAbortRecovery() throws {
        let good1 = ServerConnection(name: "first", host: "10.0.0.1", username: "u")
        let good2 = ServerConnection(name: "second", host: "10.0.0.2", username: "u")
        let encoder = JSONEncoder()
        let json1 = String(data: try encoder.encode(good1), encoding: .utf8)!
        let json2 = String(data: try encoder.encode(good2), encoding: .utf8)!
        let mixed = "[\(json1), 42, \"garbage\", \(json2)]"
        try Data(mixed.utf8).write(to: fileURL)

        let store = ConnectionStore(fileURL: fileURL)
        XCTAssertEqual(store.connections.map(\.name), ["first", "second"])
        XCTAssertEqual(try backupFiles().count, 1)
    }

    // 일부 레코드만 깨진 경우: 정상 레코드는 복구하고 백업본을 남긴다.
    func testPartiallyCorruptFileRecoversValidRecords() throws {
        let good = ServerConnection(name: "good", host: "10.0.0.1", username: "u")
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let mixed = "[\(goodJSON), {\"id\": \"not-a-uuid\", \"name\": 42}]"
        try Data(mixed.utf8).write(to: fileURL)

        let store = ConnectionStore(fileURL: fileURL)
        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connections.first?.name, "good")
        XCTAssertNotNil(store.loadFailureMessage)
        XCTAssertEqual(try backupFiles().count, 1)
    }
}
