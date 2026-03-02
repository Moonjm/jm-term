// Sources/JMTerm/Views/ConnectionDialogView.swift
import SwiftUI

struct ConnectionDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionStore: ConnectionStore
    var onConnect: (ServerConnection, String?) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var useKey = false
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var saveConnection = true

    var body: some View {
        VStack(spacing: 16) {
            Text("새 SSH 연결")
                .font(.headline)

            ConnectionFormView(
                name: $name, host: $host, port: $port,
                username: $username, password: $password,
                useKey: $useKey, keyPath: $keyPath
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
            authMethod: authMethod
        )

        if saveConnection {
            connectionStore.add(connection)
            if !useKey && !password.isEmpty {
                try? connectionStore.savePassword(password, for: connection)
            }
        }

        onConnect(connection, useKey ? nil : password)
        dismiss()
    }
}
