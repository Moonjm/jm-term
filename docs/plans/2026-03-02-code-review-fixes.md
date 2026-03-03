# Code Review Fixes: Stats OS Detection + SFTP Progress/Cancel

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stats 모니터가 non-Linux 서버에서도 동작하게 하고, SFTP 파일 전송에 취소/진행률 기능을 추가한다.

**Architecture:** (1) StatsMonitor는 첫 폴링에서 `uname` 실행 → OS 감지 → OS별 명령 분기. 미지원 OS면 stats를 nil로 두고 모니터 종료. (2) SFTPService의 기존 청크 I/O 루프에 `Task.checkCancellation()` + progress callback 추가. (3) SFTPViewModel에 전송 상태 추적 + SFTPSidebarView에 진행률 바/취소 버튼 UI. (4) JMTermApp 상태 바에서 네트워크 행을 Linux일 때만 표시.

**Tech Stack:** Swift, Citadel (SFTP), SwiftUI

**수정 파일:**
- `Sources/JMTerm/Services/StatsMonitor.swift` — OS 감지 + 명령 분기
- `Sources/JMTerm/Services/SFTPService.swift` — progress callback + 취소
- `Sources/JMTerm/ViewModels/SFTPViewModel.swift` — 전송 상태 + progress 연결
- `Sources/JMTerm/Views/SFTPSidebarView.swift` — 진행률 바 UI
- `Sources/JMTerm/JMTermApp.swift` — 네트워크 행 조건부 표시

---

### Task 1: StatsMonitor에 OS 감지 추가

**Files:**
- Modify: `Sources/JMTerm/Services/StatsMonitor.swift:6-31` (ServerOS 열거형 + ServerStats에 os 필드)
- Modify: `Sources/JMTerm/Services/StatsMonitor.swift:42-63` (start 메서드 OS 감지 분기)
- Modify: `Sources/JMTerm/Services/StatsMonitor.swift:70-134` (parseStats에 os 파라미터 + macOS 파싱)

**Step 1: ServerOS 열거형 추가 및 ServerStats에 os 필드 추가**

`StatsMonitor.swift` 상단, `ServerStats` 구조체 바로 위에 열거형 추가하고 구조체에 필드 추가:

```swift
enum ServerOS: String {
    case linux, darwin, unknown
}

struct ServerStats {
    var os: ServerOS = .unknown
    var cpuUsage: Double = 0       // %
    // ... 나머지 필드 동일
```

**Step 2: start(client:) 메서드에서 OS 감지 후 명령 분기**

기존 `start(client:)` (라인 42-63)를 교체. 루프 진입 전 `uname` 실행으로 OS 감지:

```swift
func start(client: SSHClient) {
    let clientBox = UncheckedSendableBox(value: client)

    statsTask = Task { [weak self] in
        // OS 감지 (최초 1회)
        let os: ServerOS
        do {
            let unameOutput = try await clientBox.value.executeCommand("uname")
            let uname = String(buffer: unameOutput).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if uname == "linux" {
                os = .linux
            } else if uname == "darwin" {
                os = .darwin
            } else {
                os = .unknown
            }
        } catch {
            os = .unknown
        }

        // 미지원 OS — stats 모니터링 중단
        guard os != .unknown else { return }

        let cmd: String
        switch os {
        case .linux:
            cmd = """
            head -1 /proc/stat; \
            awk '/MemTotal/{printf "MEMTOTAL %d\\n",$2}/MemAvailable/{printf "MEMAVAIL %d\\n",$2}' /proc/meminfo; \
            df -h / | awk 'NR==2{printf "DISK %s %s %s\\n",$2,$3,$5}'; \
            awk 'NR>2{rx+=$2;tx+=$10}END{printf "NET %d %d\\n",rx,tx}' /proc/net/dev
            """
        case .darwin:
            cmd = """
            top -l 1 -n 0 | awk '/CPU usage/{gsub(/%/,"");printf "CPU %s\\n",$3+$5}'; \
            vm_stat | awk '/Pages free/{free=$3}/Pages active/{active=$3}/Pages speculative/{spec=$3}/page size of/{ps=$8}END{gsub(/\\./,"",free);gsub(/\\./,"",active);gsub(/\\./,"",spec);ps=ps+0;t=(free+active+spec)*ps/1024;u=(active+spec)*ps/1024;printf "MEMTOTAL %d\\nMEMUSED %d\\n",t,u}'; \
            df -h / | awk 'NR==2{printf "DISK %s %s %s\\n",$2,$3,$5}'
            """
        case .unknown:
            return
        }

        while !Task.isCancelled {
            do {
                let output = try await clientBox.value.executeCommand(cmd)
                let text = String(buffer: output)
                self?.parseStats(text, os: os)
            } catch {
                // 명령 실패 시 무시하고 다음 폴링 대기
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
```

