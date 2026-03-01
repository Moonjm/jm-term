// Sources/ShellDock/Views/SFTPSidebarView.swift
import SwiftUI
import AppKit

struct SFTPSidebarView: View {
    let session: SSHSession
    @State private var rootNodes: [FileNode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // 현재 경로
            HStack {
                Image(systemName: "folder")
                Text(session.currentPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button(action: refreshDirectory) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(.bar)

            Divider()

            // 파일 트리
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(rootNodes) { node in
                        FileNodeRow(node: node, session: session)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // 업로드/다운로드 버튼
            HStack {
                Button(action: uploadFile) {
                    Label("업로드", systemImage: "arrow.up.doc")
                }
                Spacer()
                Button(action: downloadFile) {
                    Label("다운로드", systemImage: "arrow.down.doc")
                }
            }
            .padding(8)
        }
        .task {
            await loadDirectory()
        }
    }

    private func refreshDirectory() {
        Task { await loadDirectory() }
    }

    @MainActor
    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            rootNodes = try await session.listDirectory(at: session.currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
    private func downloadFile() {
        // 선택된 파일이 있을 때만 동작 (향후 선택 상태 추가)
    }
}

struct FileNodeRow: View {
    let node: FileNode
    let session: SSHSession
    @State private var children: [FileNode]?
    @State private var isExpanded = false

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let children {
                    ForEach(children) { child in
                        FileNodeRow(node: child, session: session)
                    }
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded && children == nil {
                    Task {
                        children = try? await session.listDirectory(at: node.path)
                    }
                }
            }
        } else {
            Label(node.name, systemImage: fileIcon(for: node.name))
                .contextMenu {
                    Button("다운로드") { downloadNode() }
                }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log": return "doc.text"
        case "swift", "py", "js", "ts", "rs", "go", "java", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "xml", "toml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        case "zip", "tar", "gz", "bz2": return "archivebox"
        default: return "doc"
        }
    }

    @MainActor
    private func downloadNode() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            try? await session.downloadFile(remotePath: node.path, localURL: url)
        }
    }
}
