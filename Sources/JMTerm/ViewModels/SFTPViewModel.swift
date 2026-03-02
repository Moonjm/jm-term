// Sources/JMTerm/ViewModels/SFTPViewModel.swift
import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class SFTPViewModel {
    let session: SSHSession

    var items: [FileNode] = []
    var isLoading = false
    var errorMessage: String?
    var editingPath: String = ""
    var selectedID: FileNode.ID?
    var isDropTargeted = false
    var renamingNode: FileNode?
    var renamingName: String = ""

    private var trackedPath: String = ""
    private var lastClickID: FileNode.ID?
    private var lastClickDate = Date.distantPast

    init(session: SSHSession) {
        self.session = session
    }

    func handleFileClick(_ node: FileNode) {
        let now = Date()
        if node.id == lastClickID,
           now.timeIntervalSince(lastClickDate) < 0.35,
           node.isDirectory {
            navigateTo(node.path)
        } else {
            selectedID = node.id
        }
        lastClickID = node.id
        lastClickDate = now
    }

    func initialLoad() async {
        for _ in 0..<50 {
            if session.sftpService.isSFTPReady { break }
            try? await Task.sleep(for: .milliseconds(200))
            if session.statusMessage.contains("실패") { return }
        }
        guard session.sftpService.isSFTPReady else { return }
        trackedPath = session.currentPath
        editingPath = session.currentPath
        await loadDirectory()
    }

    func handlePathChange(_ newPath: String) {
        if newPath != trackedPath {
            trackedPath = newPath
            editingPath = newPath
            Task { await loadDirectory() }
        }
    }

    func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            var loaded = try await session.sftpService.listDirectory(at: session.currentPath)
            if session.currentPath != "/" {
                let parent = (session.currentPath as NSString).deletingLastPathComponent
                let parentNode = FileNode(
                    name: "..",
                    path: parent.isEmpty ? "/" : parent,
                    isDirectory: true,
                    size: nil,
                    permissions: nil,
                    children: nil
                )
                loaded.insert(parentNode, at: 0)
            }
            items = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func navigateTo(_ path: String) {
        session.currentPath = path
        editingPath = path
    }

    func cdInTerminal(_ path: String) {
        session.currentPath = path
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "cd '\(escaped)'\n"
        session.sendToShell(Data(command.utf8))
    }

    func beginRename(_ node: FileNode) {
        renamingNode = node
        renamingName = node.name
    }

    func commitRename() {
        guard let node = renamingNode else { return }
        let newName = renamingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != node.name else {
            renamingNode = nil
            return
        }
        let parentPath = (node.path as NSString).deletingLastPathComponent
        let newPath = parentPath == "/" ? "/\(newName)" : "\(parentPath)/\(newName)"
        renamingNode = nil
        Task {
            do {
                try await session.sftpService.renameItem(oldPath: node.path, newPath: newPath)
                await loadDirectory()
            } catch {
                errorMessage = "이름 변경 실패: \(error.localizedDescription)"
            }
        }
    }

    func cancelRename() {
        renamingNode = nil
    }

    func deleteNode(_ node: FileNode) {
        Task {
            do {
                if node.isDirectory {
                    try await session.sftpService.deleteDirectory(at: node.path)
                } else {
                    try await session.sftpService.deleteFile(at: node.path)
                }
                await loadDirectory()
            } catch {
                errorMessage = "삭제 실패: \(error.localizedDescription)"
            }
        }
    }

    func dragProvider(for node: FileNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name

        let sftpService = session.sftpService
        let sftpBox = UncheckedSendableBox(value: sftpService)
        let remotePath = node.path
        let fileName = node.name

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task { @MainActor in
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                // Path traversal 방지: 파일명에서 경로 구분자 제거
                let safeName = (fileName as NSString).lastPathComponent
                let tempURL = tempDir.appendingPathComponent(safeName)
                do {
                    try await sftpBox.value.downloadFile(remotePath: remotePath, localURL: tempURL)
                    completion(tempURL, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    let remotePath = "\(session.currentPath)/\(url.lastPathComponent)"
                    do {
                        try await session.sftpService.uploadFile(localURL: url, remotePath: remotePath)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            await loadDirectory()
        }
    }

    func downloadNode(_ node: FileNode) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await session.sftpService.downloadFile(remotePath: node.path, localURL: url)
            } catch {
                errorMessage = "다운로드 실패: \(error.localizedDescription)"
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        let providerRef = UncheckedSendableBox(value: provider)
        return await withCheckedContinuation { continuation in
            providerRef.value.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
