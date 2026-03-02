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

    /// Parses plain (non-hashed) entries from known_hosts.
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

            guard let (hostnames, key) = parseLineKey(trimmed) else { continue }

            for hostname in hostnames {
                result[hostname, default: []].insert(key)
            }
        }

        return result
    }

    // MARK: - Lookup

    static func lookup(host: String, port: Int) -> HostKeyStatus {
        let lookupKey = port == 22 ? host : "[\(host)]:\(port)"
        let entries = parse()

        if let keys = entries[lookupKey], !keys.isEmpty {
            return .trusted(keys)
        }

        // Check hashed entries
        let hashedKeys = lookupHashed(host: host, port: port)
        if !hashedKeys.isEmpty {
            return .trusted(hashedKeys)
        }

        return .unknown
    }

    // MARK: - Hashed entry lookup

    /// Matches |1|salt|hash format entries using HMAC-SHA1.
    private static func lookupHashed(host: String, port: Int) -> Set<NIOSSHPublicKey> {
        guard let content = try? String(contentsOfFile: knownHostsPath, encoding: .utf8) else {
            return []
        }

        let hostname = port == 22 ? host : "[\(host)]:\(port)"
        var matched: Set<NIOSSHPublicKey> = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|1|") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { continue }

            let hashField = String(parts[0])
            // Format: |1|base64salt|base64hash
            let hashParts = hashField.split(separator: "|", omittingEmptySubsequences: true)
            guard hashParts.count == 3,
                  hashParts[0] == "1",
                  let salt = Data(base64Encoded: String(hashParts[1])),
                  let expectedHash = Data(base64Encoded: String(hashParts[2])) else {
                continue
            }

            // HMAC-SHA1 of hostname with salt
            let key = SymmetricKey(data: salt)
            let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(hostname.utf8), using: key)
            let computedHash = Data(hmac)

            if computedHash == expectedHash {
                let keyType = String(parts[1])
                let base64Data = String(parts[2].split(separator: " ").first ?? parts[2])
                if let publicKey = try? NIOSSHPublicKey(openSSHPublicKey: "\(keyType) \(base64Data)") {
                    matched.insert(publicKey)
                }
            }
        }

        return matched
    }

    // MARK: - Add entry

    static func addEntry(host: String, port: Int, key: NIOSSHPublicKey) {
        let hostnameField = port == 22 ? host : "[\(host)]:\(port)"
        let serialized = String(openSSHPublicKey: key)
        let line = "\(hostnameField) \(serialized)\n"

        let path = knownHostsPath
        let sshDir = (path as NSString).deletingLastPathComponent

        // Create ~/.ssh with 700 permissions
        if !FileManager.default.fileExists(atPath: sshDir) {
            try? FileManager.default.createDirectory(
                atPath: sshDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        if FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            // Create known_hosts with 644 permissions
            FileManager.default.createFile(
                atPath: path,
                contents: line.data(using: .utf8),
                attributes: [.posixPermissions: 0o644]
            )
        }
    }

    // MARK: - Update entry (replace existing key for host)

    static func updateEntry(host: String, port: Int, key: NIOSSHPublicKey) {
        removeEntries(host: host, port: port)
        addEntry(host: host, port: port, key: key)
    }

    // MARK: - Remove entries for host

    static func removeEntries(host: String, port: Int) {
        let path = knownHostsPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let hostnameField = port == 22 ? host : "[\(host)]:\(port)"
        let lines = content.components(separatedBy: "\n")
        var filtered: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Keep empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                filtered.append(line)
                continue
            }

            // Check plain hostname match
            if !trimmed.hasPrefix("|") {
                let hostField = String(trimmed.split(separator: " ", maxSplits: 1).first ?? "")
                let hosts = hostField.split(separator: ",").map { String($0) }
                if hosts.contains(hostnameField) {
                    continue // Remove this line
                }
            }

            filtered.append(line)
        }

        let result = filtered.joined(separator: "\n")
        try? result.write(toFile: path, atomically: true, encoding: .utf8)
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

    // MARK: - Helpers

    private static func parseLineKey(_ line: String) -> ([String], NIOSSHPublicKey)? {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 3 else { return nil }

        let hostnameField = String(parts[0])
        let keyType = String(parts[1])
        let base64Data = String(parts[2].split(separator: " ").first ?? parts[2])

        guard let publicKey = try? NIOSSHPublicKey(openSSHPublicKey: "\(keyType) \(base64Data)") else {
            return nil
        }

        let hostnames = hostnameField.split(separator: ",").map { String($0) }
        return (hostnames, publicKey)
    }
}
