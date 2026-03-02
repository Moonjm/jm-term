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
                                if viewModel.renamingNode?.id == node.id {
                                    RenameRow(node: node, name: $viewModel.renamingName) {
                                        viewModel.commitRename()
                                    } onCancel: {
                                        viewModel.cancelRename()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    FileItemRow(node: node)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(viewModel.selectedID == node.id ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                            .overlay(
                                FileContextMenu(node: node, viewModel: viewModel)
                            )
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
                .contextMenu {
                    Button("새로고침") {
                        Task { await viewModel.loadDirectory() }
                    }
                }
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

// MARK: - Rename Row

struct RenameRow: View {
    let node: FileNode
    @Binding var name: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                .frame(width: 16)

            TextField("이름", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit { onCommit() }
                .onExitCommand { onCancel() }
        }
        .padding(.vertical, 2)
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

// MARK: - File Context Menu (NSMenu)

private struct FileContextMenu: NSViewRepresentable {
    let node: FileNode
    let viewModel: SFTPViewModel

    func makeNSView(context: Context) -> FileContextMenuView {
        let view = FileContextMenuView()
        view.node = node
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: FileContextMenuView, context: Context) {
        nsView.node = node
        nsView.viewModel = viewModel
    }
}

final class FileContextMenuView: NSView, @unchecked Sendable {
    var node: FileNode!
    var viewModel: SFTPViewModel!
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.showContextMenu(with: event)
                return nil
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func showContextMenu(with event: NSEvent) {
        guard let node = self.node, let viewModel = self.viewModel else { return }
        viewModel.selectedID = node.id

        guard node.name != ".." else { return }

        let menu = NSMenu()

        if node.isDirectory {
            menu.addItem(ClosureMenuItem(title: "열기") {
                viewModel.navigateTo(node.path)
            })
            menu.addItem(ClosureMenuItem(title: "터미널에서 이동") {
                viewModel.cdInTerminal(node.path)
            })
        } else {
            menu.addItem(ClosureMenuItem(title: "다운로드") {
                viewModel.downloadNode(node)
            })
        }

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "이름 변경") {
            viewModel.beginRename(node)
        })

        let deleteItem = ClosureMenuItem(title: "삭제") {
            viewModel.deleteNode(node)
        }
        deleteItem.attributedTitle = NSAttributedString(
            string: "삭제",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private var closure: () -> Void

    init(title: String, closure: @escaping () -> Void) {
        self.closure = closure
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func execute() {
        closure()
    }
}

