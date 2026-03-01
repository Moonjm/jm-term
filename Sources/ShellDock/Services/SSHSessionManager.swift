// Sources/ShellDock/Services/SSHSessionManager.swift
import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
import SwiftTerm

// MARK: - Sendable wrapper for non-Sendable SSH types

/// Wraps a non-Sendable value so it can cross isolation boundaries.
/// Safety: The caller must ensure that the wrapped value is only accessed
/// from the appropriate context (e.g., always from @MainActor).
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

@MainActor
@Observable
final class SSHSession: Identifiable {
    let id = UUID()
    let connection: ServerConnection
    var isConnected = false
    var statusMessage = "연결 대기 중"
    var currentPath = "/"

    // These properties hold non-Sendable types from Citadel.
    // They are only accessed on @MainActor. We use UncheckedSendableBox
    // when passing them to nonisolated Citadel async methods.
    private var client: SSHClient?
    private var sftpClient: SFTPClient?
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
            let keyString = try String(contentsOfFile: path, encoding: .utf8)
            authMethod = try SSHKeyHelper.authenticationMethod(
                fromPrivateKey: keyString,
                username: connection.username
            )
        }

        let sshClient = try await SSHClient.connect(
            host: connection.host,
            port: connection.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        self.client = sshClient
        isConnected = true
        statusMessage = "연결됨: \(connection.username)@\(connection.host):\(connection.port)"
    }

    func startShell() async throws {
        guard let client else { return }
        guard let terminalView else { return }

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
            terminalModes: SSHTerminalModes([.ECHO: 1])
        )

        // Wrap non-Sendable values for crossing isolation boundary
        let clientBox = UncheckedSendableBox(value: client)
        let termViewBox = UncheckedSendableBox(value: terminalView)
        let sessionBox = UncheckedSendableBox<SSHSession>(value: self)

        try await SSHSession.runPTYSession(
            client: clientBox,
            ptyRequest: ptyRequest,
            session: sessionBox,
            termView: termViewBox
        )
    }

    /// Runs the PTY session in a nonisolated context to satisfy Swift 6 concurrency.
    /// The closure passed to `withPTY` must not be main-actor-isolated.
    private nonisolated static func runPTYSession(
        client: UncheckedSendableBox<SSHClient>,
        ptyRequest: SSHChannelRequestEvent.PseudoTerminalRequest,
        session: UncheckedSendableBox<SSHSession>,
        termView: UncheckedSendableBox<TerminalView>
    ) async throws {
        try await client.value.withPTY(ptyRequest) { inbound, outbound in
            let writerBox = UncheckedSendableBox(value: outbound)
            await MainActor.run {
                session.value.stdinWriter = writerBox.value
            }

            for try await event in inbound {
                switch event {
                case .stdout(let buffer), .stderr(let buffer):
                    let bytes = Array(buffer.readableBytesView)
                    await MainActor.run {
                        termView.value.feed(byteArray: bytes[...])
                    }
                }
            }

            await MainActor.run {
                session.value.isConnected = false
                session.value.statusMessage = "연결 종료됨"
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

    // MARK: - SFTP operations

    func openSFTP() async throws {
        guard let client else { return }
        let clientBox = UncheckedSendableBox(value: client)
        let sftp = try await clientBox.value.openSFTP()
        sftpClient = sftp
        currentPath = try await sftp.getRealPath(atPath: ".")
    }

    func listDirectory(at path: String) async throws -> [FileNode] {
        guard let sftp = sftpClient else { return [] }
        let entries = try await sftp.listDirectory(atPath: path)
        return entries.flatMap { name in
            name.components.compactMap { component in
                let fileName = component.filename
                guard fileName != "." && fileName != ".." else { return nil }
                let isDir = component.attributes.permissions.map { $0 & 0o40000 != 0 } ?? false
                return FileNode(
                    name: fileName,
                    path: path == "/" ? "/\(fileName)" : "\(path)/\(fileName)",
                    isDirectory: isDir,
                    size: component.attributes.size,
                    permissions: component.attributes.permissions,
                    children: isDir ? [] : nil
                )
            }
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    func downloadFile(remotePath: String, localURL: URL) async throws {
        guard let sftp = sftpClient else { return }
        let data = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            try await file.readAll()
        }
        try Data(buffer: data).write(to: localURL)
    }

    func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let sftp = sftpClient else { return }
        let data = try Data(contentsOf: localURL)
        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
            try await file.write(ByteBuffer(data: data))
        }
    }

    func disconnect() async {
        if let sftp = sftpClient {
            try? await sftp.close()
        }
        if let client {
            let clientBox = UncheckedSendableBox(value: client)
            try? await clientBox.value.close()
        }
        sftpClient = nil
        client = nil
        stdinWriter = nil
        isConnected = false
        statusMessage = "연결 끊김"
    }
}

// MARK: - Errors

enum SSHSessionError: Error, LocalizedError {
    case passwordRequired
    case notConnected
    case unsupportedKeyType(String)
    case invalidKeyFormat

    var errorDescription: String? {
        switch self {
        case .passwordRequired: "비밀번호가 필요합니다"
        case .notConnected: "SSH 연결이 없습니다"
        case .unsupportedKeyType(let type): "지원하지 않는 키 유형: \(type)"
        case .invalidKeyFormat: "잘못된 키 형식입니다"
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
