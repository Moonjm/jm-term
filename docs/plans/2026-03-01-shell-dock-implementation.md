# ShellDock Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** macOS 네이티브 SSH/SFTP 터미널 클라이언트 (MobXterm 스타일)

**Architecture:** SwiftUI 앱에서 Citadel(SSH/SFTP)과 SwiftTerm(터미널 에뮬레이션)을 통합. NavigationSplitView로 좌측 SFTP 트리 + 우측 터미널 분할 레이아웃. 탭으로 다중 세션 관리.

**Tech Stack:** Swift 6, SwiftUI, Citadel (v0.12+), SwiftTerm (v1.11+), macOS Keychain

**Minimum Deployment Target:** macOS 15.0 (Citadel의 withPTY API 요구사항)

---

### Task 1: 프로젝트 초기 설정

**Files:**
- Create: `Package.swift`
- Create: `Sources/ShellDock/ShellDockApp.swift`
- Delete: `Sources/main.swift` (있다면)

**Step 1: Package.swift 생성**

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShellDock",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "ShellDock",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)
```

**Step 2: 앱 엔트리포인트 생성**

```swift
// Sources/ShellDock/ShellDockApp.swift
import SwiftUI

@main
struct ShellDockApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
    }
}

struct ContentView: View {
    var body: some View {
        Text("ShellDock")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 3: 빌드 확인**

Run: `swift build 2>&1 | tail -5`
Expected: 의존성 다운로드 후 빌드 성공 (BUILD SUCCEEDED 또는 에러 없음)

**Step 4: 실행 확인**

Run: `.build/debug/ShellDock &` (잠시 실행 후 종료)
Expected: 창이 열리고 "ShellDock" 텍스트 표시

**Step 5: 커밋**

```bash
git add Package.swift Sources/
git commit -m "feat: initial project setup with Citadel and SwiftTerm dependencies"
```

---

### Task 2: 데이터 모델

**Files:**
- Create: `Sources/ShellDock/Models/ServerConnection.swift`
- Create: `Sources/ShellDock/Models/FileNode.swift`

**Step 1: ServerConnection 모델 생성**

```swift
// Sources/ShellDock/Models/ServerConnection.swift
import Foundation

enum AuthMethod: Codable, Hashable {
    case password
    case publicKey(path: String)
}

struct ServerConnection: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authMethod: AuthMethod

    init(name: String, host: String, port: Int = 22, username: String, authMethod: AuthMethod = .password) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
    }
}
```

**Step 2: FileNode 모델 생성**

```swift
// Sources/ShellDock/Models/FileNode.swift
import Foundation

struct FileNode: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64?
    let permissions: UInt32?
    var children: [FileNode]?
    var isExpanded: Bool = false
}
```

**Step 3: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 4: 커밋**

```bash
git add Sources/ShellDock/Models/
git commit -m "feat: add ServerConnection and FileNode data models"
```

---

### Task 3: Keychain 매니저

**Files:**
- Create: `Sources/ShellDock/Services/KeychainManager.swift`

**Step 1: KeychainManager 구현**

```swift
// Sources/ShellDock/Services/KeychainManager.swift
import Foundation
import Security

enum KeychainError: Error {
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData
}

struct KeychainManager {
    static let service = "com.shelldock.ssh"

    static func save(password: String, for account: String) throws {
        guard let data = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        var status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func read(for account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return password
    }

    static func delete(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

**Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: 커밋**

```bash
git add Sources/ShellDock/Services/KeychainManager.swift
git commit -m "feat: add KeychainManager for secure password storage"
```

---

### Task 4: ConnectionStore (서버 목록 저장/로드)

**Files:**
- Create: `Sources/ShellDock/Services/ConnectionStore.swift`

**Step 1: ConnectionStore 구현**

```swift
// Sources/ShellDock/Services/ConnectionStore.swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class ConnectionStore {
    private(set) var connections: [ServerConnection] = []
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ShellDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.fileURL = appDir.appendingPathComponent("connections.json")
        load()
    }

