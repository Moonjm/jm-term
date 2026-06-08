// Sources/JMTerm/ViewModels/SessionCoordinator.swift
import Foundation

@MainActor
@Observable
final class SessionCoordinator {
    let connectionStore: ConnectionStore

    var sessions: [SSHSession] = []
    var activeSessionID: UUID?
    var showConnectionDialog = false
    var passwordRequest: PasswordRequest?
    private var passwordQueue: [PasswordRequest] = []
    private var collectedPasswords: [UUID: String] = [:]
    private var pendingConnectionForCredentials: ServerConnection?
    var editingConnection: ServerConnection?
    var selectedConnectionID: ServerConnection.ID?
    var sidebarTab: SidebarTab = .servers
    var hostKeyPrompt: HostKeyPromptType?
    private var hostKeyQueue: [(promptType: HostKeyPromptType, continuation: CheckedContinuation<HostKeyPromptResult, Never>)] = []
    private var promptResolved = false

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
        beginConnect(conn)
    }

    /// 필요한 비밀번호(각 password-auth hop + 타깃)를 keychain에서 모으고,
    /// 빠진 것이 있으면 순차 프롬프트한다. 전부 모이면 연결을 시작한다.
    private func beginConnect(_ conn: ServerConnection) {
        // 이미 자격증명 수집/프롬프트가 진행 중이면 재진입을 무시한다.
        guard pendingConnectionForCredentials == nil else { return }
        collectedPasswords = [:]
        passwordQueue = []
        pendingConnectionForCredentials = conn

        var requests: [PasswordRequest] = []
        for hop in conn.jumpHosts where hop.authMethod == .password {
            if let saved = connectionStore.loadPassword(account: hop.keychainAccount), !saved.isEmpty {
                collectedPasswords[hop.id] = saved
            } else {
                requests.append(PasswordRequest(id: hop.id, label: hop.keychainAccount))
            }
        }
        if conn.authMethod == .password {
            if let saved = connectionStore.loadPassword(account: conn.keychainAccount), !saved.isEmpty {
                collectedPasswords[conn.id] = saved
            } else {
                requests.append(PasswordRequest(id: conn.id, label: conn.keychainAccount))
            }
        }

        if requests.isEmpty {
            launchPending()
        } else {
            passwordQueue = requests
            passwordRequest = passwordQueue.first
        }
    }

    func submitPassword(_ password: String) {
        guard let current = passwordRequest, let conn = pendingConnectionForCredentials else { return }
        collectedPasswords[current.id] = password
        let account = accountFor(id: current.id, in: conn)
        try? connectionStore.savePassword(password, account: account)

        passwordQueue.removeFirst()
        passwordRequest = nil
        if passwordQueue.isEmpty {
            launchPending()
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                passwordRequest = passwordQueue.first
            }
        }
    }

    func cancelPassword() {
        passwordQueue = []
        collectedPasswords = [:]
        passwordRequest = nil
        pendingConnectionForCredentials = nil
    }

    private func launchPending() {
        guard let conn = pendingConnectionForCredentials else { return }
        let creds = ResolvedCredentials(passwords: collectedPasswords)
        pendingConnectionForCredentials = nil
        startSession(conn, credentials: creds)
    }

    private func accountFor(id: UUID, in conn: ServerConnection) -> String {
        if id == conn.id { return conn.keychainAccount }
        if let hop = conn.jumpHosts.first(where: { $0.id == id }) { return hop.keychainAccount }
        return conn.keychainAccount
    }

    func deleteSaved(_ conn: ServerConnection) {
        guard let index = connectionStore.connections.firstIndex(where: { $0.id == conn.id }) else { return }
        connectionStore.remove(at: IndexSet(integer: index))
    }

    func startSession(_ connection: ServerConnection, credentials: ResolvedCredentials) {
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
                try await session.connect(credentials: credentials)
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

    /// 사용자가 응답하지 않고 sheet를 닫았을 때만 reject 처리
    func handlePromptDismissed() {
        if !promptResolved, !hostKeyQueue.isEmpty {
            let entry = hostKeyQueue.removeFirst()
            entry.continuation.resume(returning: .reject)
        }
        promptResolved = false
    }

    func showNextHostKeyPrompt() {
        promptResolved = false
        guard !hostKeyQueue.isEmpty else {
            hostKeyPrompt = nil
            return
        }
        hostKeyPrompt = hostKeyQueue.first?.promptType
    }

    func resolveHostKeyPrompt(result: HostKeyPromptResult) {
        guard !hostKeyQueue.isEmpty else { return }
        promptResolved = true
        let entry = hostKeyQueue.removeFirst()
        entry.continuation.resume(returning: result)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            showNextHostKeyPrompt()
        }
    }
}

struct PasswordRequest: Identifiable, Equatable {
    let id: UUID       // 타깃 connection.id 또는 JumpHost.id
    let label: String  // username@host:port
}
