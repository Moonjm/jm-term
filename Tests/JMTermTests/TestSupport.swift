import Foundation
import XCTest

/// 바인드 후 바로 닫아 "리슨 중이 아닌" 루프백 포트 번호를 얻는다. 여기로 connect 하면 즉시 refused 된다.
func reservedClosedLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
    }
    XCTAssertEqual(bound, 0)
    let got = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    XCTAssertEqual(got, 0)
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// accept 큐를 가득 채운 루프백 리스너. 여기로 connect 하면 커널이 SYN 을 버려서
/// 응답 없이 timeout 되는 "블랙홀 호스트"를 환경(라우팅·VPN)과 무관하게 재현한다.
///
/// macOS 는 `listen(fd, 1)` 상태에서 accept 되지 않은 연결이 1개 있으면 이후 SYN 을 응답 없이 버린다.
final class BlackholeListener {
    let port: Int
    private var fds: [Int32] = []

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        fds.append(listener)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, len) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
        }
        guard got == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        port = Int(UInt16(bigEndian: addr.sin_port))

        // 큐를 채우는 연결 1개. accept 하지 않은 채 열어 둔다.
        let filler = socket(AF_INET, SOCK_STREAM, 0)
        guard filler >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        fds.append(filler)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(filler, $0, len) }
        }
        guard connected == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    deinit { for fd in fds { close(fd) } }
}
