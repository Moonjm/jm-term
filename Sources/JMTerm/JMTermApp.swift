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
    @State private var coordinator: SessionCoordinator

    init(connectionStore: ConnectionStore) {
        _coordinator = State(initialValue: SessionCoordinator(connectionStore: connectionStore))
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
            }
            .font(.caption)
            .foregroundStyle(Color(white: 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(white: 0.08))
        }
        .sheet(isPresented: $coordinator.showPasswordPrompt) {
            PasswordPromptView(connection: coordinator.pendingConnection) { password in
                if let conn = coordinator.pendingConnection {
                    do {
                        try coordinator.connectionStore.savePassword(password, for: conn)
                    } catch {
                        print("[PasswordPrompt] 패스워드 저장 에러: \(error)")
                    }
                    coordinator.startSession(conn, password: password)
                }
                coordinator.pendingConnection = nil
            } onCancel: {
                coordinator.pendingConnection = nil
            }
        }
        .sheet(isPresented: $coordinator.showConnectionDialog) {
            ConnectionDialogView(connectionStore: coordinator.connectionStore) { connection, password in
                coordinator.startSession(connection, password: password)
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
    }

    @ViewBuilder
    private var serverListView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("서버 목록")
                    .font(.headline)
                Spacer()
                Button(action: { coordinator.showConnectionDialog = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color(white: 0.12))

            Divider()

            if coordinator.connectionStore.connections.isEmpty {
                VStack {
                    Spacer()
                    Text("저장된 서버가 없습니다")
                        .foregroundStyle(.secondary)
                    Button("새 연결 추가") { coordinator.showConnectionDialog = true }
                        .padding(.top, 4)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(coordinator.connectionStore.connections) { conn in
                            Button {
                                coordinator.handleServerClick(conn)
                            } label: {
                                ServerListRow(connection: conn)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(coordinator.selectedConnectionID == conn.id ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                            .contextMenu {
                                Button("연결") { coordinator.connectToSaved(conn) }
                                Button("수정") { coordinator.editingConnection = conn }
                                Divider()
                                Button("삭제", role: .destructive) { coordinator.deleteSaved(conn) }
                            }
                        }
                    }
                    .padding(6)
                }
            }
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
