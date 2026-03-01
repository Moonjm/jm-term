// Sources/ShellDock/ShellDockApp.swift
import SwiftUI
import AppKit

@main
struct ShellDockApp: App {
    @State private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
        }
        .defaultSize(width: 1200, height: 800)
    }
}

struct ContentView: View {
    let connectionStore: ConnectionStore
    @State private var sessions: [SSHSession] = []
    @State private var activeSessionID: UUID?
    @State private var showConnectionDialog = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var activeSession: SSHSession? {
        sessions.first { $0.id == activeSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 탭 바
            SessionTabBar(
                sessions: $sessions,
                activeSessionID: $activeSessionID,
                onNewConnection: { showConnectionDialog = true }
            )

            // 메인 분할 뷰
            if let session = activeSession {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SFTPSidebarView(session: session)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
                } detail: {
                    TerminalViewWrapper(session: session)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                VStack {
                    Image(systemName: "terminal")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("새 연결을 시작하세요")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Button("연결") { showConnectionDialog = true }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 상태 바
            HStack {
                if let session = activeSession {
                    Circle()
                        .fill(session.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(session.statusMessage)
                } else {
                    Text("연결 없음")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .sheet(isPresented: $showConnectionDialog) {
            ConnectionDialogView(connectionStore: connectionStore) { connection, password in
                let session = SSHSession(connection: connection)
                sessions.append(session)
                activeSessionID = session.id

                Task {
                    try await session.connect(password: password)
                    try await session.openSFTP()
                }
            }
        }
    }
}
