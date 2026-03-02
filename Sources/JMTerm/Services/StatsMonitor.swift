// Sources/JMTerm/Services/StatsMonitor.swift
import Foundation
import Citadel
import NIOCore

struct ServerStats {
    var cpuUsage: Double = 0       // %
    var memTotal: UInt64 = 0       // KB
    var memUsed: UInt64 = 0        // KB
    var diskTotal: String = ""     // "96G"
    var diskUsed: String = ""      // "48G"
    var diskPercent: String = ""   // "50%"
    var netRxSpeed: UInt64 = 0     // bytes/sec
    var netTxSpeed: UInt64 = 0     // bytes/sec

    var formattedMemory: String {
        let usedGB = Double(memUsed) / 1_048_576.0
        let totalGB = Double(memTotal) / 1_048_576.0
        return String(format: "%.1f/%.1fGB", usedGB, totalGB)
    }

    static func formatSpeed(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec)B/s"
        } else if bytesPerSec < 1_048_576 {
            return String(format: "%.1fKB/s", Double(bytesPerSec) / 1024.0)
        } else {
            return String(format: "%.1fMB/s", Double(bytesPerSec) / 1_048_576.0)
        }
    }
}

@MainActor
@Observable
final class StatsMonitor {
    var stats: ServerStats?

    private var statsTask: Task<Void, Never>?
    private var prevCPU: (idle: UInt64, total: UInt64)?
    private var prevNet: (rx: UInt64, tx: UInt64, time: Date)?

    func start(client: SSHClient) {
        let clientBox = UncheckedSendableBox(value: client)

        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let cmd = """
                    head -1 /proc/stat; \
                    awk '/MemTotal/{printf "MEMTOTAL %d\\n",$2}/MemAvailable/{printf "MEMAVAIL %d\\n",$2}' /proc/meminfo; \
                    df -h / | awk 'NR==2{printf "DISK %s %s %s\\n",$2,$3,$5}'; \
                    awk 'NR>2{rx+=$2;tx+=$10}END{printf "NET %d %d\\n",rx,tx}' /proc/net/dev
                    """
                    let output = try await clientBox.value.executeCommand(cmd)
                    let text = String(buffer: output)
                    self?.parseStats(text)
                } catch {
                    // 명령 실패 시 무시하고 다음 폴링 대기
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        statsTask?.cancel()
        statsTask = nil
    }

    private func parseStats(_ output: String) {
        let lines = output.components(separatedBy: "\n")
        var newStats = ServerStats()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // CPU: "cpu  user nice system idle iowait irq softirq steal guest guest_nice"
            if trimmed.hasPrefix("cpu ") {
                let parts = trimmed.split(separator: " ").dropFirst() // drop "cpu"
                let values = parts.compactMap { UInt64($0) }
                if values.count >= 4 {
                    let idle = values[3]
                    let total = values.reduce(0, +)
                    if let prev = prevCPU {
                        let totalDelta = total - prev.total
                        let idleDelta = idle - prev.idle
                        if totalDelta > 0 {
                            newStats.cpuUsage = Double(totalDelta - idleDelta) / Double(totalDelta) * 100
                        }
                    }
                    prevCPU = (idle: idle, total: total)
                }
            }

            if trimmed.hasPrefix("MEMTOTAL ") {
                let val = trimmed.replacingOccurrences(of: "MEMTOTAL ", with: "")
                newStats.memTotal = UInt64(val) ?? 0
            }

            if trimmed.hasPrefix("MEMAVAIL ") {
                let val = trimmed.replacingOccurrences(of: "MEMAVAIL ", with: "")
                let avail = UInt64(val) ?? 0
                newStats.memUsed = newStats.memTotal > avail ? newStats.memTotal - avail : 0
            }

            if trimmed.hasPrefix("DISK ") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 4 {
                    newStats.diskTotal = String(parts[1])
                    newStats.diskUsed = String(parts[2])
                    newStats.diskPercent = String(parts[3])
                }
            }

            if trimmed.hasPrefix("NET ") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 3 {
                    let rx = UInt64(parts[1]) ?? 0
                    let tx = UInt64(parts[2]) ?? 0
                    let now = Date()
                    if let prev = prevNet {
                        let elapsed = now.timeIntervalSince(prev.time)
                        if elapsed > 0, rx >= prev.rx, tx >= prev.tx {
                            newStats.netRxSpeed = UInt64(Double(rx - prev.rx) / elapsed)
                            newStats.netTxSpeed = UInt64(Double(tx - prev.tx) / elapsed)
                        }
                    }
                    prevNet = (rx: rx, tx: tx, time: now)
                }
            }
        }

        stats = newStats
    }
}
