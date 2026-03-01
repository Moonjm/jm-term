// Sources/ShellDock/Services/ConnectionStore.swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [ServerConnection] = []
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ShellDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.fileURL = appDir.appendingPathComponent("connections.json")
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
        }
        connections.remove(atOffsets: offsets)
        save()
    }

    func update(_ connection: ServerConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
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

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ServerConnection].self, from: data) else { return }
        connections = decoded
    }
}
