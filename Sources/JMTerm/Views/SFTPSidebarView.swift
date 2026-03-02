// Sources/JMTerm/Views/SFTPSidebarView.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SFTPSidebarView: View {
    @State private var viewModel: SFTPViewModel

    init(session: SSHSession) {
        _viewModel = State(initialValue: SFTPViewModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 경로 바 (편집 가능)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                TextField("경로", text: $viewModel.editingPath)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit {
                        viewModel.navigateTo(viewModel.editingPath)
                    }

                Button(action: { Task { await viewModel.loadDirectory() } }) {
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
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding()
                    Button("다시 시도") { Task { await viewModel.loadDirectory() } }
                    Spacer()
                }
            } else if viewModel.items.isEmpty {
                VStack {
                    Spacer()
                    Text("빈 디렉토리")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.items) { node in
                            Button {
                                viewModel.handleFileClick(node)
                            } label: {
                                FileItemRow(node: node)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(viewModel.selectedID == node.id ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                            .contextMenu {
                                if node.isDirectory && node.name != ".." {
                                    Button("열기") { viewModel.navigateTo(node.path) }
                                    Button("터미널에서 이동") { viewModel.cdInTerminal(node.path) }
                                }
                                if !node.isDirectory {
                                    Button("다운로드") { viewModel.downloadNode(node) }
                                }
                            }
                            .onDrag {
                                viewModel.dragProvider(for: node)
                            }
                        }
                    }
                    .padding(4)
                }
                .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
                    viewModel.handleDrop(providers)
                    return true
                }
                .border(viewModel.isDropTargeted ? Color.accentColor : Color.clear, width: 2)
            }

        }
        .task {
            await viewModel.initialLoad()
        }
        .onChange(of: viewModel.session.currentPath) { _, newPath in
            viewModel.handlePathChange(newPath)
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
