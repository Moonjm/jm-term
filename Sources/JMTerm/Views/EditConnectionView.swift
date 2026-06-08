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
    @State private var jumpDrafts: [JumpHostDraft]

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
        _jumpDrafts = State(initialValue: connection.jumpHosts.map { hop in
            JumpHostDraft(from: hop, password: connectionStore.loadPassword(account: hop.keychainAccount) ?? "")
        })
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("서버 수정")
                .font(.headline)

            ConnectionFormView(
                name: $name, host: $host, port: $port,
                username: $username, password: $password,
                useKey: $useKey, keyPath: $keyPath,
                jumpDrafts: $jumpDrafts
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
        updated.jumpHosts = jumpDrafts.map { $0.toJumpHost() }

        connectionStore.update(updated)

        if !useKey && !password.isEmpty {
            do {
                try connectionStore.savePassword(password, for: updated)
            } catch {
                Logger.app.error("[EditConnection] 패스워드 저장 에러: \(error)")
            }
        }
        for draft in jumpDrafts where !draft.useKey && !draft.password.isEmpty {
            let hop = draft.toJumpHost()
            do {
                try connectionStore.savePassword(draft.password, account: hop.keychainAccount)
            } catch {
                Logger.app.error("[EditConnection] 점프 패스워드 저장 에러: \(error)")
            }
        }

        dismiss()
    }
}
