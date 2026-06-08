# 점프 호스트(바스티온) 경유 연결 설계

작성일: 2026-06-08
대상: JMTerm (SSH/SFTP 터미널 macOS 앱)

## 1. 목표

바스티온/게이트웨이 서버(예: 공인 IP:22)를 거쳐 그 내부망의 다른 서버에
접속하는 기능을 추가한다. 핵심 요구사항:

- 최종(내부) 서버에 대해 **셸 + 좌측 SFTP 사이드바**가 기존 직접 연결과
  완전히 동일하게 동작해야 한다.
- 여러 게이트웨이를 순서대로 거치는 **multi-hop 체인**을 지원한다.
- 바스티온과 내부 서버의 자격증명(계정/키/비밀번호)은 **각각 독립**이다.
- MobaXterm의 "SSH gateway(jump host)" 설정과 동등한 UX(설정 필드 기반).

비목표(YAGNI):
- 터미널에 직접 친 `ssh`를 화면 스크래핑으로 추적하는 형태(불안정).
- 즉석 명령어로 연결하는 형태.
- 동적 로컬 포트 바인딩(실제 listen 소켓) — 인-프로세스 터널로 충분.

## 2. 핵심 메커니즘

Citadel의 `SSHClient.jump(to:)`를 사용한다. 이 API는 현재 `SSHClient` 위에
direct-tcpip 채널을 열고, 그 채널 위로 **완전한 새 `SSHClient`**를 핸드셰이크하여
반환한다. 반환된 클라이언트는 일반 연결과 동일하게 `withPTY`, `openSFTP()`,
`executeCommand` 등을 모두 지원한다.

따라서 최종 서버 세션은 "어떻게 만들어진 `SSHClient`인지"만 다를 뿐,
셸/SFTP/CWD 폴링/모니터링 코드는 그대로 재사용된다. 실제 localhost 포트를
바인딩하지 않는 인-프로세스 터널이며, 결과는 로컬 포트포워딩과 동일하다.

참고 시그니처:

```swift
public func jump(to settings: SSHClientSettings) async throws -> SSHClient

public struct SSHClientSettings {
    var host: String
    var port: Int
    var authenticationMethod: @Sendable () -> SSHAuthenticationMethod
    var hostKeyValidator: SSHHostKeyValidator
    // algorithms, protocolOptions 등은 기본값
}
```

## 3. 데이터 모델 (`Sources/JMTerm/Models/ServerConnection.swift`)

```swift
struct JumpHost: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var host: String
    var port: Int           // 기본 22
    var username: String
    var authMethod: AuthMethod   // 기존 enum 재사용 (.password / .publicKey)
}

struct ServerConnection: Codable, Identifiable, Hashable, Sendable {
    // ... 기존 필드 ...
    var jumpHosts: [JumpHost] = []   // 빈 배열 = 직접 연결 (기존 동작)
}
```

- `jumpHosts`의 순서가 경유 순서다: `jumpHosts[0]` → `jumpHosts[1]` → … →
  최종 서버(`ServerConnection` 본체).
- 커스텀 디코딩 구현으로 기존 `connections.json`(필드 없음)이 빈 배열로
  디코딩되어 하위 호환된다. (Swift 합성 Codable은 누락 키에 대해 throw하므로,
  커스텀 `init(from:)`에서 `decodeIfPresent(...) ?? []`로 처리한다.)
- 저장된 `ServerConnection`은 **최종(내부) 서버**를 나타내고, `jumpHosts`는
  경유지 목록으로 첨부된다.

## 4. 연결 흐름 (`Sources/JMTerm/Services/SSHSession.swift`)

hop 체인 `[J0, J1, …, Jn]` + 최종 타깃 `T` 기준:

```
c0     = SSHClient.connect(J0)         // 최초 바스티온만 실제 TCP 연결
c1     = c0.jump(to: settings(J1))     // 이전 클라이언트 위로 터널
...
cn     = c_{n-1}.jump(to: settings(Jn))
target = cn.jump(to: settings(T))      // 최종 서버 SSHClient
self.client = target
```

- 체인이 비어 있으면(`jumpHosts.isEmpty`) 기존 `SSHClient.connect(T)` 경로를
  그대로 사용한다.
- 중간/바스티온 클라이언트들(`c0…cn`)을 배열로 보관하고, `disconnect()` 시
  **역순으로 close**한다(타깃 → cn → … → c0).
