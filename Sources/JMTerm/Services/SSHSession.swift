// Sources/JMTerm/Services/SSHSession.swift
import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
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

    func connect(password: String?) async throws {
        statusMessage = "연결 중..."

        let authMethod: SSHAuthenticationMethod
        switch connection.authMethod {
        case .password:
            guard let password else { throw SSHSessionError.passwordRequired }
            authMethod = .passwordBased(username: connection.username, password: password)
        case .publicKey(let path):
            let expandedPath = NSString(string: path).expandingTildeInPath
            let keyString = try String(contentsOfFile: expandedPath, encoding: .utf8)
            authMethod = try SSHKeyHelper.authenticationMethod(
                fromPrivateKey: keyString,
                username: connection.username
            )
        }

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
                    reconnect: .never
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

    var errorDescription: String? {
        switch self {
        case .passwordRequired: "비밀번호가 필요합니다"
        case .notConnected: "SSH 연결이 없습니다"
        case .unsupportedKeyType(let type): "지원하지 않는 키 유형: \(type)"
        case .invalidKeyFormat: "잘못된 키 형식입니다"
        case .hostKeyRejected: "호스트 키가 거부되었습니다"
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
        let keyType = try SSHKeyDetection.detectPrivateKeyType(from: keyString)

        switch keyType {
        case .ed25519:
            let privateKey = try parseEd25519PrivateKey(from: keyString)
            return .ed25519(username: username, privateKey: privateKey)
        case .rsa:
            throw SSHSessionError.unsupportedKeyType("RSA (use ed25519 keys instead)")
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
}
