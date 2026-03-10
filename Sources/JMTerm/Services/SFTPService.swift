// Sources/JMTerm/Services/SFTPService.swift
import Foundation
import Citadel
import NIOCore
import SwiftTerm

struct TransferProgress {
    let fileName: String
    let isUpload: Bool
    var bytesTransferred: Int64
    var totalBytes: Int64

    var fraction: Double {
        totalBytes > 0 ? Double(bytesTransferred) / Double(totalBytes) : 0
    }

    var percent: Int {
        Int(fraction * 100)
    }
}

@MainActor
@Observable
final class SFTPService {
    var isSFTPReady = false
    var currentPath = "/"
    var transferProgress: TransferProgress?

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

    var isTransferring: Bool { transferProgress != nil }

    func downloadFile(remotePath: String, localURL: URL) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        guard !isTransferring else { return }

        let fileName = (remotePath as NSString).lastPathComponent
        var totalSize: Int64 = 0
        if let attrs = try? await sftp.getAttributes(at: remotePath) {
            totalSize = Int64(attrs.size ?? 0)
        }
        transferProgress = TransferProgress(
            fileName: fileName, isUpload: false,
            bytesTransferred: 0, totalBytes: totalSize
        )

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
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
                transferProgress?.bytesTransferred = Int64(offset)
            }
            try await file.close()
        } catch {
            try? await file.close()
            transferProgress = nil
            throw error
        }
        transferProgress = nil
    }

    func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        guard !isTransferring else { return }

        let fileName = localURL.lastPathComponent
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize: Int64
        if let size = fileAttrs[.size] as? UInt64 {
            totalSize = Int64(size)
        } else {
            totalSize = 0
        }
        transferProgress = TransferProgress(
            fileName: fileName, isUpload: true,
            bytesTransferred: 0, totalBytes: totalSize
        )

        let localHandle = try FileHandle(forReadingFrom: localURL)
        defer { localHandle.closeFile() }

        let file = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
        do {
            var offset: UInt64 = 0
            while true {
                let data = localHandle.readData(ofLength: Int(Self.chunkSize))
                if data.isEmpty { break }
                try await file.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)
                transferProgress?.bytesTransferred = Int64(offset)
            }
            try await file.close()
        } catch {
            try? await file.close()
            transferProgress = nil
            throw error
        }
        transferProgress = nil
    }

    func renameItem(oldPath: String, newPath: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        try await sftp.rename(at: oldPath, to: newPath)
    }

    func deleteFile(at path: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        try await sftp.remove(at: path)
    }

    func deleteDirectory(at path: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        try await sftp.rmdir(at: path)
    }

    func close() async {
        if let sftp = sftpClient {
            try? await sftp.close()
        }
        sftpClient = nil
        isSFTPReady = false
    }
}