    func add(_ connection: ServerConnection) {
        connections.append(connection)
        save()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let conn = connections[index]
            let account = "\(conn.username)@\(conn.host):\(conn.port)"
            try? KeychainManager.delete(for: account)
        }
        connections.remove(atOffsets: offsets)
        save()
    }

    func update(_ connection: ServerConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            save()
        }
    }

    func savePassword(_ password: String, for connection: ServerConnection) throws {
        let account = "\(connection.username)@\(connection.host):\(connection.port)"
        try KeychainManager.save(password: password, for: account)
    }

    func loadPassword(for connection: ServerConnection) -> String? {
        let account = "\(connection.username)@\(connection.host):\(connection.port)"
        return try? KeychainManager.read(for: account)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ServerConnection].self, from: data) else { return }
        connections = decoded
    }
}
```

**Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: 커밋**

```bash
git add Sources/ShellDock/Services/ConnectionStore.swift
git commit -m "feat: add ConnectionStore for persisting server configurations"
```

---

### Task 5: SSH 연결 매니저

**Files:**
- Create: `Sources/ShellDock/Services/SSHSessionManager.swift`

**Step 1: SSHSessionManager 구현**

Citadel의 SSH 연결과 PTY 셸 세션을 관리. SwiftTerm과의 데이터 브릿지 포함.

```swift
// Sources/ShellDock/Services/SSHSessionManager.swift
import Foundation
import Citadel
import NIOCore
import Crypto
import SwiftTerm

