// Sources/JMTerm/Services/SFTPService.swift
import Foundation
import Citadel
import NIOCore
import SwiftTerm

@MainActor
@Observable
final class SFTPService {
    var isSFTPReady = false
    var currentPath = "/"

    private var sftpClient: SFTPClient?
    nonisolated private static let chunkSize: UInt32 = 1024 * 1024 // 1MB chunks

    func open(client: SSHClient) async throws {
        let clientBox = UncheckedSendableBox(value: client)
        let sftp = try await clientBox.value.openSFTP()
        sftpClient = sftp
        currentPath = try await sftp.getRealPath(atPath: ".")
        isSFTPReady = true
    }

    func readMOTD(terminalView: TerminalView) async {
        guard let sftp = sftpClient else { return }
        // MOTD 파일은 시스템에 따라 없을 수 있으므로 try?로 무시
        var motdText = ""
        if let buf = try? await sftp.withFile(filePath: "/run/motd.dynamic", flags: .read, { try await $0.readAll() }) {
            motdText += String(buffer: buf)
        }
        if let buf = try? await sftp.withFile(filePath: "/etc/motd", flags: .read, { try await $0.readAll() }) {
            motdText += String(buffer: buf)
        }
        if !motdText.isEmpty {
            let display = motdText.replacingOccurrences(of: "\n", with: "\r\n")
            terminalView.feed(byteArray: Array(display.utf8)[...])
        }
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
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: localURL)
            defer { handle.closeFile() }

            var offset: UInt64 = 0
            while true {
                let chunk = try await file.read(from: offset, length: Self.chunkSize)
                let data = Data(buffer: chunk)
                if data.isEmpty { break }
                handle.write(data)
                offset += UInt64(data.count)
            }
        }
    }

    func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { handle.closeFile() }

        try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
            var offset: UInt64 = 0
            while true {
                let data = handle.readData(ofLength: Int(Self.chunkSize))
                if data.isEmpty { break }
                try await file.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)
            }
        }
    }

    func close() async {
        if let sftp = sftpClient {
            try? await sftp.close()
        }
        sftpClient = nil
        isSFTPReady = false
    }
}
