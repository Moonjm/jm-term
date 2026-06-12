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

enum SFTPTransferError: Error, LocalizedError {
    case busy
    case cancelled

    var errorDescription: String? {
        switch self {
        case .busy: "다른 전송이 진행 중입니다"
        case .cancelled: "전송이 취소되었습니다"
        }
    }
}

@MainActor
@Observable
final class SFTPService {
    var isSFTPReady = false
    var currentPath = "/"
    var transferProgress: TransferProgress?

    private var sftpClient: SFTPClient?
    private var cancelRequested = false
    nonisolated private static let chunkSize: UInt32 = 1024 * 1024 // 1MB chunks

    /// 진행 중인 전송을 다음 청크 경계에서 중단한다.
    func cancelTransfer() {
        cancelRequested = true
    }

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

    /// 원격 경로에 파일/디렉토리가 존재하는지 확인 (덮어쓰기 확인용).
    func fileExists(at path: String) async -> Bool {
        guard let sftp = sftpClient else { return false }
        return (try? await sftp.getAttributes(at: path)) != nil
    }

    func createDirectory(at path: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        try await sftp.createDirectory(atPath: path)
    }

    func downloadFile(remotePath: String, localURL: URL) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        guard !isTransferring else { throw SFTPTransferError.busy }
        cancelRequested = false

        let fileName = (remotePath as NSString).lastPathComponent
        var totalSize: Int64 = 0
        if let attrs = try? await sftp.getAttributes(at: remotePath) {
            totalSize = Int64(attrs.size ?? 0)
        }
        // .part 임시 파일에 받고 완성된 뒤에만 최종 위치로 이동 —
        // 중간 실패 시 기존 로컬 파일이 잘린 채 파괴되지 않도록.
        let partURL = localURL.appendingPathExtension("part")
        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        // progress는 openFile 성공 후에 설정 — open 실패 시 isTransferring이
        // true로 남아 이후 전송이 전부 막히지 않도록.
        transferProgress = TransferProgress(
            fileName: fileName, isUpload: false,
            bytesTransferred: 0, totalBytes: totalSize
        )
        do {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partURL)
            do {
                var offset: UInt64 = 0
                while true {
                    if cancelRequested { throw SFTPTransferError.cancelled }
                    let chunk = try await file.read(from: offset, length: Self.chunkSize)
                    let data = Data(buffer: chunk)
                    if data.isEmpty { break }
                    try handle.write(contentsOf: data)
                    offset += UInt64(data.count)
                    transferProgress?.bytesTransferred = Int64(offset)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try await file.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                _ = try FileManager.default.replaceItemAt(localURL, withItemAt: partURL)
            } else {
                try FileManager.default.moveItem(at: partURL, to: localURL)
            }
        } catch {
            try? await file.close()
            try? FileManager.default.removeItem(at: partURL)
            transferProgress = nil
            throw error
        }
        transferProgress = nil
    }

    func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
        guard !isTransferring else { throw SFTPTransferError.busy }
        cancelRequested = false

        let fileName = localURL.lastPathComponent
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize: Int64
        if let size = fileAttrs[.size] as? UInt64 {
            totalSize = Int64(size)
        } else {
            totalSize = 0
        }
        let localHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? localHandle.close() }

        // 원격도 임시 이름에 올린 뒤 rename — 중간 실패 시 기존 원격 파일이
        // 잘린 채 남지 않도록.
        let partPath = remotePath + ".jmterm-part"
        let file = try await sftp.openFile(filePath: partPath, flags: [.write, .create, .truncate])
        // progress는 openFile 성공 후에 설정 — open 실패 시 isTransferring이
        // true로 남아 이후 전송이 전부 막히지 않도록.
        transferProgress = TransferProgress(
            fileName: fileName, isUpload: true,
            bytesTransferred: 0, totalBytes: totalSize
        )
        var removedExistingTarget = false
        do {
            var offset: UInt64 = 0
            while true {
                if cancelRequested { throw SFTPTransferError.cancelled }
                guard let data = try localHandle.read(upToCount: Int(Self.chunkSize)), !data.isEmpty else { break }
                try await file.write(ByteBuffer(data: data), at: offset)
                offset += UInt64(data.count)
                transferProgress?.bytesTransferred = Int64(offset)
            }
            try await file.close()
            // SFTP rename은 대상이 존재하면 실패하는 서버가 많아 기존 파일을 먼저 제거한다.
            if (try? await sftp.getAttributes(at: remotePath)) != nil {
                try? await sftp.remove(at: remotePath)
                removedExistingTarget = true
            }
            try await sftp.rename(at: partPath, to: remotePath)
        } catch {
            try? await file.close()
            // 기존 파일을 이미 지운 뒤 rename만 실패한 경우엔 업로드본(.jmterm-part)을
            // 남겨 수동 복구가 가능하게 한다. 그 전 단계 실패면 임시 파일을 정리한다.
            if !removedExistingTarget {
                try? await sftp.remove(at: partPath)
            }
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
        // await 중 재연결의 open()이 새 클라이언트를 넣을 수 있으므로
        // 먼저 분리한 뒤 닫는다.
        let old = sftpClient
        sftpClient = nil
        isSFTPReady = false
        if let old {
            try? await old.close()
        }
    }
}
