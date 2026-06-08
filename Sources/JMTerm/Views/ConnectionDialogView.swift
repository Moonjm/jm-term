// Sources/JMTerm/Views/ConnectionDialogView.swift
import SwiftUI

struct ConnectionDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionStore: ConnectionStore
    /// - Bool: 연결이 성공하면 비밀번호를 keychain에 저장할지(=연결 정보 저장 여부).
    var onConnect: (ServerConnection, ResolvedCredentials, Bool) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var useKey = false
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var saveConnection = true
    @State private var jumpDrafts: [JumpHostDraft] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("새 SSH 연결")
                .font(.headline)

            ConnectionFormView(
                name: $name, host: $host, port: $port,
                username: $username, password: $password,
                useKey: $useKey, keyPath: $keyPath,
                jumpDrafts: $jumpDrafts
            )

            Toggle("연결 정보 저장", isOn: $saveConnection)

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("연결") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func connect() {
        let authMethod: AuthMethod = useKey ? .publicKey(path: keyPath) : .password
        let connection = ServerConnection(
            name: name.isEmpty ? "\(username)@\(host)" : name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            jumpHosts: jumpDrafts.map { $0.toJumpHost() }
        )

        var passwords: [UUID: String] = [:]
        if !useKey && !password.isEmpty { passwords[connection.id] = password }
        for draft in jumpDrafts where !draft.useKey && !draft.password.isEmpty {
            passwords[draft.id] = draft.password
        }

        // 연결 레코드는 즉시 저장하되, 비밀번호는 연결 성공 후에 저장한다(오타가
        // keychain에 남아 다음 연결에서 조용히 자동 로드되는 것을 방지).
        // 저장 의도(saveConnection)를 coordinator로 넘겨 startSession 성공 시 저장한다.
        if saveConnection {
            connectionStore.add(connection)
        }

        onConnect(connection, ResolvedCredentials(passwords: passwords), saveConnection)
        dismiss()
    }
}