@MainActor
@Observable
final class SSHSession: Identifiable {
    let id = UUID()
    let connection: ServerConnection
    var isConnected = false
    var statusMessage = "연결 대기 중"
    var currentPath = "/"

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
            let keyString = try String(contentsOfFile: path)
            let key = try OpenSSH.PrivateKey<Curve25519.Signing.PrivateKey>(string: keyString)
            authMethod = .ed25519(username: connection.username, privateKey: key.privateKey)
        }

        let client = try await SSHClient.connect(
            host: connection.host,
            port: connection.port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        self.client = client
        isConnected = true
        statusMessage = "연결됨: \(connection.username)@\(connection.host):\(connection.port)"
    }

    func startShell() async throws {
        guard let client, let terminalView else { return }

        let terminal = terminalView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows

        try await client.withPTY(
            .init(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: UInt32(cols),
                terminalRowHeight: UInt32(rows),
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([.ECHO: 1])
            )
        ) { [weak self] inbound, outbound in
            await MainActor.run {
                self?.stdinWriter = outbound
            }

            for try await event in inbound {
                switch event {
                case .stdout(let buffer), .stderr(let buffer):
                    let bytes = Array(buffer.readableBytesView)
                    await MainActor.run {
                        self?.terminalView?.feed(byteArray: bytes[...])
                    }
                }
            }

            await MainActor.run {
                self?.isConnected = false
                self?.statusMessage = "연결 종료됨"
            }
        }
    }

    func sendToShell(_ data: Data) {
        guard let stdinWriter else { return }
        Task {
            try await stdinWriter.write(ByteBuffer(data: data))
        }
    }

    func resizeTerminal(cols: Int, rows: Int) {
        guard let stdinWriter else { return }
        Task {
            try await stdinWriter.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    // SFTP operations
    func openSFTP() async throws {
        guard let client else { return }
        sftpClient = try await client.openSFTP()
        currentPath = try await sftpClient?.getRealPath(atPath: ".") ?? "/"
    }

    func listDirectory(at path: String) async throws -> [FileNode] {
        guard let sftp = sftpClient else { return [] }
        let entries = try await sftp.listDirectory(atPath: path)
        return entries.flatMap { name in
            name.path.compactMap { component in
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
        try? await sftpClient?.close()
        try? await client?.close()
        sftpClient = nil
        client = nil
        stdinWriter = nil
        isConnected = false
        statusMessage = "연결 끊김"
    }
}

enum SSHSessionError: Error, LocalizedError {
    case passwordRequired
    case notConnected

    var errorDescription: String? {
        switch self {
        case .passwordRequired: "비밀번호가 필요합니다"
        case .notConnected: "SSH 연결이 없습니다"
        }
    }
}
```

**Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (Citadel/SwiftTerm API가 맞다면)

참고: `withPTY`의 `PseudoTerminalRequest` 이니셜라이저 시그니처가 다를 수 있음. 빌드 실패 시 Citadel 소스를 확인하여 정확한 시그니처로 조정할 것.

**Step 3: 커밋**

```bash
git add Sources/ShellDock/Services/SSHSessionManager.swift
git commit -m "feat: add SSHSession with shell, SFTP, and file transfer support"
```

---

### Task 6: SwiftTerm NSViewRepresentable 래퍼

**Files:**
- Create: `Sources/ShellDock/Views/TerminalViewWrapper.swift`

**Step 1: TerminalViewWrapper 구현**

```swift
// Sources/ShellDock/Views/TerminalViewWrapper.swift
import SwiftUI
import SwiftTerm
import AppKit

struct TerminalViewWrapper: NSViewRepresentable {
    let session: SSHSession

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator

        terminalView.nativeForegroundColor = NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1)
        terminalView.caretColor = .systemGreen
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.getTerminal().setCursorStyle(.steadyBlock)

        context.coordinator.session = session
        session.terminalView = terminalView

        Task {
            try await session.startShell()
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        var session: SSHSession?

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session?.sendToShell(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session?.resizeTerminal(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) { NSSound.beep() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
```

**Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: 커밋**

```bash
git add Sources/ShellDock/Views/TerminalViewWrapper.swift
git commit -m "feat: add SwiftTerm NSViewRepresentable wrapper for SwiftUI"
```

---

### Task 7: SFTP 사이드바 뷰

**Files:**
- Create: `Sources/ShellDock/Views/SFTPSidebarView.swift`

**Step 1: SFTPSidebarView 구현**

```swift
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

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let remotePath = "\(session.currentPath)/\(url.lastPathComponent)"
            try await session.uploadFile(localURL: url, remotePath: remotePath)
            await loadDirectory()
        }
    }

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

    private func downloadNode() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            try await session.downloadFile(remotePath: node.path, localURL: url)
        }
    }
}
```

**Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 3: 커밋**

```bash
git add Sources/ShellDock/Views/SFTPSidebarView.swift
git commit -m "feat: add SFTP sidebar with directory tree and file transfer"
```

---

### Task 8: 탭 바 + 연결 다이얼로그

**Files:**
- Create: `Sources/ShellDock/Views/SessionTabBar.swift`
- Create: `Sources/ShellDock/Views/ConnectionDialogView.swift`

**Step 1: SessionTabBar 구현**

```swift
// Sources/ShellDock/Views/SessionTabBar.swift
import SwiftUI

struct SessionTabBar: View {
    @Binding var sessions: [SSHSession]
    @Binding var activeSessionID: UUID?
    var onNewConnection: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onNewConnection) {
                Image(systemName: "plus")
                    .frame(width: 36, height: 28)
            }
            .buttonStyle(.plain)

            ForEach(sessions) { session in
                SessionTab(
                    name: session.connection.name,
                    isConnected: session.isConnected,
                    isSelected: session.id == activeSessionID,
                    onSelect: { activeSessionID = session.id },
                    onClose: { closeSession(session) }
                )
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func closeSession(_ session: SSHSession) {
        Task { await session.disconnect() }
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }
}

struct SessionTab: View {
    let name: String
    let isConnected: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(name)
                .lineLimit(1)
                .font(.caption)
            if isHovered || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
```

**Step 2: ConnectionDialogView 구현**

```swift
// Sources/ShellDock/Views/ConnectionDialogView.swift
import SwiftUI

struct ConnectionDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let connectionStore: ConnectionStore
    var onConnect: (ServerConnection, String?) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var useKey = false
    @State private var keyPath = "~/.ssh/id_ed25519"
    @State private var saveConnection = true

    // 저장된 서버 선택
    @State private var selectedSaved: ServerConnection?

    var body: some View {
        VStack(spacing: 16) {
            Text("SSH 연결")
                .font(.headline)

            // 저장된 서버 목록
            if !connectionStore.connections.isEmpty {
                Picker("저장된 서버", selection: $selectedSaved) {
                    Text("새 연결").tag(nil as ServerConnection?)
                    ForEach(connectionStore.connections) { conn in
                        Text(conn.name).tag(conn as ServerConnection?)
                    }
                }
                .onChange(of: selectedSaved) { _, conn in
                    if let conn {
                        name = conn.name
                        host = conn.host
                        port = String(conn.port)
                        username = conn.username
                        if case .publicKey(let path) = conn.authMethod {
                            useKey = true
                            keyPath = path
                        } else {
                            useKey = false
                        }
                        password = connectionStore.loadPassword(for: conn) ?? ""
                    }
                }
            }

            Form {
                TextField("이름", text: $name)
                TextField("호스트", text: $host)
                TextField("포트", text: $port)
                TextField("사용자", text: $username)

                Toggle("SSH 키 사용", isOn: $useKey)
                if useKey {
                    TextField("키 경로", text: $keyPath)
                } else {
                    SecureField("비밀번호", text: $password)
                }

                Toggle("연결 정보 저장", isOn: $saveConnection)
            }

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("연결") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func connect() {
        let authMethod: AuthMethod = useKey ? .publicKey(path: keyPath) : .password
        let connection = ServerConnection(
            name: name.isEmpty ? "\(username)@\(host)" : name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod
        )

        if saveConnection {
            connectionStore.add(connection)
            if !useKey && !password.isEmpty {
                try? connectionStore.savePassword(password, for: connection)
            }
        }

        onConnect(connection, useKey ? nil : password)
        dismiss()
    }
}
```

**Step 3: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

**Step 4: 커밋**

```bash
git add Sources/ShellDock/Views/SessionTabBar.swift Sources/ShellDock/Views/ConnectionDialogView.swift
git commit -m "feat: add session tab bar and connection dialog"
```

---

### Task 9: 메인 ContentView 조립

**Files:**
- Modify: `Sources/ShellDock/ShellDockApp.swift`

**Step 1: ShellDockApp 업데이트 및 ContentView 구현**

```swift
// Sources/ShellDock/ShellDockApp.swift
import SwiftUI
import AppKit

@main
struct ShellDockApp: App {
    @State private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
        }
        .defaultSize(width: 1200, height: 800)
    }
}

struct ContentView: View {
    let connectionStore: ConnectionStore
    @State private var sessions: [SSHSession] = []
    @State private var activeSessionID: UUID?
    @State private var showConnectionDialog = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var activeSession: SSHSession? {
        sessions.first { $0.id == activeSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 탭 바
            SessionTabBar(
                sessions: $sessions,
                activeSessionID: $activeSessionID,
                onNewConnection: { showConnectionDialog = true }
            )

            // 메인 분할 뷰
            if let session = activeSession {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SFTPSidebarView(session: session)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
                } detail: {
                    TerminalViewWrapper(session: session)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                VStack {
                    Image(systemName: "terminal")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("새 연결을 시작하세요")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Button("연결") { showConnectionDialog = true }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 상태 바
            HStack {
                if let session = activeSession {
                    Circle()
                        .fill(session.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(session.statusMessage)
                } else {
                    Text("연결 없음")
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .sheet(isPresented: $showConnectionDialog) {
            ConnectionDialogView(connectionStore: connectionStore) { connection, password in
                let session = SSHSession(connection: connection)
                sessions.append(session)
                activeSessionID = session.id

                Task {
                    try await session.connect(password: password)
                    try await session.openSFTP()
                }
            }
        }
    }
}
```

**Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: 실행 확인**

Run: `.build/debug/ShellDock`
Expected: 윈도우가 열리고 "새 연결을 시작하세요" 화면 표시. "연결" 버튼 클릭시 다이얼로그 표시.

**Step 4: 커밋**

```bash
git add Sources/ShellDock/ShellDockApp.swift
git commit -m "feat: assemble main ContentView with split layout, tabs, and status bar"
```

---

### Task 10: 빌드 스크립트 + .app 번들 생성

**Files:**
- Create: `scripts/build-app.sh`
- Create: `Info.plist`

**Step 1: Info.plist 생성**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ShellDock</string>
    <key>CFBundleIdentifier</key>
    <string>com.shelldock.app</string>
    <key>CFBundleName</key>
    <string>ShellDock</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

**Step 2: 빌드 스크립트 생성**

```bash
#!/bin/bash
# scripts/build-app.sh
set -e

APP_NAME="ShellDock"
BUILD_DIR=".build/release"
APP_DIR="${APP_NAME}.app/Contents"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_DIR}/MacOS"
mkdir -p "${APP_DIR}/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/MacOS/"
cp "Info.plist" "${APP_DIR}/"

echo "Done! ${APP_NAME}.app created."
echo "Run: open ${APP_NAME}.app"
```

**Step 3: 실행 권한 부여**

Run: `chmod +x scripts/build-app.sh`

**Step 4: 커밋**

```bash
git add Info.plist scripts/build-app.sh
git commit -m "feat: add app bundle build script and Info.plist"
```

---

## 구현 순서 요약

| Task | 내용 | 의존성 |
|------|------|--------|
| 1 | 프로젝트 초기 설정 | 없음 |
| 2 | 데이터 모델 | Task 1 |
| 3 | Keychain 매니저 | Task 1 |
| 4 | ConnectionStore | Task 2, 3 |
| 5 | SSH 세션 매니저 | Task 2 |
| 6 | SwiftTerm 래퍼 | Task 5 |
| 7 | SFTP 사이드바 | Task 5 |
| 8 | 탭 바 + 연결 다이얼로그 | Task 4, 5 |
| 9 | ContentView 조립 | Task 6, 7, 8 |
| 10 | 빌드 스크립트 | Task 9 |

## 주의사항

1. **Citadel API 호환성**: Citadel은 0.x 버전이라 API가 변경될 수 있음. 빌드 실패 시 Citadel 소스 코드의 실제 시그니처를 확인할 것.
2. **macOS 15.0 필요**: Citadel의 `withPTY` API가 macOS 15.0+ 필요.
3. **@unchecked Sendable**: TerminalView는 메인 스레드에서만 접근해야 하므로 Coordinator에 `@unchecked Sendable` 사용.
4. **호스트 키 검증**: `.acceptAnything()`은 개발용. 프로덕션에서는 known_hosts 검증 구현 필요.
5. **Concurrency**: Swift 6의 strict concurrency 규칙에 따라 `@MainActor` 어노테이션 필요한 곳 있을 수 있음.
