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
private final class OnceResolver: Sendable {
    private let state = ManagedCriticalState<(resolved: Bool, continuation: CheckedContinuation<Void, Error>?)>(
        (resolved: false, continuation: nil)
    )

    func resolve(with result: Result<Void, Error>) {
        state.withLock { s in
            guard !s.resolved else { return }
            s.resolved = true
            s.continuation?.resume(with: result)
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if s.resolved { return }
                s.continuation = continuation
            }
        }
    }
}

/// Minimal lock-based critical state for Sendable conformance.
private final class ManagedCriticalState<State>: @unchecked Sendable {
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
    private var stdinWriter: TTYStdinWriter?
    weak var terminalView: TerminalView?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private nonisolated static func resolveAuthMethod(
        _ connection: ServerConnection, password: String?
    ) throws -> SSHAuthenticationMethod {
        switch connection.authMethod {
        case .password:
            guard let password else { throw SSHSessionError.passwordRequired }
            return .passwordBased(username: connection.username, password: password)
        case .publicKey(let path):
            let expandedPath = NSString(string: path).expandingTildeInPath
            let keyString = try String(contentsOfFile: expandedPath, encoding: .utf8)
            return try SSHKeyHelper.authenticationMethod(
                fromPrivateKey: keyString,
                username: connection.username
            )
        }
    }

    func connect(password: String?) async throws {
        statusMessage = "연결 중..."

        let authMethod = try Self.resolveAuthMethod(connection, password: password)
        let hostKeyValidator = buildHostKeyValidator()

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

    private func buildHostKeyValidator() -> SSHHostKeyValidator {
        let status = KnownHostsManager.lookup(host: connection.host, port: connection.port)
        let knownKeys: Set<NIOSSHPublicKey>? = if case .trusted(let keys) = status { keys } else { nil }

        let validator = HostKeyValidationDelegate(
            knownKeys: knownKeys,
            host: connection.host,
            port: connection.port,
            promptHandler: hostKeyPromptHandler
        )
        return .custom(validator)
    }

    func startShell() async throws {
        guard let client else { return }
        guard let terminalView else { return }

        // SFTP 준비 대기 후 MOTD 읽어서 셸 시작 전에 표시
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

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.ECHO: 0])
        )

        let clientBox = UncheckedSendableBox(value: client)
        let termViewBox = UncheckedSendableBox(value: terminalView)
        let sessionBox = UncheckedSendableBox<SSHSession>(value: self)

        // 별도 스레드에서 PTY 세션 실행 (메인스레드 블로킹 방지)
        Task.detached {
            do {
                try await clientBox.value.withPTY(ptyRequest) { inbound, outbound in
                    let writerBox = UncheckedSendableBox(value: outbound)
                    await MainActor.run {
                        sessionBox.value.stdinWriter = writerBox.value
                    }

                    // PS1에 OSC 7 추가 + echo 복원 (ECHO:0이라 명령 안 보임)
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        let setupCmd = #" PS1='\[\e]7;file://\H$(pwd)\a\]'"$PS1"; stty echo; printf '\033[1A\033[2K'"# + "\n"
                        try? await writerBox.value.write(ByteBuffer(data: Data(setupCmd.utf8)))
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

    // MARK: - Test Connection

    /// Tests SSH connectivity without starting a shell or keeping the connection.
    nonisolated static func testConnection(_ connection: ServerConnection, password: String?, timeout: Duration = .seconds(10)) async throws {
        let authMethod = try resolveAuthMethod(connection, password: password)

        // known_hosts 기반 호스트 키 검증 (프롬프트 없이 trusted만 통과, 나머지 수락)
        let status = KnownHostsManager.lookup(host: connection.host, port: connection.port)
        let hostKeyValidator: SSHHostKeyValidator
        if case .trusted(let keys) = status {
            hostKeyValidator = .trustedKeys(keys)
        } else {
            hostKeyValidator = .acceptAnything()
        }

        let authBox = UncheckedSendableBox(value: authMethod)
        let validatorBox = UncheckedSendableBox(value: hostKeyValidator)
        let host = connection.host
        let port = connection.port
        let resolver = OnceResolver()

        // 타임아웃 적용: detached task로 Sendable 제약 회피
        let connectTask = Task.detached {
            do {
                let client = try await SSHClient.connect(
                    host: host,
                    port: port,
                    authenticationMethod: authBox.value,
                    hostKeyValidator: validatorBox.value,
                    reconnect: .never,
                    algorithms: .all
                )
                try? await client.close()
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
        await sftpService.close()
        if let client {
            let clientBox = UncheckedSendableBox(value: client)
            try? await clientBox.value.close()
        }
        client = nil
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
