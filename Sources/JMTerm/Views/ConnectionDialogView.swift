// Sources/JMTerm/Views/ConnectionDialogView.swift
import SwiftUI

struct ConnectionDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionStore: ConnectionStore
    /// - Bool: 연결이 성공하면 비밀번호를 keychain에 저장할지(=연결 정보 저장 여부).
    var onConnect: (ServerConnection, ResolvedCredentials, Bool) -> Void
    /// 저장된 서버를 선택했을 때 — keychain/프롬프트 흐름은 coordinator가 처리한다.
    var onConnectSaved: (ServerConnection) -> Void = { _ in }

    /// quickConnect 모드에서 "새 서버 추가..."로 폼으로 전환할 수 있도록 로컬 상태로 유지.
    @State private var showingForm: Bool
    private let mode: ConnectionDialogMode

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var useKey = false
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var jumpDrafts: [JumpHostDraft] = []
    @State private var allowLegacy = false

    /// 저장된 서버 목록에서 방향키로 이동 중인 대상.
    @State private var selectedID: ServerConnection.ID?
    @FocusState private var listFocused: Bool

    init(
        connectionStore: ConnectionStore,
        mode: ConnectionDialogMode = .newServer,
        onConnect: @escaping (ServerConnection, ResolvedCredentials, Bool) -> Void,
        onConnectSaved: @escaping (ServerConnection) -> Void = { _ in }
    ) {
        self.connectionStore = connectionStore
        self.mode = mode
        self.onConnect = onConnect
        self.onConnectSaved = onConnectSaved
        _showingForm = State(initialValue: mode == .newServer)
    }

    var body: some View {
        VStack(spacing: 16) {
            if showingForm {
                newServerForm
            } else {
                quickConnectList
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: - 새 서버 폼 (+ 버튼)

    @ViewBuilder
    private var newServerForm: some View {
        HStack {
            // quickConnect 목록에서 넘어온 경우엔 되돌아갈 길을 제공한다.
            if mode == .quickConnect {
                Button(action: { showingForm = false }) {
                    Label("목록으로", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Text("새 SSH 연결")
                .font(.headline)
            Spacer()
            if mode == .quickConnect {
                // 제목을 가운데 정렬하기 위한 균형추
                Label("목록으로", systemImage: "chevron.left")
                    .hidden()
            }
        }

        ConnectionFormView(
            name: $name, host: $host, port: $port,
            username: $username, password: $password,
            useKey: $useKey, keyPath: $keyPath,
            jumpDrafts: $jumpDrafts,
            allowLegacy: $allowLegacy
        )

        HStack {
            Spacer()
            Button("취소") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("연결") { connect() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty || username.isEmpty)
        }
    }

    // MARK: - 저장된 서버 목록 (⌘T 새 탭)

    @ViewBuilder
    private var quickConnectList: some View {
        Text("서버에 연결")
            .font(.headline)

        if connectionStore.connections.isEmpty {
            // 시트가 떠 있는 동안 다른 창에서 마지막 서버를 지운 경우
            Text("저장된 서버가 없습니다")
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(connectionStore.connections) { conn in
                            Button {
                                onConnectSaved(conn)
                                dismiss()
                            } label: {
                                SavedConnectionRow(
                                    connection: conn,
                                    isSelected: conn.id == selectedID
                                )
                            }
                            .buttonStyle(.plain)
                            .help("클릭하거나 방향키로 선택 후 Enter로 연결합니다")
                            .id(conn.id)
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(connectionStore.connections.count) * 38 + 8, 300))
                .onChange(of: selectedID) { _, newValue in
                    if let newValue { proxy.scrollTo(newValue) }
                }
            }
            .focusable()
            .focused($listFocused)
            .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
            .onKeyPress(.return) { connectSelected(); return .handled }
            .onAppear {
                if selectedID == nil { selectedID = connectionStore.connections.first?.id }
                listFocused = true
            }
        }

        HStack {
            Button("새 서버 추가...") { showingForm = true }
                .buttonStyle(.borderless)
            Spacer()
            Button("취소") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// 방향키로 선택 대상을 위/아래로 이동한다(끝에서 반대편으로 순환).
    private func moveSelection(by delta: Int) {
        let conns = connectionStore.connections
        guard !conns.isEmpty else { return }
        let next: Int
        if let current = conns.firstIndex(where: { $0.id == selectedID }) {
            next = (current + delta + conns.count) % conns.count
        } else {
            next = delta > 0 ? 0 : conns.count - 1
        }
        selectedID = conns[next].id
    }

    /// 현재 선택된 저장 서버로 연결한다(Enter).
    private func connectSelected() {
        guard let id = selectedID,
              let conn = connectionStore.connections.first(where: { $0.id == id })
        else { return }
        onConnectSaved(conn)
        dismiss()
    }

    private func connect() {
        let authMethod: AuthMethod = useKey ? .publicKey(path: keyPath) : .password
        let connection = ServerConnection(
            name: name.isEmpty ? "\(username)@\(host)" : name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            jumpHosts: jumpDrafts.map { $0.toJumpHost() },
            allowLegacyAlgorithms: allowLegacy
        )

        var passwords: [UUID: String] = [:]
        if !useKey && !password.isEmpty { passwords[connection.id] = password }
        for draft in jumpDrafts where !draft.useKey && !draft.password.isEmpty {
            passwords[draft.id] = draft.password
        }

        // 연결 정보는 항상 저장한다. 단, 연결 레코드는 즉시 저장하고 비밀번호는
        // 연결 성공 후에 저장한다(오타가 keychain에 남아 다음 연결에서 조용히
        // 자동 로드되는 것을 방지). persist=true로 coordinator가 성공 시 저장한다.
        connectionStore.add(connection)

        onConnect(connection, ResolvedCredentials(passwords: passwords), true)
        dismiss()
    }
}

/// 다이얼로그용 저장 서버 행 — 호버 시 연결 아이콘으로 클릭 동작을 암시한다.
private struct SavedConnectionRow: View {
    let connection: ServerConnection
    /// 방향키로 선택된 행(키보드 포커스). 호버와 동일한 강조를 준다.
    var isSelected: Bool = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(verbatim: "\(connection.username)@\(connection.host):\(connection.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isHovered || isSelected {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered || isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
