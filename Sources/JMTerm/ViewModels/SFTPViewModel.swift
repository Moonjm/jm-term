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
    /// 디렉토리 목록을 읽지 못했을 때만 사용 — 목록 영역 전체를 대체한다.
    var errorMessage: String?
    /// 개별 작업(업로드·삭제 등) 실패 — 목록은 유지하고 배너로만 표시한다.
    var operationError: String?
    var editingPath: String = ""
    var selectedID: FileNode.ID?
    var isDropTargeted = false
    var renamingNode: FileNode?
    var renamingName: String = ""
    var showHiddenFiles: Bool {
        didSet {
            UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenFilesKey)
            Task { await loadDirectory() }
        }
    }

    private static let showHiddenFilesKey = "sftp.showHiddenFiles"
    private var trackedPath: String = ""
    private var lastClickID: FileNode.ID?
    private var lastClickDate = Date.distantPast
    private var operationErrorDismissTask: Task<Void, Never>?

    init(session: SSHSession) {
        self.session = session
        self.showHiddenFiles = UserDefaults.standard.object(forKey: Self.showHiddenFilesKey) as? Bool ?? true
    }

    func showOperationError(_ message: String) {
        operationError = message
        operationErrorDismissTask?.cancel()
        operationErrorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.operationError = nil }
        }
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
            if session.state == .disconnected { return }
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
        // 경로 스냅샷: await 중 경로가 바뀌면(연속 탐색, 숨김 토글 등 겹친 로드)
        // 늦게 도착한 옛 디렉토리 결과가 현재 화면을 덮어쓰지 않도록 한다.
        let path = session.currentPath
        isLoading = true
        errorMessage = nil
        do {
            var loaded = try await session.sftpService.listDirectory(at: path)
            guard session.currentPath == path else { return }
            if !showHiddenFiles {
                loaded.removeAll { $0.name.hasPrefix(".") }
            }
            if path != "/" {
                let parent = (path as NSString).deletingLastPathComponent
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
            guard session.currentPath == path else { return }
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
        if newName == node.name {
            renamingNode = nil
            return
        }
        guard !newName.isEmpty, !newName.contains("/") else {
            showOperationError("이름에 '/'를 쓸 수 없고 비울 수 없습니다")
            return
        }
        let parentURL = URL(fileURLWithPath: node.path).deletingLastPathComponent()
        let newPath = parentURL.appendingPathComponent(newName).path
        Task {
            do {
                try await session.sftpService.renameItem(oldPath: node.path, newPath: newPath)
                renamingNode = nil
                await loadDirectory()
            } catch {
                showOperationError("이름 변경 실패: \(error.localizedDescription)")
            }
        }
    }

    func createFolder() {
        let alert = NSAlert()
        alert.messageText = "새 폴더"
        alert.informativeText = "생성할 폴더 이름을 입력하세요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "폴더 이름"
        alert.accessoryView = field
        alert.addButton(withTitle: "만들기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            showOperationError("폴더 이름에 '/'를 쓸 수 없고 비울 수 없습니다")
            return
        }
        let path = session.currentPath == "/" ? "/\(name)" : "\(session.currentPath)/\(name)"
        Task {
            do {
                try await session.sftpService.createDirectory(at: path)
                await loadDirectory()
            } catch {
                showOperationError("폴더 생성 실패: \(error.localizedDescription)")
            }
        }
    }

    func cancelRename() {
        renamingNode = nil
    }

    func deleteNode(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = "'\(node.name)' 삭제"
        alert.informativeText = node.isDirectory
            ? "이 디렉토리를 삭제하시겠습니까? (빈 디렉토리만 삭제 가능)"
            : "이 파일을 삭제하시겠습니까?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            do {
                if node.isDirectory {
                    try await session.sftpService.deleteDirectory(at: node.path)
                } else {
                    try await session.sftpService.deleteFile(at: node.path)
                }
                await loadDirectory()
            } catch {
                showOperationError("삭제 실패: \(error.localizedDescription)")
            }
        }
    }

    /// 드래그 promise가 시작조차 못했다고 판단하기까지 기다리는 시간.
    /// 앱 종료 시 AppKit은 CFPasteboardResolveAllPromisedData에서 메인 스레드를
    /// 중첩 런루프에 가둔 채 promise 확정을 동기 대기한다. 그 상태에서는
    /// @MainActor 작업이 영원히 스케줄되지 않으므로, 여기서 끊어주지 않으면
    /// 앱이 무한히 멈춰 강제종료로만 끌 수 있다.
    private static let dragPromiseStartTimeout: Duration = .seconds(3)

    func dragProvider(for node: FileNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name

        let sftpService = session.sftpService
        let sftpBox = UncheckedSendableBox(value: sftpService)
        let remotePath = node.path
        let fileName = node.name
        let startTimeout = Self.dragPromiseStartTimeout

        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            // completion은 정확히 한 번만 호출한다 — 워치독과 다운로드가 경쟁한다.
            let state = ManagedCriticalState((finished: false, started: false))
            let finish: @Sendable (URL?, Bool, Error?) -> Void = { url, coordinated, error in
                let isFirst = state.withLock { s -> Bool in
                    guard !s.finished else { return false }
                    s.finished = true
                    return true
                }
                guard isFirst else { return }
                completion(url, coordinated, error)
            }

            Task { @MainActor in
                // 메인 액터에 실제로 진입했음을 알린다 — 워치독은 이후 개입하지 않는다.
                state.withLock { $0.started = true }
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                // Path traversal 방지: 파일명에서 경로 구분자 제거
                let safeName = (fileName as NSString).lastPathComponent
                let tempURL = tempDir.appendingPathComponent(safeName)
                do {
                    try await sftpBox.value.downloadFile(remotePath: remotePath, localURL: tempURL)
                    finish(tempURL, true, nil)
                } catch {
                    finish(nil, false, error)
                }
            }

            // 워치독은 메인 액터를 타지 않는다 — 메인 스레드가 막혀도 동작해야 한다.
            // 다운로드가 일단 시작됐다면 큰 파일이라도 끝까지 기다린다.
            Task.detached {
                try? await Task.sleep(for: startTimeout)
                let stalled = state.withLock { !$0.started }
                if stalled {
                    finish(nil, false, SFTPDragPromiseError.mainActorUnavailable)
                }
            }
            return nil
        }
        return provider
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            for provider in providers {
                guard let url = await loadFileURL(from: provider) else { continue }

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    showOperationError("디렉토리 업로드는 지원되지 않습니다: \(url.lastPathComponent)")
                    continue
                }

                let base = session.currentPath == "/" ? "" : session.currentPath
                let remotePath = "\(base)/\(url.lastPathComponent)"

                // 같은 이름의 원격 파일을 확인 없이 덮어쓰지 않는다.
                if await session.sftpService.fileExists(at: remotePath) {
                    let alert = NSAlert()
                    alert.messageText = "'\(url.lastPathComponent)' 덮어쓰기"
                    alert.informativeText = "같은 이름의 파일이 서버에 이미 있습니다. 덮어쓰시겠습니까?"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "덮어쓰기")
                    alert.addButton(withTitle: "건너뛰기")
                    guard alert.runModal() == .alertFirstButtonReturn else { continue }
                }

                do {
                    try await session.sftpService.uploadFile(localURL: url, remotePath: remotePath)
                } catch SFTPTransferError.cancelled {
                    // 사용자가 취소한 것 — 에러 배너를 띄우지 않는다.
                } catch {
                    showOperationError("업로드 실패: \(error.localizedDescription)")
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
            } catch SFTPTransferError.cancelled {
                // 사용자가 취소한 것 — 에러 배너를 띄우지 않는다.
            } catch {
                showOperationError("다운로드 실패: \(error.localizedDescription)")
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

/// 드래그 promise를 확정할 수 없을 때의 오류.
enum SFTPDragPromiseError: LocalizedError {
    /// 메인 액터가 막혀 있어 다운로드를 시작하지 못했다 (주로 앱 종료 중).
    case mainActorUnavailable

    var errorDescription: String? {
        switch self {
        case .mainActorUnavailable:
            return "앱이 종료 중이라 드래그한 파일을 내려받지 못했습니다."
        }
    }
}