macOS에서는 네트워크 속도를 수집하지 않음 (netRxSpeed/netTxSpeed는 0 유지).

**Step 3: parseStats에 os 파라미터 추가 + macOS 파싱**

`parseStats(_ output: String)` 시그니처를 `parseStats(_ output: String, os: ServerOS)`로 변경.
`var newStats = ServerStats()`를 `var newStats = ServerStats(os: os)`로 변경.
기존 `cpu ` 파싱 블록 뒤에 macOS CPU 파싱 추가.
기존 `MEMAVAIL` 블록 뒤에 macOS `MEMUSED` 파싱 추가:

```swift
// 기존 "cpu " 블록 뒤에 추가
if trimmed.hasPrefix("CPU ") && !trimmed.hasPrefix("CPU usage") {
    let val = trimmed.replacingOccurrences(of: "CPU ", with: "")
    newStats.cpuUsage = Double(val) ?? 0
}

// 기존 MEMAVAIL 블록 뒤에 추가
if trimmed.hasPrefix("MEMUSED ") {
    let val = trimmed.replacingOccurrences(of: "MEMUSED ", with: "")
    newStats.memUsed = UInt64(val) ?? 0
}
```

**Step 4: 빌드 확인**

Run: `cd /Users/jm/Documents/study/jm-term && swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 5: 커밋**

```bash
git add Sources/JMTerm/Services/StatsMonitor.swift
git commit -m "fix: add OS detection to stats monitor for non-Linux servers"
```

---

### Task 2: JMTermApp 상태 바에서 네트워크 행 조건부 표시

**Files:**
- Modify: `Sources/JMTerm/JMTermApp.swift:110-116` (네트워크 행에 `if stats.os == .linux` 조건 추가)

**Step 1: 네트워크 HStack을 Linux 조건으로 감싸기**

`JMTermApp.swift` 라인 110-116의 네트워크 표시 블록을 수정:

```swift
// 기존:
                        Divider().frame(height: 12)

                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text("↓\(ServerStats.formatSpeed(stats.netRxSpeed))")
                            Text("↑\(ServerStats.formatSpeed(stats.netTxSpeed))")
                        }

// 변경:
                        if stats.os == .linux {
                            Divider().frame(height: 12)

                            HStack(spacing: 4) {
                                Image(systemName: "network")
                                Text("↓\(ServerStats.formatSpeed(stats.netRxSpeed))")
                                Text("↑\(ServerStats.formatSpeed(stats.netTxSpeed))")
                            }
                        }
```

**Step 2: 빌드 확인**

Run: `cd /Users/jm/Documents/study/jm-term && swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 3: 커밋**

```bash
git add Sources/JMTerm/JMTermApp.swift
git commit -m "fix: hide network stats row on non-Linux connections"
```

---

### Task 3: SFTPService에 progress callback + 취소 추가

**Files:**
- Modify: `Sources/JMTerm/Services/SFTPService.swift:63-95` (downloadFile, uploadFile 수정)

**Step 1: downloadFile에 progress + 취소 추가**

기존 `downloadFile` (라인 63-79) 교체. 기존 FileHandle 스트리밍 구조 유지하면서 `Task.checkCancellation()` + progress callback 추가:

```swift
func downloadFile(
    remotePath: String,
    localURL: URL,
    progress: (@Sendable (Int64, Int64) -> Void)? = nil
) async throws {
    guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
    try await sftp.withFile(filePath: remotePath, flags: .read) { file in
        let attrs = try await file.readAttributes()
        let totalSize = Int64(attrs.size ?? 0)

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { handle.closeFile() }

        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try await file.read(from: offset, length: Self.chunkSize)
            let data = Data(buffer: chunk)
            if data.isEmpty { break }
            handle.write(data)
            offset += UInt64(data.count)
            progress?(Int64(offset), totalSize)
        }
    }
}
```

**Step 2: uploadFile에 progress + 취소 추가**

기존 `uploadFile` (라인 81-95) 교체:

