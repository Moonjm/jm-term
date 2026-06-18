// Sources/JMTerm/JMTermApp.swift
import SwiftUI
import AppKit
import OSLog

@main
struct JMTermApp: App {
    @State private var connectionStore = ConnectionStore()

    init() {
        registerRSASHA512()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            SessionCommands()
        }
    }
}

// MARK: - 메뉴 커맨드 & 단축키

private struct SessionCoordinatorFocusedKey: FocusedValueKey {
    typealias Value = SessionCoordinator
}

extension FocusedValues {
    var sessionCoordinator: SessionCoordinator? {
        get { self[SessionCoordinatorFocusedKey.self] }
        set { self[SessionCoordinatorFocusedKey.self] = newValue }
    }
}

/// 터미널 앱 표준 단축키: ⌘W는 창이 아니라 탭을 닫는다.
/// (⌘W 항목이 비활성일 때는 시스템 기본 Close(창 닫기)로 넘어간다)
struct SessionCommands: Commands {
    @FocusedValue(\.sessionCoordinator) private var coordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // ⌘T = 새 탭: 저장된 서버 목록에서 골라 바로 연결 (없으면 새 서버 폼)
            Button("새 탭...") {
                coordinator?.openQuickConnect()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(coordinator == nil)

            Button("재연결") {
                if let coordinator, let session = coordinator.activeSession {
                    coordinator.reconnect(session)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(coordinator?.activeSession?.state != .disconnected)

            Divider()

            Button(coordinator?.activeSession == nil ? "닫기" : "탭 닫기") {
                if let coordinator, let session = coordinator.activeSession {
                    coordinator.closeSession(session)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("창 닫기") {
                closeWindowWithConfirmation()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // 시스템 기본 Close(⌘W)가 위의 탭 닫기와 중복 표시되지 않도록 제거한다.
        // 창 닫기는 위의 '닫기/창 닫기' 항목이 대신한다.
        CommandGroup(replacing: .saveItem) {}

        CommandMenu("탭") {
            Button("다음 탭") { coordinator?.cycleTab(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((coordinator?.sessions.count ?? 0) < 2)

            Button("이전 탭") { coordinator?.cycleTab(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((coordinator?.sessions.count ?? 0) < 2)

            Divider()

            ForEach(1...9, id: \.self) { index in
                Button("탭 \(index)") {
                    if let coordinator, index <= coordinator.sessions.count {
                        coordinator.activeSessionID = coordinator.sessions[index - 1].id
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                .disabled(index > (coordinator?.sessions.count ?? 0))
            }
        }
    }

    private func closeWindowWithConfirmation() {
        guard let window = NSApp.keyWindow else { return }
        let liveCount = coordinator?.sessions.filter(\.isConnected).count ?? 0
        if liveCount > 0 {
            let alert = NSAlert()
            alert.messageText = "창을 닫으시겠습니까?"
            alert.informativeText = "연결 중인 세션 \(liveCount)개가 모두 종료됩니다."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "닫기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        window.performClose(nil)
    }
}

enum SidebarTab {
    case servers
    case files
}

/// SwiftUI 뷰가 속한 NSWindow를 알아내기 위한 헬퍼.
private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onResolve(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let window = nsView.window
        DispatchQueue.main.async { onResolve(window) }
    }
}

struct ContentView: View {
    @State private var coordinator: SessionCoordinator
    @State private var tabSwitchMonitor: Any?
    /// 사이드바 드래그 재정렬 상태.
    @State private var draggingConnectionID: ServerConnection.ID?
    @State private var dropTargetID: ServerConnection.ID?
    /// 서버 목록 방향키 이동을 위한 포커스.
    @FocusState private var serverListFocused: Bool

    init(connectionStore: ConnectionStore) {
        _coordinator = State(initialValue: SessionCoordinator(connectionStore: connectionStore))
    }

    /// ⌃⇥ / ⌃⇧⇥ 순환 이동, ⌃1~9 직접 이동. 터미널 뷰가 키 입력을 선점하므로
    /// 메뉴 단축키에만 의존하지 않고 이벤트 모니터로 직접 처리한다.
    private func installTabSwitchMonitor() {
        guard tabSwitchMonitor == nil else { return }
        let coordinator = self.coordinator
        tabSwitchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Caps Lock이 켜져 있어도 단축키가 동작하도록 비교에서 제외한다.
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            // 로컬 모니터는 앱 전역이므로, 다른 창의 이벤트는 그 창의 모니터에 맡긴다.
            guard event.window === MainActor.assumeIsolated({ coordinator.hostWindow }) else { return event }
            // 시트(다이얼로그)가 떠 있으면 포커스 이동 등 기본 동작에 맡긴다.
            guard !(event.window?.isSheet ?? false) else { return event }

            // ⌃⇥ / ⌃⇧⇥ — 탭 순환
            if event.keyCode == 48, flags == .control || flags == [.control, .shift] {   // 48 = Tab
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard coordinator.sessions.count > 1 else { return false }
                    coordinator.cycleTab(by: flags.contains(.shift) ? -1 : 1)
                    return true
                }
                return handled ? nil : event
            }

            // ⌃1~⌃9 — 해당 번호 탭으로 직접 이동
            if flags == .control,
               let chars = event.charactersIgnoringModifiers,
               chars.count == 1,
               let digit = Int(chars), (1...9).contains(digit) {
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard digit <= coordinator.sessions.count else { return false }
                    coordinator.activeSessionID = coordinator.sessions[digit - 1].id
                    return true
                }
                return handled ? nil : event
            }

            return event
        }
    }

    /// 창이 닫힐 때 모니터를 해제한다 — 남겨두면 stale coordinator가
    /// 이벤트를 선점해 새 창의 탭 전환이 조용히 깨진다.
    private func removeTabSwitchMonitor() {
        if let tabSwitchMonitor {
            NSEvent.removeMonitor(tabSwitchMonitor)
            self.tabSwitchMonitor = nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // 왼쪽: 사이드바 (탭 피커 + 내용)
                VStack(spacing: 0) {
                    if coordinator.isFilesTabAvailable {
                        Picker("", selection: $coordinator.sidebarTab) {
                            Text("서버").tag(SidebarTab.servers)
                            Text("파일").tag(SidebarTab.files)
                        }
                        .pickerStyle(.segmented)
                        .padding(8)

                        Divider()
                    }

                    switch coordinator.sidebarTab {
                    case .servers:
                        serverListView
                    case .files:
                        if let session = coordinator.activeSession {
                            SFTPSidebarView(session: session)
                                .id(session.id)
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                .background(Color(white: 0.1))

                // 오른쪽: 서버 탭 + 터미널
                VStack(spacing: 0) {
                    if !coordinator.sessions.isEmpty {
                        SessionTabBar(coordinator: coordinator)
                    }

                    if let session = coordinator.activeSession {
                        ZStack(alignment: .top) {
                            TerminalViewWrapper(session: session)

                            // 끊긴 세션: 버퍼는 그대로 보여주고 재연결 수단을 제공한다.
                            if session.state == .disconnected {
                                HStack(spacing: 10) {
                                    Image(systemName: "bolt.slash.fill")
                                        .foregroundStyle(.red)
                                    Text(session.statusMessage)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("재연결 (⌘R)") { coordinator.reconnect(session) }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    Button("탭 닫기") { coordinator.closeSession(session) }
                                        .controlSize(.small)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(white: 0.15).opacity(0.95))
                                .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .font(.system(size: 64))
                                .foregroundStyle(.gray)
                            Text("JMTerm")
                                .font(.largeTitle)
                                .foregroundStyle(.gray)
                            Text("서버를 선택하거나 새 연결을 추가하세요")
                                .foregroundStyle(Color(white: 0.4))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                    }
                }
            }

            // 상태 바
            HStack(spacing: 12) {
                if let session = coordinator.activeSession {
                    Circle()
                        .fill(session.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(session.statusMessage)

                    if let stats = session.statsMonitor.stats {
                        Divider().frame(height: 12)

                        Label(String(format: "%.1f%%", stats.cpuUsage), systemImage: "cpu")

                        Divider().frame(height: 12)

                        Label(stats.formattedMemory, systemImage: "memorychip")

                        Divider().frame(height: 12)

                        Label("\(stats.diskUsed)/\(stats.diskTotal) (\(stats.diskPercent))", systemImage: "internaldrive")

                        Divider().frame(height: 12)

                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text("↓\(ServerStats.formatSpeed(stats.netRxSpeed))")
                            Text("↑\(ServerStats.formatSpeed(stats.netTxSpeed))")
                        }
                    }
                } else {
                    Text("연결 없음")
                }
                Spacer()
                Text("build \(BuildInfo.version)")
                    .foregroundStyle(Color(white: 0.35))
            }
            .font(.caption)
            .foregroundStyle(Color(white: 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(white: 0.08))
        }
        .sheet(item: $coordinator.passwordRequest) { request in
            PasswordPromptView(title: "비밀번호 입력", subtitle: request.label) { password in
                coordinator.submitPassword(password)
            } onCancel: {
                coordinator.cancelPassword()
            }
        }
        .sheet(item: $coordinator.connectionDialogMode) { mode in
            ConnectionDialogView(connectionStore: coordinator.connectionStore, mode: mode) { connection, credentials, persist in
                coordinator.startSession(connection, credentials: credentials, persistCredentials: persist)
            } onConnectSaved: { connection in
                // 다이얼로그 시트가 닫히는 중에 비밀번호 프롬프트 시트를 띄우면
                // 프롬프트가 유실되고 자격증명 수집이 영구히 잠길 수 있다 —
                // 시트 전환 딜레이(submitPassword와 동일 패턴) 후 시작한다.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    coordinator.connectToSaved(connection)
                }
            }
        }
        .sheet(item: $coordinator.editingConnection) { conn in
            EditConnectionView(connectionStore: coordinator.connectionStore, connection: conn)
        }
        .sheet(item: $coordinator.hostKeyPrompt, onDismiss: {
            coordinator.handlePromptDismissed()
        }) { prompt in
            HostKeyPromptView(promptType: prompt) { result in
                coordinator.resolveHostKeyPrompt(result: result)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            Task { @MainActor in
                await coordinator.disconnectAll()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sshSessionEnded)) { notification in
            guard let sessionID = notification.object as? UUID else { return }
            coordinator.handleSessionEnded(sessionID: sessionID)
        }
        .onChange(of: coordinator.isFilesTabAvailable) { _, available in
            coordinator.sidebarTab = available ? .files : .servers
        }
        .focusedSceneValue(\.sessionCoordinator, coordinator)
        .background(WindowAccessor { window in coordinator.hostWindow = window })
        .onAppear { installTabSwitchMonitor() }
        .onDisappear { removeTabSwitchMonitor() }
    }

    private func backgroundColor(for conn: ServerConnection) -> Color {
        coordinator.selectedConnectionID == conn.id ? Color.accentColor.opacity(0.2) : Color.clear
    }

    /// 드래그한 행(UUID 문자열)을 target 행 위치로 이동시킨다.
    private func handleDrop(_ items: [String], on target: ServerConnection) -> Bool {
        resetDragState()
        guard let dragged = items.first,
              let draggedID = UUID(uuidString: dragged) else { return false }
        return coordinator.connectionStore.move(draggedID: draggedID, onto: target.id)
    }

    /// 드래그 종료(성공/취소 무관) 시 시각 피드백 상태를 초기화한다.
    private func resetDragState() {
        draggingConnectionID = nil
        dropTargetID = nil
    }

    @ViewBuilder
    private var serverListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("서버 목록")
                    .font(.headline)
                Spacer()
                Button(action: { coordinator.connectionDialogMode = .newServer }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("새 서버 추가")
            }
            .padding(10)
            .background(Color(white: 0.12))

            Divider()

            // connections.json 손상 복구 안내 (백업 경로 포함)
            if let failure = coordinator.connectionStore.loadFailureMessage {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                Divider()
            }

            if coordinator.connectionStore.connections.isEmpty {
                VStack {
                    Spacer()
                    Text("저장된 서버가 없습니다")
                        .foregroundStyle(.secondary)
                    Button("새 연결 추가") { coordinator.connectionDialogMode = .newServer }
                        .padding(.top, 4)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(coordinator.connectionStore.connections) { conn in
                            Button {
                                coordinator.handleServerClick(conn)
                                serverListFocused = true
                            } label: {
                                ServerListRow(connection: conn)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(backgroundColor(for: conn))
                            )
                            .opacity(draggingConnectionID == conn.id ? 0.35 : 1)
                            .contextMenu {
                                Button("연결") { coordinator.connectToSaved(conn) }
                                Button("수정") { coordinator.editingConnection = conn }
                                Divider()
                                Button("삭제", role: .destructive) { coordinator.deleteSaved(conn) }
                            }
                            // 행 전체를 잡아 드래그해 순서를 바꾼다.
                            .draggable(conn.id.uuidString) {
                                ServerListRow(connection: conn)
                                    .frame(width: 220)
                                    .padding(6)
                                    .background(Color(white: 0.18))
                                    .onAppear { draggingConnectionID = conn.id }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                handleDrop(items, on: conn)
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTargetID = conn.id
                                } else if dropTargetID == conn.id {
                                    dropTargetID = nil
                                }
                            }
                            .overlay(alignment: .top) {
                                // 드롭 위치 표시선
                                if dropTargetID == conn.id, draggingConnectionID != conn.id {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.accentColor)
                                        .frame(height: 2)
                                }
                            }
                            .id(conn.id)
                        }
                    }
                    .padding(6)
                    // 행 사이 여백 등 빈 영역에 드롭해도 ghost 상태가 남지 않게 초기화한다.
                    .dropDestination(for: String.self) { _, _ in
                        resetDragState()
                        return false
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($serverListFocused)
                .onKeyPress(.upArrow) { moveServerSelection(by: -1, proxy: proxy); return .handled }
                .onKeyPress(.downArrow) { moveServerSelection(by: 1, proxy: proxy); return .handled }
                .onKeyPress(.return) { connectSelectedServer(); return .handled }
                }
            }
        }
    }

    /// 방향키로 서버 목록 선택을 위/아래 이동(끝에서 반대편으로 순환). 선택이 없으면 양 끝에서 시작.
    private func moveServerSelection(by delta: Int, proxy: ScrollViewProxy) {
        let conns = coordinator.connectionStore.connections
        guard !conns.isEmpty else { return }
        let next: Int
        if let cur = conns.firstIndex(where: { $0.id == coordinator.selectedConnectionID }) {
            next = (cur + delta + conns.count) % conns.count
        } else {
            next = delta > 0 ? 0 : conns.count - 1
        }
        coordinator.selectedConnectionID = conns[next].id
        proxy.scrollTo(conns[next].id)
    }

    /// 현재 선택된 서버로 접속(Enter).
    private func connectSelectedServer() {
        guard let id = coordinator.selectedConnectionID,
              let conn = coordinator.connectionStore.connections.first(where: { $0.id == id })
        else { return }
        coordinator.connectToSaved(conn)
    }
}

struct ServerListRow: View {
    let connection: ServerConnection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name)
                    .fontWeight(.medium)
                Text(verbatim: "\(connection.username)@\(connection.host):\(connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: connection.authMethod == .password ? "key" : "lock.shield")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
