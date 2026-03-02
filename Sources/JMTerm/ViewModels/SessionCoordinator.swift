// Sources/JMTerm/ViewModels/SessionCoordinator.swift
import Foundation

@MainActor
@Observable
final class SessionCoordinator {
    let connectionStore: ConnectionStore

    var sessions: [SSHSession] = []
    var activeSessionID: UUID?
    var showConnectionDialog = false
    var showPasswordPrompt = false
    var pendingConnection: ServerConnection?
    var editingConnection: ServerConnection?
    var selectedConnectionID: ServerConnection.ID?
    var sidebarTab: SidebarTab = .servers
    var hostKeyPrompt: HostKeyPromptType?
    private var hostKeyQueue: [(promptType: HostKeyPromptType, continuation: CheckedContinuation<HostKeyPromptResult, Never>)] = []

    var hasQueuedPrompts: Bool { !hostKeyQueue.isEmpty }

    private var lastClickID: ServerConnection.ID?
    private var lastClickDate = Date.distantPast

    init(connectionStore: ConnectionStore) {
        self.connectionStore = connectionStore
    }

    var activeSession: SSHSession? {
        sessions.first { $0.id == activeSessionID }
    }

    var isFilesTabAvailable: Bool {
        activeSession?.isSFTPReady == true
    }

    func handleServerClick(_ conn: ServerConnection) {
        let now = Date()
        if conn.id == lastClickID, now.timeIntervalSince(lastClickDate) < 0.35 {
            connectToSaved(conn)
        } else {
            selectedConnectionID = conn.id
        }
        lastClickID = conn.id
        lastClickDate = now
    }

    func connectToSaved(_ conn: ServerConnection) {
        if case .publicKey = conn.authMethod {
            startSession(conn, password: nil)
        } else if let saved = connectionStore.loadPassword(for: conn), !saved.isEmpty {
            startSession(conn, password: saved)
        } else {
            pendingConnection = conn
            showPasswordPrompt = true
        }
    }

    func deleteSaved(_ conn: ServerConnection) {
        guard let index = connectionStore.connections.firstIndex(where: { $0.id == conn.id }) else { return }
        connectionStore.remove(at: IndexSet(integer: index))
    }

    func startSession(_ connection: ServerConnection, password: String?) {
        let session = SSHSession(connection: connection)
        session.hostKeyPromptHandler = { [weak self] promptType in
            guard let self else { return .reject }
            return await withCheckedContinuation { continuation in
                self.hostKeyQueue.append((promptType, continuation))
                if self.hostKeyPrompt == nil {
                    self.showNextHostKeyPrompt()
                }
            }
        }
        sessions.append(session)
        activeSessionID = session.id

        Task {
            do {
                try await session.connect(password: password)
                session.startMonitoring()
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

    func closeSession(_ session: SSHSession) {
        Task { await session.disconnect() }
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    func handleSessionEnded(sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        if activeSessionID == sessionID {
            activeSessionID = sessions.first?.id
        }
    }

    func disconnectAll() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.disconnect() }
            }
        }
    }

    func showNextHostKeyPrompt() {
        guard !hostKeyQueue.isEmpty else {
            hostKeyPrompt = nil
            return
        }
        hostKeyPrompt = hostKeyQueue.first?.promptType
    }

    func resolveHostKeyPrompt(result: HostKeyPromptResult) {
        guard !hostKeyQueue.isEmpty else { return }
        let entry = hostKeyQueue.removeFirst()
        entry.continuation.resume(returning: result)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            showNextHostKeyPrompt()
        }
    }
}