```swift
func uploadFile(
    localURL: URL,
    remotePath: String,
    progress: (@Sendable (Int64, Int64) -> Void)? = nil
) async throws {
    guard let sftp = sftpClient else { throw SSHSessionError.notConnected }
    let handle = try FileHandle(forReadingFrom: localURL)
    defer { handle.closeFile() }

    let totalSize = Int64(handle.seekToEndOfFile())
    handle.seek(toFileOffset: 0)

    try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
        var offset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = handle.readData(ofLength: Int(Self.chunkSize))
            if data.isEmpty { break }
            try await file.write(ByteBuffer(data: data), at: offset)
            offset += UInt64(data.count)
            progress?(Int64(offset), totalSize)
        }
    }
}
```

progress 기본값 nil → 기존 호출부(dragProvider, handleDrop 등) 변경 없이 호환.

**Step 3: 빌드 확인**

Run: `cd /Users/jm/Documents/study/jm-term && swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 4: 커밋**

```bash
git add Sources/JMTerm/Services/SFTPService.swift
git commit -m "feat: add progress callback and cancellation to SFTP download/upload"
```

---

### Task 4: SFTPViewModel에 전송 상태 + progress 연결

**Files:**
- Modify: `Sources/JMTerm/ViewModels/SFTPViewModel.swift`

**Step 1: 전송 상태 프로퍼티 추가**

기존 `isDropTargeted` 뒤(라인 16)에 추가:

```swift
var transferProgress: Double = 0
var transferFileName: String?
var transferTask: Task<Void, Never>?
```

**Step 2: cancelTransfer 함수 추가**

`cdInTerminal` 뒤(라인 93)에 추가:

```swift
func cancelTransfer() {
    transferTask?.cancel()
    transferTask = nil
    transferFileName = nil
    transferProgress = 0
}
```

**Step 3: handleDrop 교체**

기존 `handleDrop` (라인 128-142) 교체. 동시 전송 가드 + progress 연결:

```swift
func handleDrop(_ providers: [NSItemProvider]) {
    guard transferTask == nil else { return }
    transferTask = Task { @MainActor in
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                let remotePath = "\(session.currentPath)/\(url.lastPathComponent)"
                transferFileName = url.lastPathComponent
                transferProgress = 0
                do {
                    try await session.sftpService.uploadFile(localURL: url, remotePath: remotePath) { completed, total in
                        Task { @MainActor in
                            self.transferProgress = total > 0 ? Double(completed) / Double(total) : 0
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        transferFileName = nil
        transferProgress = 0
        transferTask = nil
        await loadDirectory()
    }
}
```

**Step 4: downloadNode 교체**

기존 `downloadNode` (라인 144-156) 교체. 동시 전송 가드 + progress 연결:

```swift
func downloadNode(_ node: FileNode) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = node.name
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard transferTask == nil else { return }

    transferFileName = node.name
    transferProgress = 0
    transferTask = Task {
        do {
            try await session.sftpService.downloadFile(remotePath: node.path, localURL: url) { completed, total in
                Task { @MainActor in
                    self.transferProgress = total > 0 ? Double(completed) / Double(total) : 0
                }
            }
        } catch is CancellationError {
            // 사용자 취소
        } catch {
            errorMessage = "다운로드 실패: \(error.localizedDescription)"
        }
        transferFileName = nil
        transferProgress = 0
        transferTask = nil
    }
}
```

**Step 5: 빌드 확인**

Run: `cd /Users/jm/Documents/study/jm-term && swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 6: 커밋**

```bash
git add Sources/JMTerm/ViewModels/SFTPViewModel.swift
git commit -m "feat: add transfer progress state and cancellation to SFTPViewModel"
```

---

### Task 5: SFTPSidebarView에 진행률 바 UI 추가

**Files:**
- Modify: `Sources/JMTerm/Views/SFTPSidebarView.swift:37-38` (Divider와 파일 목록 사이에 진행률 바 삽입)

**Step 1: 진행률 바 UI 삽입**

`SFTPSidebarView.swift` 라인 37 `Divider()` 뒤, 라인 39 `// 파일 목록` 앞에 삽입:

```swift
            Divider()

            // 전송 진행률 바
            if let fileName = viewModel.transferFileName {
                HStack(spacing: 8) {
                    ProgressView(value: viewModel.transferProgress)
                        .frame(maxWidth: .infinity)
                    Text(fileName)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 60)
                    Button(action: { viewModel.cancelTransfer() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()
            }

            // 파일 목록
```

**Step 2: 빌드 확인**

Run: `cd /Users/jm/Documents/study/jm-term && swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 3: 커밋**

```bash
git add Sources/JMTerm/Views/SFTPSidebarView.swift
git commit -m "feat: add transfer progress bar and cancel button to SFTP sidebar"
```
