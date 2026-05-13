import Foundation

enum BuildInfo {
    static let version: String = {
        if let stamped = Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String,
           !stamped.isEmpty {
            return stamped
        }
        return "dev"
    }()
}
