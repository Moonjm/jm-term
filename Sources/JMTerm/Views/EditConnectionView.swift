import SwiftUI
import OSLog

struct EditConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionStore: ConnectionStore
    let connection: ServerConnection

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var useKey: Bool
    @State private var keyPath: String

    init(connectionStore: ConnectionStore, connection: ServerConnection) {
        self.connectionStore = connectionStore
        self.connection = connection
        _name = State(initialValue: connection.name)
        _host = State(initialValue: connection.host)
        _port = State(initialValue: String(connection.port))
        _username = State(initialValue: connection.username)
        _password = State(initialValue: connectionStore.loadPassword(for: connection) ?? "")
        if case .publicKey(let path) = connection.authMethod {
            _useKey = State(initialValue: true)
            _keyPath = State(initialValue: path)
        } else {
            _useKey = State(initialValue: false)
            _keyPath = State(initialValue: "~/.ssh/id_ed25519")
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("서버 수정")
                .font(.headline)

            ConnectionFormView(
                name: $name, host: $host, port: $port,
                username: $username, password: $password,
                useKey: $useKey, keyPath: $keyPath
            )

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("저장") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        let authMethod: AuthMethod = useKey ? .publicKey(path: keyPath) : .password
        var updated = connection
        updated.name = name.isEmpty ? "\(username)@\(host)" : name
        updated.host = host
        updated.port = Int(port) ?? 22
        updated.username = username
        updated.authMethod = authMethod

        connectionStore.update(updated)

        if !useKey && !password.isEmpty {
            do {
                try connectionStore.savePassword(password, for: updated)
            } catch {
                Logger.app.error("[EditConnection] 패스워드 저장 에러: \(error)")
            }
        }

        dismiss()
    }
}
