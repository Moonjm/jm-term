// Sources/JMTerm/Views/ConnectionFormView.swift
import SwiftUI

struct ConnectionFormView: View {
    @Binding var name: String
    @Binding var host: String
    @Binding var port: String
    @Binding var username: String
    @Binding var password: String
    @Binding var useKey: Bool
    @Binding var keyPath: String
    @Binding var jumpDrafts: [JumpHostDraft]

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    private var canTest: Bool {
        !host.isEmpty && !username.isEmpty && (useKey || !password.isEmpty)
    }

    var body: some View {
        VStack(spacing: 12) {
            Form {
                TextField("이름", text: $name)
                TextField("호스트", text: $host)
                TextField("포트", text: $port)
                TextField("사용자", text: $username)

                Toggle("SSH 키 사용", isOn: $useKey)
                if useKey {
                    HStack {
                        TextField("키 경로", text: $keyPath)
                        Button("선택...") {
                            let panel = NSOpenPanel()
                            panel.title = "SSH 키 파일 선택"
                            panel.allowsMultipleSelection = false
                            panel.canChooseDirectories = false
                            panel.canChooseFiles = true
                            panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath)
                            if panel.runModal() == .OK, let url = panel.url {
                                keyPath = url.path
                            }
                        }
                    }
                } else {
                    SecureField("비밀번호", text: $password)
                }
            }

            GroupBox("점프 호스트 경유 (선택)") {
                VStack(alignment: .leading, spacing: 8) {
                    if jumpDrafts.isEmpty {
                        Text("경유 없이 직접 연결합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($jumpDrafts) { $draft in
                        JumpHostRowView(draft: $draft) {
                            jumpDrafts.removeAll { $0.id == draft.id }
                        }
                        Divider()
                    }
                    Button {
                        jumpDrafts.append(JumpHostDraft())
                    } label: {
                        Label("점프 호스트 추가", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Divider()

            HStack {
                Button(action: testConnection) {
                    HStack(spacing: 4) {
                        if case .testing = testState {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("테스트 연결")
                    }
                }
                .disabled(!canTest || testState == .testing)

                Spacer()

                switch testState {
                case .idle:
                    EmptyView()
                case .testing:
                    Text("연결 테스트 중...")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                case .success:
                    Label("연결 성공 (호스트 키 미검증)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .help("도달 가능하고 인증에 성공했습니다. 호스트 키 신뢰 확인은 실제 연결 시 이뤄집니다.")
                case .failure(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                        .help(message)
                }
            }
        }
        .onChange(of: host) { testState = .idle }
        .onChange(of: port) { testState = .idle }
        .onChange(of: username) { testState = .idle }
        .onChange(of: password) { testState = .idle }
        .onChange(of: useKey) { testState = .idle }
        .onChange(of: keyPath) { testState = .idle }
        .onChange(of: jumpDrafts) { testState = .idle }
    }

    private func testConnection() {
        testState = .testing
        let authMethod: AuthMethod = useKey ? .publicKey(path: keyPath) : .password
        let connection = ServerConnection(
            name: "test",
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
        let creds = ResolvedCredentials(passwords: passwords)

        Task {
            do {
                try await SSHSession.testConnection(connection, credentials: creds)
                testState = .success
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

private struct JumpHostRowView: View {
    @Binding var draft: JumpHostDraft
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("호스트", text: $draft.host)
                TextField("포트", text: $draft.port)
                    .frame(width: 64)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            TextField("사용자", text: $draft.username)
            Toggle("SSH 키 사용", isOn: $draft.useKey)
            if draft.useKey {
                HStack {
                    TextField("키 경로", text: $draft.keyPath)
                    Button("선택...") {
                        let panel = NSOpenPanel()
                        panel.title = "SSH 키 파일 선택"
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath)
                        if panel.runModal() == .OK, let url = panel.url {
                            draft.keyPath = url.path
                        }
                    }
                }
            } else {
                SecureField("비밀번호", text: $draft.password)
            }
        }
    }
}
