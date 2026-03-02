// Sources/JMTerm/Models/ServerConnection.swift
import Foundation

enum AuthMethod: Codable, Hashable, Sendable {
    case password
    case publicKey(path: String)
}

struct ServerConnection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod

    init(name: String, host: String, port: Int = 22, username: String, authMethod: AuthMethod = .password) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}
