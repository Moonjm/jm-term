// Sources/JMTerm/JMTermApp.swift
import SwiftUI
import AppKit

@main
struct JMTermApp: App {
    @State private var connectionStore = ConnectionStore()

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
    }
}

enum SidebarTab {
    case servers
    case files
}

struct ContentView: View {
    let connectionStore: ConnectionStore
    @State private var sessions: [SSHSession] = []
    @State private var activeSessionID: UUID?
    @State private var showConnectionDialog = false
    @State private var showPasswordPrompt = false
    @State private var promptPassword = ""
    @State private var pendingConnection: ServerConnection?
    @State private var editingConnection: ServerConnection?
    @State private var selectedConnectionID: ServerConnection.ID?
    @State private var lastClickID: ServerConnection.ID?
    @State private var lastClickDate = Date.distantPast
    @State private var sidebarTab: SidebarTab = .servers
    @State private var hostKeyPrompt: HostKeyPromptType?
    @State private var hostKeyQueue: [(promptType: HostKeyPromptType, continuation: CheckedContinuation<Bool, Never>)] = []

    private var activeSession: SSHSession? {
        sessions.first { $0.id == activeSessionID }
    }

    private var isFilesTabAvailable: Bool {
        activeSession?.isSFTPReady == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // 왼쪽: 사이드바 (탭 피커 + 내용)
                VStack(spacing: 0) {
                    if isFilesTabAvailable {
                        Picker("", selection: $sidebarTab) {
                            Text("서버").tag(SidebarTab.servers)
                            Text("파일").tag(SidebarTab.files)
                        }
                        .pickerStyle(.segmented)
                        .padding(8)

                        Divider()
                    }

                    switch sidebarTab {
                    case .servers:
                        serverListView
                    case .files:
                        if let session = activeSession {
                            SFTPSidebarView(session: session)
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                .background(Color(white: 0.1))

                // 오른쪽: 서버 탭 + 터미널
                VStack(spacing: 0) {
                    if !sessions.isEmpty {
                        SessionTabBar(
                            sessions: $sessions,
                            activeSessionID: $activeSessionID
                        )
                    }

                    if let session = activeSession {
                        TerminalViewWrapper(session: session)
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
                if let session = activeSession {
                    Circle()
                        .fill(session.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(session.statusMessage)

                    if let stats = session.stats {
                        Divider().frame(height: 12)

                        Label(String(format: "%.1f%%", stats.cpuUsage), systemImage: "cpu")

                        Divider().frame(height: 12)

                        Label(formatMemory(used: stats.memUsed, total: stats.memTotal), systemImage: "memorychip")

                        Divider().frame(height: 12)

                        Label("\(stats.diskUsed)/\(stats.diskTotal) (\(stats.diskPercent))", systemImage: "internaldrive")

                        Divider().frame(height: 12)

                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text("↓\(formatSpeed(stats.netRxSpeed))")
                            Text("↑\(formatSpeed(stats.netTxSpeed))")
                        }
                    }
                } else {
                    Text("연결 없음")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(Color(white: 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(white: 0.08))
        }
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(connection: pendingConnection) { password in
                if let conn = pendingConnection {
                    try? connectionStore.savePassword(password, for: conn)
                    startSession(conn, password: password)
                }
                pendingConnection = nil
            } onCancel: {
                pendingConnection = nil
            }
        }
        .sheet(isPresented: $showConnectionDialog) {
            ConnectionDialogView(connectionStore: connectionStore) { connection, password in
                startSession(connection, password: password)
            }
        }
        .sheet(item: $editingConnection) { conn in
            EditConnectionView(connectionStore: connectionStore, connection: conn)
        }
        .sheet(item: $hostKeyPrompt, onDismiss: {
            // Esc 등으로 시트가 닫힐 때 대기 중인 continuation이 멈추지 않도록 처리
            if !hostKeyQueue.isEmpty {
                resolveHostKeyPrompt(accepted: false)
            }
        }) { prompt in
            HostKeyPromptView(promptType: prompt) {
                resolveHostKeyPrompt(accepted: true)
            } onReject: {
                resolveHostKeyPrompt(accepted: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // Best-effort cleanup: 앱 종료 시 프로세스가 먼저 끝날 수 있음
            let activeSessions = sessions
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    for session in activeSessions {
                        group.addTask { await session.disconnect() }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sshSessionEnded)) { notification in
            guard let sessionID = notification.object as? UUID else { return }
            sessions.removeAll { $0.id == sessionID }
            if activeSessionID == sessionID {
                activeSessionID = sessions.first?.id
            }
        }
        .onChange(of: isFilesTabAvailable) { _, available in
            if available {
                sidebarTab = .files
            } else {
                sidebarTab = .servers
            }
        }
    }

    @ViewBuilder
    private var serverListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("서버 목록")
                    .font(.headline)
                Spacer()
                Button(action: { showConnectionDialog = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color(white: 0.12))

            Divider()

            if connectionStore.connections.isEmpty {
                VStack {
                    Spacer()
                    Text("저장된 서버가 없습니다")
                        .foregroundStyle(.secondary)
                    Button("새 연결 추가") { showConnectionDialog = true }
                        .padding(.top, 4)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(connectionStore.connections) { conn in
                            Button {
                                let now = Date()
                                if conn.id == lastClickID, now.timeIntervalSince(lastClickDate) < 0.35 {
                                    connectToSaved(conn)
                                } else {
                                    selectedConnectionID = conn.id
                                }
                                lastClickID = conn.id
                                lastClickDate = now
                            } label: {
                                ServerListRow(connection: conn)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selectedConnectionID == conn.id ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                            .contextMenu {
                                Button("연결") { connectToSaved(conn) }
                                Button("수정") { editingConnection = conn }
                                Divider()
                                Button("삭제", role: .destructive) { deleteSaved(conn) }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func connectToSaved(_ conn: ServerConnection) {
        if case .publicKey = conn.authMethod {
            startSession(conn, password: nil)
        } else if let saved = connectionStore.loadPassword(for: conn), !saved.isEmpty {
            startSession(conn, password: saved)
        } else {
            pendingConnection = conn
            showPasswordPrompt = true
        }
    }

    private func deleteSaved(_ conn: ServerConnection) {
        guard let index = connectionStore.connections.firstIndex(where: { $0.id == conn.id }) else { return }
        connectionStore.remove(at: IndexSet(integer: index))
    }

    private func startSession(_ connection: ServerConnection, password: String?) {
        let session = SSHSession(connection: connection)
        session.hostKeyPromptHandler = { [self] promptType in
            await withCheckedContinuation { continuation in
                hostKeyQueue.append((promptType, continuation))
                if hostKeyPrompt == nil {
                    showNextHostKeyPrompt()
                }
            }
        }
        sessions.append(session)
        activeSessionID = session.id

        Task {
            do {
                try await session.connect(password: password)
                session.startStatsMonitor()
                do {
                    try await session.openSFTP()
                } catch {
                    session.statusMessage = "연결됨 (SFTP 사용 불가)"
                }
            } catch {
                session.statusMessage = "연결 실패: \(error.localizedDescription)"
            }
        }
    }

    private func showNextHostKeyPrompt() {
        guard !hostKeyQueue.isEmpty else {
            hostKeyPrompt = nil
            return
        }
        hostKeyPrompt = hostKeyQueue.first?.promptType
    }

    private func resolveHostKeyPrompt(accepted: Bool) {
        guard !hostKeyQueue.isEmpty else { return }
        let entry = hostKeyQueue.removeFirst()
        entry.continuation.resume(returning: accepted)
        // Show next queued prompt after a short delay for sheet dismissal
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            showNextHostKeyPrompt()
        }
    }

    private func formatMemory(used: UInt64, total: UInt64) -> String {
        let usedGB = Double(used) / 1_048_576.0
        let totalGB = Double(total) / 1_048_576.0
        return String(format: "%.1f/%.1fGB", usedGB, totalGB)
    }

    private func formatSpeed(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec)B/s"
        } else if bytesPerSec < 1_048_576 {
            return String(format: "%.1fKB/s", Double(bytesPerSec) / 1024.0)
        } else {
            return String(format: "%.1fMB/s", Double(bytesPerSec) / 1_048_576.0)
        }
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
