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
    /// 자격증명 수집이 끝났을 때 실행할 동작 (새 연결 또는 재연결).
    private var pendingCredentialAction: ((ResolvedCredentials) -> Void)?
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

    /// 활성 탭을 앞/뒤로 순환 이동한다 (⌃⇥ / ⌃⇧⇥).
    func cycleTab(by offset: Int) {
        guard sessions.count > 1,
              let current = sessions.firstIndex(where: { $0.id == activeSessionID })
        else { return }
        let next = (current + offset + sessions.count) % sessions.count
        activeSessionID = sessions[next].id
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
        collectCredentials(for: conn) { [weak self] creds in
            // 저장된 연결로의 접속이므로, 연결이 성공하면 입력받은 비밀번호를 keychain에 저장한다.
            self?.startSession(conn, credentials: creds, persistCredentials: true)
        }
    }

    /// 끊어진 세션을 같은 터미널 버퍼를 유지한 채 다시 연결한다.
    func reconnect(_ session: SSHSession) {
        guard session.state == .disconnected else { return }
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        collectCredentials(for: session.connection) { [weak self] creds in
            session.terminalView?.feed(byteArray: Array("\r\n\u{1b}[33m[재연결 중...]\u{1b}[0m\r\n".utf8)[...])
            self?.launch(into: session, credentials: creds, persistCredentials: true)
        }
    }

    /// 필요한 비밀번호(각 password-auth hop + 타깃)를 keychain에서 모으고,
    /// 빠진 것이 있으면 순차 프롬프트한다. 전부 모이면 onReady를 실행한다.
    private func collectCredentials(for conn: ServerConnection, onReady: @escaping (ResolvedCredentials) -> Void) {
        // 이미 자격증명 수집/프롬프트가 진행 중이면 재진입을 무시한다.
        guard pendingConnectionForCredentials == nil else { return }
        collectedPasswords = [:]
        passwordQueue = []
        pendingConnectionForCredentials = conn
        pendingCredentialAction = onReady

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
        guard let current = passwordRequest else { return }
        // keychain 저장은 연결 성공 후로 미룬다(오타 비밀번호가 저장돼 다음 연결에서
        // 프롬프트 없이 자동 로드되는 것을 방지). startSession(persistCredentials:) 참고.
        collectedPasswords[current.id] = password

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
        pendingCredentialAction = nil
    }

    private func launchPending() {
        guard pendingConnectionForCredentials != nil, let action = pendingCredentialAction else { return }
        let creds = ResolvedCredentials(passwords: collectedPasswords)
        pendingConnectionForCredentials = nil
        pendingCredentialAction = nil
        action(creds)
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

    /// - persistCredentials: 연결이 성공한 뒤에만 입력받은 비밀번호를 keychain에 저장할지 여부.
    ///   프롬프트 흐름(저장된 연결 접속)에서는 true. 새 연결 다이얼로그는 자체적으로
    ///   "연결 정보 저장" 토글에 따라 저장하므로 false(기본값).
    func startSession(_ connection: ServerConnection, credentials: ResolvedCredentials, persistCredentials: Bool = false) {
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
        launch(into: session, credentials: credentials, persistCredentials: persistCredentials)
    }

    /// 세션(신규 또는 재연결)에 대해 연결 → 모니터링/keepalive/SFTP를 순서대로 시작한다.
    private func launch(into session: SSHSession, credentials: ResolvedCredentials, persistCredentials: Bool) {
        Task {
            do {
                try await session.connect(credentials: credentials)
                if persistCredentials {
                    for (id, password) in credentials.passwords {
                        try? connectionStore.savePassword(password, account: accountFor(id: id, in: session.connection))
                    }
                }
                session.startMonitoring()
                session.startKeepalive()
                do {
                    try await session.openSFTP()
                } catch {
                    session.statusMessage = "연결됨 (SFTP 사용 불가)"
                }
                // 재연결: 터미널 뷰가 이미 붙어 있으면 셸도 바로 시작한다.
                // (신규 세션은 TerminalViewWrapper가 뷰 생성 후 시작 — startShell은 중복 호출에 안전)
                if session.terminalView != nil {
                    try? await session.startShell()
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

    /// 세션이 끝나도 탭을 즉시 제거하지 않는다 — 마지막 출력을 보존하고
    /// 재연결 버튼을 제공한다. 리소스(클라이언트 체인·폴링 태스크)는 정리한다.
    func handleSessionEnded(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        Task { await session.disconnect() }
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
