// Sources/JMTerm/Services/KnownHostsManager.swift
import Foundation
import Crypto
import NIOCore
import NIOSSH

enum HostKeyStatus {
    case trusted(Set<NIOSSHPublicKey>)
    case unknown
}

struct KnownHostsManager {

    private static var knownHostsPath: String {
        NSString(string: "~/.ssh/known_hosts").expandingTildeInPath
    }

    // MARK: - Parse known_hosts

    static func parse() -> [String: Set<NIOSSHPublicKey>] {
        guard let content = try? String(contentsOfFile: knownHostsPath, encoding: .utf8) else {
            return [:]
        }

        var result: [String: Set<NIOSSHPublicKey>] = [:]

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("|") {
                continue
            }

            let parts = trimmed.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { continue }

            let hostnameField = String(parts[0])
            let keyType = String(parts[1])
            let base64Data = String(parts[2].split(separator: " ").first ?? parts[2])

            let openSSHString = "\(keyType) \(base64Data)"
            guard let publicKey = try? NIOSSHPublicKey(openSSHPublicKey: openSSHString) else {
                continue
            }

            let hostnames = hostnameField.split(separator: ",").map { String($0) }
            for hostname in hostnames {
                result[hostname, default: []].insert(publicKey)
            }
        }

        return result
    }

    // MARK: - Lookup

    static func lookup(host: String, port: Int) -> HostKeyStatus {
        let entries = parse()

        let key = port == 22 ? host : "[\(host)]:\(port)"

        if let keys = entries[key], !keys.isEmpty {
            return .trusted(keys)
        }

        if port != 22, let keys = entries[host], !keys.isEmpty {
            return .trusted(keys)
        }

        return .unknown
    }

    // MARK: - Add entry

    static func addEntry(host: String, port: Int, key: NIOSSHPublicKey) {
        let hostnameField = port == 22 ? host : "[\(host)]:\(port)"
        let serialized = String(openSSHPublicKey: key)
        let line = "\(hostnameField) \(serialized)\n"

        let path = knownHostsPath
        let sshDir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: sshDir, withIntermediateDirectories: true)

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Fingerprint

    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let keyData = Data(buffer.readableBytesView)

        let hash = SHA256.hash(data: keyData)
        let base64 = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }
}
