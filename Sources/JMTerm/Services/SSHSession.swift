// Sources/JMTerm/Services/SSHSession.swift
import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
import CCryptoBoringSSL
import SwiftTerm
import OSLog

// MARK: - Sendable wrapper for non-Sendable SSH types

/// Wraps a non-Sendable value so it can cross isolation boundaries.
/// Safety: The caller must ensure that the wrapped value is only accessed
/// from the appropriate context (e.g., always from @MainActor).
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Callback type for host key verification UI.
typealias HostKeyPromptHandler = @MainActor (HostKeyPromptType) async -> HostKeyPromptResult

/// Thread-safe one-shot resolver for async result passing across isolation boundaries.
/// resolve()가 wait()보다 먼저 와도 결과를 보관했다가 즉시 반환한다.
final class OnceResolver: Sendable {
    private let state = ManagedCriticalState<(result: Result<Void, Error>?, continuation: CheckedContinuation<Void, Error>?)>(
        (result: nil, continuation: nil)
    )

    func resolve(with result: Result<Void, Error>) {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Error>? in
            guard s.result == nil else { return nil }
            s.result = result
            let c = s.continuation
            s.continuation = nil
            return c
        }
        continuation?.resume(with: result)
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let stored = state.withLock { s -> Result<Void, Error>? in
                if let result = s.result { return result }
                s.continuation = continuation
                return nil
            }
            if let stored { continuation.resume(with: stored) }
        }
    }
}

