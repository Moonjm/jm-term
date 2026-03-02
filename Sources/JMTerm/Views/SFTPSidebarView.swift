// Sources/JMTerm/Views/SFTPSidebarView.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

struct SFTPSidebarView: View {
    let session: SSHSession
    @State private var items: [FileNode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var trackedPath: String = ""
    @State private var editingPath: String = ""
    @State private var selectedID: FileNode.ID?
    @State private var lastClickID: FileNode.ID?
    @State private var lastClickDate = Date.distantPast
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // 경로 바 (편집 가능)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                TextField("경로", text: $editingPath)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit {
                        navigateTo(editingPath)
                    }

                Button(action: { Task { await loadDirectory() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("새로고침")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(white: 0.12))

            Divider()

            // 파일 목록
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding()
                    Button("다시 시도") { Task { await loadDirectory() } }
                    Spacer()
                }
            } else if items.isEmpty {
                VStack {
                    Spacer()
                    Text("빈 디렉토리")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { node in
                            Button {
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
                            } label: {
                                FileItemRow(node: node)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(selectedID == node.id ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                            .contextMenu {
                                if node.isDirectory && node.name != ".." {
                                    Button("열기") { navigateTo(node.path) }
                                    Button("터미널에서 이동") { cdInTerminal(node.path) }
                                }
                                if !node.isDirectory {
                                    Button("다운로드") { downloadNode(node) }
                                }
                            }
                            .onDrag {
                                dragProvider(for: node)
                            }
                        }
                    }
                    .padding(4)
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                    return true
                }
                .border(isDropTargeted ? Color.accentColor : Color.clear, width: 2)
            }

        }
        .task {
            for _ in 0..<50 {
                if session.isSFTPReady { break }
                try? await Task.sleep(for: .milliseconds(200))
                if session.statusMessage.contains("실패") { return }
            }
            guard session.isSFTPReady else { return }
            trackedPath = session.currentPath
            editingPath = session.currentPath
            await loadDirectory()
        }
        .onChange(of: session.currentPath) { _, newPath in
            if newPath != trackedPath {
                trackedPath = newPath
                editingPath = newPath
                Task { await loadDirectory() }
            }
        }
    }

    @MainActor
    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            var loaded = try await session.listDirectory(at: session.currentPath)
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

    private func navigateTo(_ path: String) {
        session.currentPath = path
        editingPath = path
    }

    private func cdInTerminal(_ path: String) {
        session.currentPath = path
        let encoded = Data(path.utf8).base64EncodedString()
        let command = "cd \"$(echo '\(encoded)' | base64 -d)\"\n"
        session.sendToShell(Data(command.utf8))
    }

    private func dragProvider(for node: FileNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name

        let sessionRef = UncheckedBox(value: session)
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
                let tempURL = tempDir.appendingPathComponent(fileName)
                do {
                    try await sessionRef.value.downloadFile(remotePath: remotePath, localURL: tempURL)
                    completion(tempURL, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    let remotePath = "\(session.currentPath)/\(url.lastPathComponent)"
                    do {
                        try await session.uploadFile(localURL: url, remotePath: remotePath)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            await loadDirectory()
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        let providerRef = UncheckedBox(value: provider)
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

    @MainActor
    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let remotePath = "\(session.currentPath)/\(url.lastPathComponent)"
                try await session.uploadFile(localURL: url, remotePath: remotePath)
                await loadDirectory()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func downloadNode(_ node: FileNode) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            try? await session.downloadFile(remotePath: node.path, localURL: url)
        }
    }
}

// MARK: - File Item Row

struct FileItemRow: View {
    let node: FileNode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon)
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                .frame(width: 16)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if !node.isDirectory, let size = node.size {
                Text(formatSize(size))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var fileIcon: String {
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log": return "doc.text"
        case "swift", "py", "js", "ts", "rs", "go", "java", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "xml", "toml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "zip", "tar", "gz", "bz2": return "archivebox"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc"
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