- 각 hop·타깃마다 **자체 host key 검증**: 기존 `KnownHostsManager` 조회를 각
  host:port에 대해 수행하고, 미지/불일치 시 기존 `hostKeyPromptHandler`(큐)를
  재사용한다.
- 각 hop·타깃마다 **자체 auth**: 기존 `resolveAuthMethod` 로직을 hop에도 적용할
  수 있도록 일반화한다(현재는 `ServerConnection` 전용 → host/port/username/
  authMethod/password를 받는 형태로 분리).
- 셸/SFTP/CWD 폴링/모니터링 코드는 무변경 — 최종 `client` 하나만 바라본다.

### 메서드 시그니처 변경

`connect(password:)`는 hop별 비밀번호가 필요하므로 자격증명 묶음을 받도록
일반화한다. 예:

```swift
struct ResolvedCredentials {
    var targetPassword: String?
    var jumpPasswords: [UUID: String]   // JumpHost.id → password
}

func connect(credentials: ResolvedCredentials) async throws
```

(정확한 형태는 구현 계획에서 확정. 기존 단일 password 경로도 이 구조로 표현 가능.)

## 5. 인증 / 비밀번호

- Keychain 계정 키는 각 hop의 `username@host:port` 규칙을 그대로 따른다
  (기존 `ConnectionStore.savePassword`/`loadPassword` 규칙). hop과 타깃이 자연히
  독립 저장된다.
- 연결 시작 시 `SessionCoordinator`가 필요한 모든 비밀번호(각 password-auth hop +
  타깃)를 Keychain에서 먼저 조회한다.
- 누락된 비밀번호는 **순차적으로 프롬프트**한다. 기존 `PasswordPromptView`를
  재사용하되, 어떤 호스트의 비밀번호인지 라벨로 표시한다
  (예: "바스티온 user@10.0.0.1:22 비밀번호").
- 키 인증(`.publicKey`) hop은 비밀번호 프롬프트가 필요 없다.
- host key 프롬프트도 hop 수만큼 발생할 수 있다. 기존 `hostKeyQueue`가 순차
  처리하므로 추가 작업 없이 동작한다.

## 6. UI (`Sources/JMTerm/Views/ConnectionFormView.swift` 등)

- 연결 추가/수정 폼에 **"점프 호스트 경유"** 섹션을 추가한다.
  - hop 목록: 추가 / 삭제 / 순서 조정.
  - 각 hop 행은 기존 연결 폼과 동일한 필드(host / port / username / auth +
    키 파일 선택)를 사용하는 재사용 서브뷰로 구현한다.
- hop 목록이 비어 있으면 화면은 기존 직접 연결 폼과 동일하다.
- `EditConnectionView`에서도 동일 섹션으로 편집 가능.
- 서버 목록 표시에 경유 여부를 가볍게 나타내는 표식(선택) — 구현 계획에서 결정.

## 7. 수명주기 / 테스트

- 중간 hop이 끊기면 그 위의 터널·최종 채널도 닫힌다 → 기존 `sshSessionEnded`
  알림 처리로 세션이 정리된다.
- `disconnect()`는 보관한 클라이언트들을 역순으로 close한다.
- `testConnection`(정적)도 전체 체인을 따라 연결을 시도하고 즉시 닫도록
  확장한다. 타임아웃/취소 처리는 기존 구조를 유지한다.

## 8. 영향 범위 요약

| 파일 | 변경 |
|---|---|
| `Models/ServerConnection.swift` | `JumpHost` 추가, `jumpHosts` 필드 추가 |
| `Services/SSHSession.swift` | jump 체인 연결, auth 일반화, disconnect 역순 close, testConnection 확장 |
| `ViewModels/SessionCoordinator.swift` | 자격증명 수집 + 순차 비밀번호 프롬프트 |
| `Views/ConnectionFormView.swift` / `EditConnectionView.swift` | 점프 호스트 섹션 UI |
| `Services/ConnectionStore.swift` | (필요 시) hop 비밀번호 저장/삭제 정리 |

## 9. 리스크 / 검증 포인트

- `jump(to:)`의 host key 검증 콜백이 우리 `hostKeyPromptHandler`와 매끄럽게
  연동되는지 실제 연결로 검증 필요.
- multi-hop에서 비밀번호/호스트키 프롬프트가 순차적으로 올바르게 큐잉되는지 확인.
- 중간 hop 끊김 시 자원(클라이언트들) 누수 없이 정리되는지 확인.
