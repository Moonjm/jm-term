// Sources/JMTerm/Views/SSHKeyPicker.swift
import SwiftUI

/// ~/.ssh 에서 개인키 후보를 탐지한다.
enum SSHKeyScanner {
    /// 개인키로 보이는 파일들의 절대 경로 목록.
    /// 휴리스틱: `<name>.pub` 짝이 있거나 `id_`로 시작하는 일반 파일.
    /// known_hosts/config/authorized_keys 등은 제외.
    static func detectKeys() -> [String] {
        let dir = NSString(string: "~/.ssh").expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        let excluded: Set<String> = ["known_hosts", "known_hosts.old", "config", "authorized_keys"]
        let pubNames = Set(entries.filter { $0.hasSuffix(".pub") })

        return entries.sorted().compactMap { name in
            if name.hasSuffix(".pub") || name.hasPrefix(".") || excluded.contains(name) { return nil }
            let hasPubPair = pubNames.contains(name + ".pub")
            guard hasPubPair || name.hasPrefix("id_") else { return nil }
            // 일반 파일만 후보로(디렉터리 제외 — 예: ~/.ssh/id_backup/).
            let fullPath = dir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return fullPath
        }
    }
}

/// SSH 키 경로 입력 + ~/.ssh 자동 탐지 드롭다운 + 파일 찾아보기.
struct SSHKeyPicker: View {
    @Binding var keyPath: String
    @State private var detected: [String] = []

    var body: some View {
        HStack(spacing: 6) {
            TextField("키 경로", text: $keyPath)

            Menu {
                if detected.isEmpty {
                    Text("~/.ssh 에서 키를 찾지 못했어요")
                } else {
                    Section("~/.ssh") {
                        ForEach(detected, id: \.self) { path in
                            Button((path as NSString).lastPathComponent) { keyPath = path }
                        }
                    }
                }
                Divider()
                Button("찾아보기…") { browse() }
            } label: {
                Image(systemName: "key.fill")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .onAppear { detected = SSHKeyScanner.detectKeys() }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "SSH 키 파일 선택"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }
}
