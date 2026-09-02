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
