// Sources/JMTerm/Services/ConnectionStore.swift
import Foundation
import SwiftUI
import OSLog

@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [ServerConnection] = []
    /// 저장 파일을 읽지 못했을 때 사용자에게 보여줄 메시지 (백업 경로 포함).
    private(set) var loadFailureMessage: String?
    private let fileURL: URL

    /// - Parameter fileURL: 테스트용 주입 지점. nil이면 Application Support 기본 경로 사용.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupport.appendingPathComponent("JMTerm", isDirectory: true)
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            self.fileURL = appDir.appendingPathComponent("connections.json")
        }
        load()
    }

    func add(_ connection: ServerConnection) {
        connections.append(connection)
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let conn = connections[index]
            let account = "\(conn.username)@\(conn.host):\(conn.port)"
            try? KeychainManager.delete(for: account)
            for hop in conn.jumpHosts where hop.authMethod == .password {
                try? KeychainManager.delete(for: hop.keychainAccount)
            }
        }
        connections.remove(atOffsets: offsets)
        save()
    }

    /// 사이드바 드래그 재정렬. 순서는 connections.json 배열 순서로 영속화되어 재시작 후에도 유지된다.
    func move(from source: IndexSet, to destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// 드래그한 항목을 target 항목 자리로 이동시킨다. 실제로 이동했으면 true.
    /// move(fromOffsets:toOffset:)는 destination을 제거 전 인덱스 기준으로 받으므로
    /// 아래로 끌 때(from < to)는 +1 보정해 target '뒤'에, 위로 끌 때는 target '앞'에 놓는다.
    @discardableResult
    func move(draggedID: ServerConnection.ID, onto targetID: ServerConnection.ID) -> Bool {
        guard let from = connections.firstIndex(where: { $0.id == draggedID }),
              let toIndex = connections.firstIndex(where: { $0.id == targetID }),
              from != toIndex else { return false }
        let destination = from < toIndex ? toIndex + 1 : toIndex
        connections.move(fromOffsets: IndexSet(integer: from), toOffset: destination)
        save()
        return true
    }

    func update(_ connection: ServerConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            let old = connections[index]
            let oldAccount = "\(old.username)@\(old.host):\(old.port)"
            let newAccount = "\(connection.username)@\(connection.host):\(connection.port)"

            // Clean up old keychain entry if account changed or switched to key auth
            if oldAccount != newAccount || connection.authMethod != .password {
                try? KeychainManager.delete(for: oldAccount)
            }

            // 점프 호스트가 변경/삭제/키인증 전환된 경우, 더 이상 쓰이지 않는 hop keychain 항목 정리.
            let newHopAccounts = Set(
                connection.jumpHosts
                    .filter { $0.authMethod == .password }
                    .map { $0.keychainAccount }
            )
            for oldHop in old.jumpHosts where oldHop.authMethod == .password {
                if !newHopAccounts.contains(oldHop.keychainAccount) {
                    try? KeychainManager.delete(for: oldHop.keychainAccount)
                }
            }

            connections[index] = connection
            save()
        }
    }

    func savePassword(_ password: String, for connection: ServerConnection) throws {
        let account = "\(connection.username)@\(connection.host):\(connection.port)"
        try KeychainManager.save(password: password, for: account)
    }

    func loadPassword(for connection: ServerConnection) -> String? {
        let account = "\(connection.username)@\(connection.host):\(connection.port)"
        return try? KeychainManager.read(for: account)
    }

    func savePassword(_ password: String, account: String) throws {
        try KeychainManager.save(password: password, for: account)
    }

    func loadPassword(account: String) -> String? {
        try? KeychainManager.read(for: account)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(connections)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.app.error("[ConnectionStore] save 에러: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Logger.app.error("[ConnectionStore] load 에러: \(error)")
            loadFailureMessage = "연결 목록을 읽지 못했습니다: \(error.localizedDescription)"
            return
        }

        do {
            connections = try JSONDecoder().decode([ServerConnection].self, from: data)
        } catch {
            Logger.app.error("[ConnectionStore] load 디코딩 에러: \(error)")
            // 다음 save()가 원본을 덮어쓰기 전에 반드시 백업해 데이터 소실을 막는다.
            let backupName = backupCorruptFile()
            let recovered = (try? JSONDecoder().decode(LossyArray<ServerConnection>.self, from: data).elements) ?? []
            connections = recovered
            if recovered.isEmpty {
                loadFailureMessage = "저장된 연결 목록이 손상되어 불러오지 못했습니다."
            } else {
                loadFailureMessage = "연결 목록 일부가 손상되어 \(recovered.count)개만 복구했습니다."
            }
            if let backupName {
                loadFailureMessage! += " 원본은 \(backupName)으로 백업했습니다."
            }
        }
    }

    /// 손상된 원본을 connections.json.corrupt-<timestamp> 로 복사해 둔다.
    private func backupCorruptFile() -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backupURL = fileURL.appendingPathExtension("corrupt-\(formatter.string(from: Date()))")
        var counter = 1
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = fileURL.appendingPathExtension("corrupt-\(formatter.string(from: Date()))-\(counter)")
            counter += 1
        }
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            return backupURL.lastPathComponent
        } catch {
            Logger.app.error("[ConnectionStore] 손상 파일 백업 실패: \(error)")
            return nil
        }
    }
}

/// 배열 디코딩 시 깨진 원소만 건너뛰고 정상 원소를 살리는 래퍼.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct AnyDecodable: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                result.append(value)
            } else if (try? container.decode(AnyDecodable.self)) == nil {
                // 인덱스를 더 진행할 수 없는 형태 — 무한 루프 방지를 위해 중단.
                break
            }
        }
        elements = result
    }
}
