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
                    Label("연결 성공", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
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
    }

    private func testConnection() {
        testState = .testing
        let authMethod: AuthMethod = useKey ? .publicKey(path: keyPath) : .password
        let connection = ServerConnection(
            name: "test",
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod
        )
        let pwd = useKey ? nil : password

        Task {
            do {
                try await SSHSession.testConnection(connection, credentials: ResolvedCredentials(passwords: pwd.map { [connection.id: $0] } ?? [:]))
                testState = .success
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
