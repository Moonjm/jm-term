import Foundation

enum BuildInfo {
    static let version: String = {
        let date = Date()
        let f = DateFormatter()
        f.dateFormat = "yyMMdd.HHmm"
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        return f.string(from: date)
    }()
}
