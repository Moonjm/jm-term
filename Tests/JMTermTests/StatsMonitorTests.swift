import XCTest
@testable import JMTerm

@MainActor
final class StatsMonitorTests: XCTestCase {

    // 정상 증가 카운터: 두 샘플 간 delta로 CPU 사용률 계산.
    func testParsesCPUUsageFromTwoSamples() {
        let monitor = StatsMonitor()
        // total=1000, idle=800
        monitor.parseStats("cpu  100 0 100 800 0 0 0 0 0 0")
        // total=2000, idle=1300 → totalDelta=1000, idleDelta=500 → 50%
        monitor.parseStats("cpu  400 0 300 1300 0 0 0 0 0 0")
        XCTAssertEqual(monitor.stats?.cpuUsage ?? -1, 50.0, accuracy: 0.01)
    }

    // 카운터가 거꾸로 가도 (재연결/서버 리부트) 언더플로 크래시 없이 0%로 처리.
    func testCPUCountersGoingBackwardsDoesNotCrash() {
        let monitor = StatsMonitor()
        monitor.parseStats("cpu  100 0 100 800 0 0 0 0 0 0")
        monitor.parseStats("cpu  10 0 10 80 0 0 0 0 0 0")
        XCTAssertEqual(monitor.stats?.cpuUsage ?? -1, 0.0, accuracy: 0.01)
        // 거꾸로 간 샘플이 새 기준점이 되어 다음 샘플부터 다시 정상 계산.
        monitor.parseStats("cpu  20 0 20 160 0 0 0 0 0 0")
        XCTAssertEqual(monitor.stats?.cpuUsage ?? -1, 20.0, accuracy: 0.01)
    }
}
