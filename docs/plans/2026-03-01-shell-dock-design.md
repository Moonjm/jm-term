# ShellDock Design

macOS SSH/SFTP 터미널 클라이언트. MobXterm의 핵심 기능을 macOS 네이티브로 구현.

## Core Features

- SSH 터미널 (shell)
- SFTP 파일 브라우저 (트리 뷰)
- 파일 업로드/다운로드
- 서버 접속 정보 저장/관리
- 탭으로 다중 세션

## Tech Stack

- **언어**: Swift 6
- **UI**: SwiftUI (macOS)
- **SSH/SFTP**: Citadel (순수 Swift, SwiftNIO SSH 기반, async/await)
- **터미널**: SwiftTerm (NSViewRepresentable로 SwiftUI 통합)
- **비밀번호 저장**: macOS Keychain

## UI Layout

```
┌─────────────────────────────────────────────────────────┐
│  ShellDock                                    ─ □ ✕     │
├─────────────────────────────────────────────────────────┤
│  [+ 새 연결]  [서버1] [서버2] [서버3]          ← 탭 바  │
├──────────────┬──────────────────────────────────────────┤
│  📁 /home/   │  $ ssh user@server                      │
│  ├── docs/   │  Last login: ...                        │
│  ├── src/    │  user@server:~$                         │
│  │   ├── a   │                                         │
│  │   └── b   │                                         │
│  ├── .bashrc │                                         │
│  └── tmp/    │                                         │
│              │                                         │
│  [↑업로드]   │                                         │
│  [↓다운로드] │                                         │
│              │                                         │
│  ← SFTP 패널 │  ← 터미널 패널 (SwiftTerm)              │
├──────────────┴──────────────────────────────────────────┤
│  연결됨: user@192.168.1.1:22          ← 상태 바        │
└─────────────────────────────────────────────────────────┘
```

- SwiftUI NavigationSplitView 기반 2분할 레이아웃
- 왼쪽: SFTP 파일 트리 + 업로드/다운로드 버튼
- 오른쪽: SwiftTerm 터미널
- 상단: 탭 바 (다중 세션 전환)
- 하단: 연결 상태 바

## Architecture

```
ShellDockApp (SwiftUI App)
├── ConnectionStore       서버 목록 저장 (JSON + Keychain)
├── SessionManager        탭별 활성 세션 관리
│   ├── SFTPManager       디렉토리 탐색 (Citadel SFTPClient)
│   ├── SSHShellSession   터미널 데이터 중계 (Citadel ↔ SwiftTerm)
│   └── TransferManager   파일 전송 + 진행률
```

## Data Model

```swift
struct ServerConnection: Codable, Identifiable {
    let id: UUID
    var name: String           // 표시 이름
    var host: String           // 호스트 주소
    var port: Int              // 기본 22
    var username: String
    var authMethod: AuthMethod // password 또는 publicKey
}

enum AuthMethod: Codable {
    case password              // Keychain에서 비밀번호 조회
    case publicKey(path: String) // SSH 키 파일 경로
}
```

## Key Flows

1. **연결**: 서버 선택 → SSHClient.connect() → SSH 세션 수립
2. **터미널**: SSH shell 채널 → SwiftTerm에 PTY 데이터 양방향 전달
3. **파일 탐색**: 같은 연결에서 SFTP 채널 → 디렉토리 트리 표시
4. **파일 전송**: 드래그&드롭 또는 버튼 → 업로드/다운로드 + 진행률
5. **탭 관리**: 각 탭이 독립 SSH 연결 유지

## Authentication

- 비밀번호 인증: macOS Keychain에 안전하게 저장
- SSH 키 인증: 로컬 키 파일 경로 지정 (Ed25519, ECDSA 지원)

## Dependencies (Swift Package Manager)

- `orlandos-nl/Citadel` - SSH/SFTP
- `migueldeicaza/SwiftTerm` - 터미널 에뮬레이션
