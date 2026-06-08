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
    @FocusState private var hostFocused: Bool

    private enum TestState: Equatable {
        case idle
        case testing
        case success(seconds: Double)
        case failure(String)
    }

    private var canTest: Bool {
        !host.isEmpty && !username.isEmpty && (useKey || !password.isEmpty)
    }

    /// 이름을 비웠을 때 자동 생성되는 값 미리보기.
    private var autoNamePrompt: String {
        let u = username.isEmpty ? "user" : username
        let h = host.isEmpty ? "host" : host
        return "비우면 자동: \(u)@\(h)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Form {
                // 서버: 핵심 필수 항목을 맨 위로.
                TextField("호스트 *", text: $host,
                          prompt: Text("예: 192.168.0.10 또는 server.example.com"))
                    .focused($hostFocused)
                TextField("포트", text: $port, prompt: Text("22"))
                TextField("사용자 *", text: $username, prompt: Text("예: ubuntu, root"))

                // 인증: 토글 대신 명시적 모드 선택(세그먼트).
                Picker("인증", selection: $useKey) {
                    Text("비밀번호").tag(false)
                    Text("SSH 키").tag(true)
                }
                .pickerStyle(.segmented)

                if useKey {
                    LabeledContent("키 파일") { SSHKeyPicker(keyPath: $keyPath) }
                } else {
                    SecureField("비밀번호", text: $password,
                                prompt: Text("비우면 연결 시 물어봅니다"))
                }

                // 이름: host/user에서 파생되므로 맨 아래·선택.
                TextField("이름", text: $name, prompt: Text(autoNamePrompt))
            }

            GroupBox("점프 호스트 경유 (선택)") {
                VStack(alignment: .leading, spacing: 10) {
                    if jumpDrafts.isEmpty {
                        Text("경유 없이 직접 연결합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("내부망 서버 앞의 게이트웨이(배스천)를 거쳐 접속합니다. 좌측 파일 탐색기도 최종 서버를 가리킵니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !jumpDrafts.isEmpty {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach($jumpDrafts) { $draft in
                                    let step = (jumpDrafts.firstIndex(where: { $0.id == draft.id }) ?? 0) + 1
                                    JumpHostRowView(stepLabel: "\(step)단계 · 게이트웨이", draft: $draft) {
                                        jumpDrafts.removeAll { $0.id == draft.id }
                                    }
                                }
                            }
                            .padding(.trailing, 2)
                        }
                        // 호스트가 많아지면 목록만 스크롤 — 다이얼로그가 무한히 길어지지 않도록.
                        .frame(maxHeight: 240)
                    }
                    Button {
                        jumpDrafts.append(JumpHostDraft())
                    } label: {
                        Label(jumpDrafts.isEmpty ? "점프 호스트 추가" : "게이트웨이 추가", systemImage: "plus.circle")
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
                        } else {
                            Image(systemName: "bolt.horizontal")
                        }
                        Text("테스트 연결")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!canTest || testState == .testing)

                Spacer()

                switch testState {
                case .idle:
                    if !canTest {
                        Text("호스트·사용자를 입력하면 테스트할 수 있어요.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        EmptyView()
                    }
                case .testing:
                    Text("연결 테스트 중...")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                case .success(let seconds):
                    Label("연결 성공 · \(String(format: "%.1f초", seconds)) (호스트 키 미검증)", systemImage: "checkmark.circle.fill")
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
        .onAppear {
            // 시트 표시 직후 핵심 필드(호스트)에 포커스.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                hostFocused = true
            }
        }
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

        let start = Date()
        Task {
            do {
                try await SSHSession.testConnection(connection, credentials: creds)
                testState = .success(seconds: Date().timeIntervalSince(start))
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

private struct JumpHostRowView: View {
    let stepLabel: String
    @Binding var draft: JumpHostDraft
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(stepLabel, systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                TextField("호스트", text: $draft.host, prompt: Text("게이트웨이 호스트"))
                TextField("포트", text: $draft.port, prompt: Text("22"))
                    .frame(width: 64)
            }
            TextField("사용자", text: $draft.username, prompt: Text("예: ec2-user"))

            Picker("인증", selection: $draft.useKey) {
                Text("비밀번호").tag(false)
                Text("SSH 키").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if draft.useKey {
                SSHKeyPicker(keyPath: $draft.keyPath)
            } else {
                SecureField("비밀번호", text: $draft.password, prompt: Text("비우면 연결 시 물어봅니다"))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }
}