/// Minimal lock-based critical state for Sendable conformance.
final class ManagedCriticalState<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()
    init(_ state: State) { self.state = state }
    func withLock<R>(_ body: (inout State) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

@MainActor
@Observable
final class SSHSession: Identifiable {
    let id = UUID()
    let connection: ServerConnection
    var isConnected = false
    var statusMessage = "연결 대기 중"
    let statsMonitor = StatsMonitor()
    let sftpService = SFTPService()

    var isSFTPReady: Bool { sftpService.isSFTPReady }
    var currentPath: String {
        get { sftpService.currentPath }
        set { sftpService.currentPath = newValue }
    }

    /// Set this before calling connect() to enable host key verification UI.
    var hostKeyPromptHandler: HostKeyPromptHandler?

    // These properties hold non-Sendable types from Citadel.
    // They are only accessed on @MainActor. We use UncheckedSendableBox
    // when passing them to nonisolated Citadel async methods.
    private var client: SSHClient?
    private var jumpClients: [SSHClient] = []
    private var stdinWriter: TTYStdinWriter?
    private var cwdPollingTask: Task<Void, Never>?
    weak var terminalView: TerminalView?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private nonisolated static func resolveAuthMethod(
        authMethod: AuthMethod, username: String, password: String?
    ) throws -> SSHAuthenticationMethod {
        switch authMethod {
        case .password:
            guard let password else { throw SSHSessionError.passwordRequired }
            return .passwordBased(username: username, password: password)
        case .publicKey(let path):
            let expandedPath = NSString(string: path).expandingTildeInPath
            let keyString = try String(contentsOfFile: expandedPath, encoding: .utf8)
            return try SSHKeyHelper.authenticationMethod(fromPrivateKey: keyString, username: username)
        }
    }

    private nonisolated static func resolveAuthMethod(
        _ connection: ServerConnection, password: String?
    ) throws -> SSHAuthenticationMethod {
        try resolveAuthMethod(authMethod: connection.authMethod, username: connection.username, password: password)
    }

    // jump(to:) 는 @Sendable () -> SSHAuthenticationMethod 를 요구한다.
    // SSHAuthenticationMethod 는 non-Sendable 이므로 Sendable 원시값만 캡처하고
    // 클로저 내부에서 생성한다. publicKey 의 경우 형식 오류를 즉시 표면화하기 위해
    // 미리 한 번 파싱해 본다(성공 시 클로저 내부 재파싱은 안전).
    private nonisolated static func makeAuthClosure(
        authMethod: AuthMethod, username: String, password: String?
    ) throws -> @Sendable () -> SSHAuthenticationMethod {
        switch authMethod {
        case .password:
            guard let password else { throw SSHSessionError.passwordRequired }
            return { .passwordBased(username: username, password: password) }
        case .publicKey(let path):
            let expandedPath = NSString(string: path).expandingTildeInPath
            let keyString = try String(contentsOfFile: expandedPath, encoding: .utf8)
            _ = try SSHKeyHelper.authenticationMethod(fromPrivateKey: keyString, username: username)
            return {
                (try? SSHKeyHelper.authenticationMethod(fromPrivateKey: keyString, username: username))
                    ?? .passwordBased(username: username, password: "")
            }
        }
    }

    private nonisolated static func makeJumpSettings(
        host: String, port: Int, authMethod: AuthMethod, username: String,
        password: String?, validator: SSHHostKeyValidator
    ) throws -> SSHClientSettings {
        let authClosure = try makeAuthClosure(authMethod: authMethod, username: username, password: password)
        var settings = SSHClientSettings(
            host: host, port: port,
            authenticationMethod: authClosure,
            hostKeyValidator: validator
        )
        settings.algorithms = .all
        return settings
    }

    func connect(credentials: ResolvedCredentials) async throws {
        statusMessage = "연결 중..."
        if connection.jumpHosts.isEmpty {
            try await connectDirect(password: credentials.passwords[connection.id])
        } else {
            try await connectViaJumpChain(credentials: credentials)
        }
    }

    private func connectDirect(password: String?) async throws {
        let authMethod = try Self.resolveAuthMethod(connection, password: password)
        let hostKeyValidator = buildHostKeyValidator(host: connection.host, port: connection.port)

        var sshClient: SSHClient?
        var lastError: Error?
        for attempt in 1...3 {
            do {
                sshClient = try await SSHClient.connect(
                    host: connection.host,
                    port: connection.port,
                    authenticationMethod: authMethod,
                    hostKeyValidator: hostKeyValidator,
                    reconnect: .never,
                    algorithms: .all
                )
                break
            } catch {
                lastError = error
                if attempt < 3 {
                    statusMessage = "연결 재시도 중... (\(attempt)/3)"
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        guard let sshClient else { throw lastError ?? SSHSessionError.notConnected }

        self.client = sshClient
        isConnected = true
        statusMessage = "연결됨: \(connection.username)@\(connection.host):\(connection.port)"
    }

    private func connectViaJumpChain(credentials: ResolvedCredentials) async throws {
        var clients: [SSHClient] = []

        do {
            // 1) 최초 바스티온만 실제 TCP 연결.
            let first = connection.jumpHosts[0]
            let firstAuth = try Self.resolveAuthMethod(
                authMethod: first.authMethod, username: first.username, password: credentials.passwords[first.id]
            )
            statusMessage = "바스티온 연결 중: \(first.host)"
            let firstClient = try await SSHClient.connect(
                host: first.host,
                port: first.port,
                authenticationMethod: firstAuth,
                hostKeyValidator: buildHostKeyValidator(host: first.host, port: first.port),
                reconnect: .never,
                algorithms: .all
            )
            clients.append(firstClient)

            // 2) 나머지 hop 들을 순서대로 jump.
            var current = firstClient
            for hop in connection.jumpHosts.dropFirst() {
                let settings = try Self.makeJumpSettings(
                    host: hop.host, port: hop.port, authMethod: hop.authMethod,
                    username: hop.username, password: credentials.passwords[hop.id],
                    validator: buildHostKeyValidator(host: hop.host, port: hop.port)
                )
                statusMessage = "경유 연결 중: \(hop.host)"
                let next = try await current.jump(to: settings)
                clients.append(next)
                current = next
            }

            // 3) 최종 내부 서버로 jump.
            let targetSettings = try Self.makeJumpSettings(
                host: connection.host, port: connection.port, authMethod: connection.authMethod,
                username: connection.username, password: credentials.passwords[connection.id],
                validator: buildHostKeyValidator(host: connection.host, port: connection.port)
            )
            statusMessage = "내부 서버 연결 중: \(connection.host)"
            let targetClient = try await current.jump(to: targetSettings)

            self.client = targetClient
            self.jumpClients = clients
            isConnected = true
            statusMessage = "연결됨: \(connection.username)@\(connection.host):\(connection.port)"
        } catch {
            // 체인 도중 실패 시 이미 열린 클라이언트를 깊은 쪽(마지막)부터 닫는다.
            for c in clients.reversed() {
                let box = UncheckedSendableBox(value: c)
                try? await box.value.close()
            }
            throw error
        }
    }

    private func buildHostKeyValidator(host: String, port: Int) -> SSHHostKeyValidator {
        let status = KnownHostsManager.lookup(host: host, port: port)
        let knownKeys: Set<NIOSSHPublicKey>? = if case .trusted(let keys) = status { keys } else { nil }

        let validator = HostKeyValidationDelegate(
            knownKeys: knownKeys,
            host: host,
            port: port,
            promptHandler: hostKeyPromptHandler
        )
        return .custom(validator)
    }

    // 프롬프트 없이 known_hosts 만으로 검증 (testConnection 용).
    //
    // 보안 주의: testConnection은 UI를 띄우지 않는 도달성/인증 확인 용도라,
    // known_hosts에 없는(=처음 보는) 호스트 키는 acceptAnything으로 통과시킨다.
    // 즉 "테스트 성공"은 도달 가능·인증 성공을 뜻할 뿐, 호스트 키가 검증/신뢰됐다는
    // 의미가 아니다(특히 바스티온이 MITM에 노출될 수 있음). 실제 연결 경로는
    // buildHostKeyValidator(host:port:)로 미지/불일치 키를 사용자에게 프롬프트해
    // 정상 검증한다.
    private nonisolated static func nonPromptingValidator(host: String, port: Int) -> SSHHostKeyValidator {
        let status = KnownHostsManager.lookup(host: host, port: port)
        if case .trusted(let keys) = status {
            return .trustedKeys(keys)
        }
        return .acceptAnything()
    }

    func startShell() async throws {
        guard let client else { return }
        guard let terminalView else { return }

        // /etc/motd 와 /run/motd.dynamic 을 SFTP로 직접 읽어 표시.
        // 일부 sshd/PAM 조합이 우리 세션에 대해 MOTD를 emit하지 않는 경우가 있어,
        // ssh CLI에서 보이는 내용을 동일하게 보장하려고 SFTP로 우회한다.
        // SFTP가 ready될 때까지 최대 2초까지만 대기.
        for _ in 0..<20 {
            if sftpService.isSFTPReady { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if sftpService.isSFTPReady {
            await sftpService.readMOTD(terminalView: terminalView)
        }

        let terminal = terminalView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows

        // PTY 모드는 기본값으로 — ECHO 등 termios는 서버 셸이 관리하도록 위임.
        // 클라이언트는 stdin 주입을 하지 않는다.
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        let clientBox = UncheckedSendableBox(value: client)
        let termViewBox = UncheckedSendableBox(value: terminalView)
        let sessionBox = UncheckedSendableBox<SSHSession>(value: self)

        // CWD 폴링 시작 — PTY 셸이 시작되면 /proc/$PID/cwd 를 주기적으로 읽어
        // 사이드바를 셸의 현재 디렉토리에 자동 동기화.
        startCWDPolling()

        // 별도 스레드에서 PTY 세션 실행 (메인스레드 블로킹 방지)
        Task.detached {
            do {
                try await clientBox.value.withPTY(ptyRequest) { inbound, outbound in
                    let writerBox = UncheckedSendableBox(value: outbound)
                    await MainActor.run {
                        sessionBox.value.stdinWriter = writerBox.value
                    }

                    for try await event in inbound {
                        switch event {
                        case .stdout(let buffer), .stderr(let buffer):
                            let bytes = Array(buffer.readableBytesView)
                            await MainActor.run {
                                termViewBox.value.feed(byteArray: bytes[...])
                            }
                        }
                    }

                    await MainActor.run {
                        sessionBox.value.isConnected = false
                        sessionBox.value.statusMessage = "연결 종료됨"
                        NotificationCenter.default.post(name: .sshSessionEnded, object: sessionBox.value.id)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    sessionBox.value.isConnected = false
                    sessionBox.value.statusMessage = "연결 종료됨"
                    NotificationCenter.default.post(name: .sshSessionEnded, object: sessionBox.value.id)
                }
            } catch {
                Logger.app.error("셸 오류: \(error)")
                await MainActor.run {
                    sessionBox.value.isConnected = false
                    sessionBox.value.statusMessage = "셸 오류: \(error.localizedDescription)"
                    NotificationCenter.default.post(name: .sshSessionEnded, object: sessionBox.value.id)
                }
            }
        }
    }

    func sendToShell(_ data: Data) {
        guard let stdinWriter else { return }
        let writerBox = UncheckedSendableBox(value: stdinWriter)
        let buffer = ByteBuffer(data: data)
        Task.detached {
            try await writerBox.value.write(buffer)
        }
    }

    func resizeTerminal(cols: Int, rows: Int) {
        guard let stdinWriter else { return }
        let writerBox = UncheckedSendableBox(value: stdinWriter)
        Task.detached {
            try await writerBox.value.changeSize(
                cols: cols, rows: rows,
                pixelWidth: 0, pixelHeight: 0
            )
        }
    }

    // MARK: - CWD Polling
    //
    // Tracks the interactive shell's current working directory by reading
    // /proc/<PID>/cwd over a separate exec channel. Linux 전용 (Raspberry Pi OS,
    // Ubuntu, Debian 등에서 동작). 가장 최근 시작된 사용자 셸 프로세스를
    // 휴리스틱으로 선택하므로 같은 사용자가 다중 SSH 세션을 동시에 열면 부정확할 수
    // 있다. stdin 주입 없이 동작하므로 프롬프트 시각 부작용은 없음.

    func startCWDPolling() {
        guard let client else { return }
        let username = connection.username
        let clientBox = UncheckedSendableBox(value: client)

        cwdPollingTask?.cancel()
        cwdPollingTask = Task.detached { [weak self] in
            // 우리 SSH 세션의 인터랙티브 셸 PID 식별:
            //   1) $SSH_CONNECTION 이 우리 세션과 동일한 사용자 프로세스를 찾음
            //   2) 그 중 pts/* TTY가 붙은 것(=셸 본체) 중 PID가 가장 작은 것(=가장 오래된 = 셸 자체) 선택
            // 자식 프로세스(vim 등)는 PID가 더 커서 자연히 제외됨. 다중 SSH 세션도 SSH_CONNECTION으로 정확히 구분됨.
            let pidCmd = """
            conn="$SSH_CONNECTION"
            {
              for p in $(ps -u \(username) -o pid= --no-headers 2>/dev/null | sort -n); do
                if grep -aqF "SSH_CONNECTION=$conn" "/proc/$p/environ" 2>/dev/null; then
                  t=$(ps -p "$p" -o tty= 2>/dev/null | tr -d ' \\n')
                  case "$t" in pts/*) printf '%s\\n' "$p"; break ;; esac
                fi
              done
            } | head -1
            """
            var pid: String?
            for _ in 0..<10 {
                if Task.isCancelled { return }
                if let buf = try? await clientBox.value.executeCommand(pidCmd, inShell: true) {
                    let raw = String(buffer: buf)
                    // 응답에 MOTD/lastlog가 섞일 수 있으므로 마지막 숫자만 추출
                    let lastNumeric = raw
                        .split(whereSeparator: { $0.isNewline })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .last(where: { Int($0) != nil })
                    if let lastNumeric, !lastNumeric.isEmpty {
                        pid = lastNumeric
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let pid else {
                Logger.app.error("[CWD] PID 식별 실패 — 폴링 중단")
                return
            }

            // /proc/<PID>/cwd 주기적 폴링 (500ms 간격).
            // exit 코드 1을 받으면 (CommandFailed) shell wrapping으로 || true 처리해
            // 빈 결과를 정상 반환받게 한다.
            var lastCwd: String?
            while !Task.isCancelled {
                if let buf = try? await clientBox.value.executeCommand(
                    "readlink /proc/\(pid)/cwd || true",
                    inShell: true
                ) {
                    let cwd = String(buffer: buf)
                        .split(whereSeparator: { $0.isNewline })
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .last(where: { $0.hasPrefix("/") }) ?? ""
                    if cwd != lastCwd {
                        lastCwd = cwd
                        if !cwd.isEmpty {
                            await MainActor.run { [weak self] in
                                self?.currentPath = cwd
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopCWDPolling() {
        cwdPollingTask?.cancel()
        cwdPollingTask = nil
    }

    // MARK: - Test Connection

    /// 직접 또는 체인 연결을 시도하고 즉시 닫아 도달성을 검증한다. 프롬프트 없음.
    nonisolated static func testConnection(
        _ connection: ServerConnection,
        credentials: ResolvedCredentials,
        timeout: Duration = .seconds(10)
    ) async throws {
        let connectionBox = UncheckedSendableBox(value: connection)
        let credsBox = UncheckedSendableBox(value: credentials)
        let resolver = OnceResolver()

        let connectTask = Task.detached {
            do {
                let conn = connectionBox.value
                let creds = credsBox.value
                if conn.jumpHosts.isEmpty {
                    let auth = try resolveAuthMethod(conn, password: creds.passwords[conn.id])
                    let client = try await SSHClient.connect(
                        host: conn.host, port: conn.port,
                        authenticationMethod: auth,
                        hostKeyValidator: nonPromptingValidator(host: conn.host, port: conn.port),
                        reconnect: .never, algorithms: .all
                    )
                    try? await client.close()
                } else {
                    var openClients: [SSHClient] = []
                    do {
                        let first = conn.jumpHosts[0]
                        let firstAuth = try resolveAuthMethod(
                            authMethod: first.authMethod, username: first.username,
                            password: creds.passwords[first.id]
                        )
                        let firstClient = try await SSHClient.connect(
                            host: first.host, port: first.port,
                            authenticationMethod: firstAuth,
                            hostKeyValidator: nonPromptingValidator(host: first.host, port: first.port),
                            reconnect: .never, algorithms: .all
                        )
                        openClients.append(firstClient)
                        var current = firstClient
                        for hop in conn.jumpHosts.dropFirst() {
                            let settings = try makeJumpSettings(
                                host: hop.host, port: hop.port, authMethod: hop.authMethod,
                                username: hop.username, password: creds.passwords[hop.id],
                                validator: nonPromptingValidator(host: hop.host, port: hop.port)
                            )
                            let next = try await current.jump(to: settings)
                            openClients.append(next)
                            current = next
                        }
                        let targetSettings = try makeJumpSettings(
                            host: conn.host, port: conn.port, authMethod: conn.authMethod,
                            username: conn.username, password: creds.passwords[conn.id],
                            validator: nonPromptingValidator(host: conn.host, port: conn.port)
                        )
                        let targetClient = try await current.jump(to: targetSettings)
                        try? await targetClient.close()
                        for c in openClients.reversed() { try? await c.close() }
                    } catch {
                        // 체인 도중 실패 시 이미 열린 클라이언트를 정리한다.
                        for c in openClients.reversed() {
                            let box = UncheckedSendableBox(value: c)
                            try? await box.value.close()
                        }
                        throw error
                    }
                }
                resolver.resolve(with: .success(()))
            } catch {
                resolver.resolve(with: .failure(error))
            }
        }

        Task.detached {
            try? await Task.sleep(for: timeout)
            connectTask.cancel()
            resolver.resolve(with: .failure(SSHSessionError.connectionTimeout))
        }

        try await resolver.wait()
    }

    // MARK: - Monitoring & SFTP

    func startMonitoring() {
        guard let client else { return }
        statsMonitor.start(client: client)
    }

    func openSFTP() async throws {
        guard let client else { return }
        try await sftpService.open(client: client)
    }

    func disconnect() async {
        statsMonitor.stop()
        stopCWDPolling()
        await sftpService.close()
        if let client {
            let clientBox = UncheckedSendableBox(value: client)
            try? await clientBox.value.close()
        }
        // 바스티온/중간 클라이언트를 깊은 쪽(마지막)부터 역순으로 닫는다.
        for c in jumpClients.reversed() {
            let box = UncheckedSendableBox(value: c)
            try? await box.value.close()
        }
        client = nil
        jumpClients = []
        stdinWriter = nil
        isConnected = false
        statusMessage = "연결 끊김"
        statsMonitor.stats = nil
    }
}

// MARK: - Host Key Validation Delegate

/// Custom NIOSSHClientServerAuthenticationDelegate that validates host keys
/// against known_hosts and prompts the user for unknown/mismatched keys.
private final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let knownKeys: Set<NIOSSHPublicKey>?
    let host: String
    let port: Int
    let promptHandler: HostKeyPromptHandler?

    init(knownKeys: Set<NIOSSHPublicKey>?, host: String, port: Int, promptHandler: HostKeyPromptHandler?) {
        self.knownKeys = knownKeys
        self.host = host
        self.port = port
        self.promptHandler = promptHandler
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let host = self.host
        let port = self.port
        let knownKeys = self.knownKeys
        let promptHandler = self.promptHandler

        if let knownKeys, knownKeys.contains(hostKey) {
            validationCompletePromise.succeed(())
            return
        }

        // Compute fingerprints outside MainActor boundary to avoid sendability issues
        let newFingerprint = KnownHostsManager.fingerprint(of: hostKey)
        let isUnknown = knownKeys == nil
        let promptType: HostKeyPromptType
        if let knownKeys, !knownKeys.isEmpty {
            // Find the same key type for comparison, fallback to first
            let newKeyType = String(openSSHPublicKey: hostKey).split(separator: " ").first.map(String.init)
            let matchingKey = knownKeys.first { key in
                String(openSSHPublicKey: key).split(separator: " ").first.map(String.init) == newKeyType
            } ?? knownKeys.first!
            let oldFingerprint = KnownHostsManager.fingerprint(of: matchingKey)
            promptType = .mismatch(host: host, oldFingerprint: oldFingerprint, newFingerprint: newFingerprint)
        } else {
            promptType = .unknown(host: host, fingerprint: newFingerprint)
        }

        // Serialize hostKey to string for safe cross-isolation transfer
        let hostKeyString = String(openSSHPublicKey: hostKey)

        Task { @MainActor in
            guard let promptHandler else {
                validationCompletePromise.fail(SSHSessionError.hostKeyRejected)
                return
            }

            let result = await promptHandler(promptType)
            switch result {
            case .reject:
                validationCompletePromise.fail(SSHSessionError.hostKeyRejected)
            case .acceptOnce:
                validationCompletePromise.succeed(())
            case .acceptAndSave:
                if let savedKey = try? NIOSSHPublicKey(openSSHPublicKey: hostKeyString) {
                    if isUnknown {
                        KnownHostsManager.addEntry(host: host, port: port, key: savedKey)
                    } else {
                        KnownHostsManager.updateEntry(host: host, port: port, key: savedKey)
                    }
                }
                validationCompletePromise.succeed(())
            }
        }
    }
}

extension Notification.Name {
    static let sshSessionEnded = Notification.Name("sshSessionEnded")
}

// MARK: - Credentials

/// 한 연결을 수립하는 데 필요한 비밀번호 묶음.
/// 키: 타깃 connection.id 또는 JumpHost.id (둘 다 .password 인증일 때만 존재).
struct ResolvedCredentials: Sendable {
    var passwords: [UUID: String]
    init(passwords: [UUID: String] = [:]) { self.passwords = passwords }
}

// MARK: - Errors

enum SSHSessionError: Error, LocalizedError {
    case passwordRequired
    case notConnected
    case unsupportedKeyType(String)
    case invalidKeyFormat
    case hostKeyRejected
    case connectionTimeout

    var errorDescription: String? {
        switch self {
        case .passwordRequired: "비밀번호가 필요합니다"
        case .notConnected: "SSH 연결이 없습니다"
        case .unsupportedKeyType(let type): "지원하지 않는 키 유형: \(type)"
        case .invalidKeyFormat: "잘못된 키 형식입니다"
        case .hostKeyRejected: "호스트 키가 거부되었습니다"
        case .connectionTimeout: "연결 시간이 초과되었습니다"
        }
    }
}

// MARK: - SSH Key Helper

/// Parses OpenSSH private key files and creates the appropriate SSHAuthenticationMethod.
/// This is necessary because Citadel's OpenSSH key parser is internal.
enum SSHKeyHelper {

    static func authenticationMethod(
        fromPrivateKey keyString: String,
        username: String
    ) throws -> SSHAuthenticationMethod {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        // 전통 PEM 형식 (PKCS#1): -----BEGIN RSA PRIVATE KEY-----
        if trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            let (d, e, n) = try parsePEMRSAComponents(from: trimmed)
            return .custom(RSASHA512AuthDelegate(username: username, d: d, e: e, n: n))
        }

        // OpenSSH 형식: -----BEGIN OPENSSH PRIVATE KEY-----
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)

        switch keyType {
        case .ed25519:
            let privateKey = try parseEd25519PrivateKey(from: keyString)
            return .ed25519(username: username, privateKey: privateKey)
        case .rsa:
            let (d, e, n) = try parseOpenSSHRSAComponents(from: keyString)
            return .custom(RSASHA512AuthDelegate(username: username, d: d, e: e, n: n))
        case .ecdsaP256:
            let privateKey = try parseP256PrivateKey(from: keyString)
            return .p256(username: username, privateKey: privateKey)
        case .ecdsaP384:
            let privateKey = try parseP384PrivateKey(from: keyString)
            return .p384(username: username, privateKey: privateKey)
        case .ecdsaP521:
            let privateKey = try parseP521PrivateKey(from: keyString)
            return .p521(username: username, privateKey: privateKey)
        default:
            throw SSHSessionError.unsupportedKeyType(keyType.rawValue)
        }
    }

    // MARK: - Low-level OpenSSH key format parsing

    /// Extracts the base64-decoded binary data from an OpenSSH private key PEM block.
    private static func extractKeyData(from keyString: String) throws -> Data {
        var key = keyString.replacingOccurrences(of: "\n", with: "")

        guard
            key.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
            key.hasSuffix("-----END OPENSSH PRIVATE KEY-----")
        else {
            throw SSHSessionError.invalidKeyFormat
        }

        key.removeLast("-----END OPENSSH PRIVATE KEY-----".count)
        key.removeFirst("-----BEGIN OPENSSH PRIVATE KEY-----".count)

        guard let data = Data(base64Encoded: key) else {
            throw SSHSessionError.invalidKeyFormat
        }

        return data
    }

    /// Reads a big-endian UInt32 from data, advancing offset by 4.
    private static func readUInt32(from data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw SSHSessionError.invalidKeyFormat }
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    /// Reads an SSH-style string (uint32 length prefix + bytes) from data, advancing offset.
    private static func readSSHBytes(from data: Data, offset: inout Int) throws -> Data {
        let length = Int(try readUInt32(from: data, offset: &offset))
        guard offset + length <= data.count else { throw SSHSessionError.invalidKeyFormat }
        let result = data[offset..<(offset + length)]
        offset += length
        return Data(result)
    }

    /// Parses an unencrypted OpenSSH private key and returns the private section data
    /// with the offset positioned after the key type string.
    private static func parsePrivateSection(from keyString: String) throws -> (privateSection: Data, offset: Int) {
        let data = try extractKeyData(from: keyString)
        var offset = 0

        // Verify magic: "openssh-key-v1\0"
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard data.count > magic.count else { throw SSHSessionError.invalidKeyFormat }
        for (i, byte) in magic.enumerated() {
            guard data[i] == byte else { throw SSHSessionError.invalidKeyFormat }
        }
        offset = magic.count

        // Skip: cipher name, kdf name, kdf options
        _ = try readSSHBytes(from: data, offset: &offset)
        _ = try readSSHBytes(from: data, offset: &offset)
        _ = try readSSHBytes(from: data, offset: &offset)

        // Number of keys (must be 1)
        let numKeys = try readUInt32(from: data, offset: &offset)
        guard numKeys == 1 else { throw SSHSessionError.invalidKeyFormat }

        // Skip public key blob
        _ = try readSSHBytes(from: data, offset: &offset)

        // Read private section blob
        let privateSection = try readSSHBytes(from: data, offset: &offset)
        var privOffset = 0

        // Verify checkints match (indicates correct decryption / no encryption)
        let check1 = try readUInt32(from: privateSection, offset: &privOffset)
        let check2 = try readUInt32(from: privateSection, offset: &privOffset)
        guard check1 == check2 else { throw SSHSessionError.invalidKeyFormat }

        // Skip key type string (e.g. "ssh-ed25519")
        _ = try readSSHBytes(from: privateSection, offset: &privOffset)

        return (privateSection, privOffset)
    }

    // MARK: - Ed25519

    static func parseEd25519PrivateKey(from keyString: String) throws -> Curve25519.Signing.PrivateKey {
        let result = try parsePrivateSection(from: keyString)
        let section = result.privateSection
        var offset = result.offset

        // ed25519: public key (32 bytes), private key (64 bytes = 32 seed + 32 public)
        _ = try readSSHBytes(from: section, offset: &offset)
        let privateKeyData = try readSSHBytes(from: section, offset: &offset)
        guard privateKeyData.count == 64 else { throw SSHSessionError.invalidKeyFormat }

        return try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData.prefix(32))
    }

    // MARK: - ECDSA P-256

    static func parseP256PrivateKey(from keyString: String) throws -> P256.Signing.PrivateKey {
        let result = try parsePrivateSection(from: keyString)
        let section = result.privateSection
        var offset = result.offset

        // ECDSA: curve identifier, public key point, private scalar
        _ = try readSSHBytes(from: section, offset: &offset) // curve id
        _ = try readSSHBytes(from: section, offset: &offset) // public point
        let privateKeyData = try readSSHBytes(from: section, offset: &offset)

        return try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    // MARK: - ECDSA P-384

    static func parseP384PrivateKey(from keyString: String) throws -> P384.Signing.PrivateKey {
        let result = try parsePrivateSection(from: keyString)
        let section = result.privateSection
        var offset = result.offset

        _ = try readSSHBytes(from: section, offset: &offset)
        _ = try readSSHBytes(from: section, offset: &offset)
        let privateKeyData = try readSSHBytes(from: section, offset: &offset)

        return try P384.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    // MARK: - ECDSA P-521

    static func parseP521PrivateKey(from keyString: String) throws -> P521.Signing.PrivateKey {
        let result = try parsePrivateSection(from: keyString)
        let section = result.privateSection
        var offset = result.offset

        _ = try readSSHBytes(from: section, offset: &offset)
        _ = try readSSHBytes(from: section, offset: &offset)
        let privateKeyData = try readSSHBytes(from: section, offset: &offset)

        return try P521.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    // MARK: - OpenSSH RSA

    /// OpenSSH 형식의 RSA 키에서 d, e, n BIGNUM을 추출합니다.
    static func parseOpenSSHRSAComponents(from keyString: String) throws -> (d: UnsafeMutablePointer<BIGNUM>, e: UnsafeMutablePointer<BIGNUM>, n: UnsafeMutablePointer<BIGNUM>) {
        let result = try parsePrivateSection(from: keyString)
        let section = result.privateSection
        var offset = result.offset

        let nData = try readSSHBytes(from: section, offset: &offset)
        let eData = try readSSHBytes(from: section, offset: &offset)
        let dData = try readSSHBytes(from: section, offset: &offset)

        let n = CCryptoBoringSSL_BN_bin2bn([UInt8](nData), nData.count, nil)!
        let e = CCryptoBoringSSL_BN_bin2bn([UInt8](eData), eData.count, nil)!
        let d = CCryptoBoringSSL_BN_bin2bn([UInt8](dData), dData.count, nil)!

        return (d, e, n)
    }

    // MARK: - PEM RSA (PKCS#1)

    /// 전통적인 PEM 형식 (-----BEGIN RSA PRIVATE KEY-----) PKCS#1 키에서 d, e, n을 추출합니다.
    static func parsePEMRSAComponents(from keyString: String) throws -> (d: UnsafeMutablePointer<BIGNUM>, e: UnsafeMutablePointer<BIGNUM>, n: UnsafeMutablePointer<BIGNUM>) {
        var pem = keyString.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard
            pem.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"),
            pem.hasSuffix("-----END RSA PRIVATE KEY-----")
        else {
            throw SSHSessionError.invalidKeyFormat
        }

        pem.removeFirst("-----BEGIN RSA PRIVATE KEY-----".count)
        pem.removeLast("-----END RSA PRIVATE KEY-----".count)

        guard let derData = Data(base64Encoded: pem) else {
            throw SSHSessionError.invalidKeyFormat
        }

        return try parsePKCS1RSAComponents(from: derData)
    }

    // MARK: - ASN.1 DER / PKCS#1 parser

    private static func parsePKCS1RSAComponents(from data: Data) throws -> (d: UnsafeMutablePointer<BIGNUM>, e: UnsafeMutablePointer<BIGNUM>, n: UnsafeMutablePointer<BIGNUM>) {
        var offset = 0

        try expectASN1Tag(0x30, in: data, offset: &offset)
        _ = try readASN1Length(from: data, offset: &offset)

        let version = try readASN1Integer(from: data, offset: &offset)
        guard version.count <= 1 else { throw SSHSessionError.invalidKeyFormat }

        let n = try readASN1Integer(from: data, offset: &offset)
        let e = try readASN1Integer(from: data, offset: &offset)
        let d = try readASN1Integer(from: data, offset: &offset)

        let nBN = CCryptoBoringSSL_BN_bin2bn([UInt8](n), n.count, nil)!
        let eBN = CCryptoBoringSSL_BN_bin2bn([UInt8](e), e.count, nil)!
        let dBN = CCryptoBoringSSL_BN_bin2bn([UInt8](d), d.count, nil)!

        return (dBN, eBN, nBN)
    }

    private static func expectASN1Tag(_ tag: UInt8, in data: Data, offset: inout Int) throws {
        guard offset < data.count, data[offset] == tag else {
            throw SSHSessionError.invalidKeyFormat
        }
        offset += 1
    }

    /// ASN.1 DER 길이 필드를 읽습니다.
    private static func readASN1Length(from data: Data, offset: inout Int) throws -> Int {
        guard offset < data.count else { throw SSHSessionError.invalidKeyFormat }
        let first = data[offset]
        offset += 1

        if first < 0x80 {
            return Int(first)
        }

        let numBytes = Int(first & 0x7F)
        guard numBytes > 0, numBytes <= 4, offset + numBytes <= data.count else {
            throw SSHSessionError.invalidKeyFormat
        }

        var length = 0
        for i in 0..<numBytes {
            length = (length << 8) | Int(data[offset + i])
        }
        offset += numBytes
        return length
    }

    /// ASN.1 INTEGER를 읽어서 바이트 Data로 반환합니다 (선행 0x00 패딩 제거).
    private static func readASN1Integer(from data: Data, offset: inout Int) throws -> Data {
        try expectASN1Tag(0x02, in: data, offset: &offset)
        let length = try readASN1Length(from: data, offset: &offset)
        guard offset + length <= data.count else { throw SSHSessionError.invalidKeyFormat }

        var intData = data[offset..<(offset + length)]
        offset += length

        // ASN.1 INTEGER는 부호 있는 표현이라 양수일 때 선행 0x00이 있을 수 있음
        if let first = intData.first, first == 0x00, intData.count > 1 {
            intData = intData.dropFirst()
        }

        return Data(intData)
    }
}
