// Sources/JMTerm/Views/TerminalViewWrapper.swift
import SwiftUI
import SwiftTerm
import AppKit

private class PaddedContainerView: NSView {
    let inset: CGFloat = 8
    weak var coordinator: TerminalViewWrapper.Coordinator?

    override func layout() {
        super.layout()
        guard let terminalView = subviews.first else { return }
        terminalView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator, let tv = coordinator.terminalView else {
            super.scrollWheel(with: event)
            return
        }
        let deltaY = event.deltaY
        guard deltaY != 0 else { super.scrollWheel(with: event); return }
        guard tv.getTerminal().isCurrentBufferAlternate else {
            super.scrollWheel(with: event)
            return
        }
        let lines = max(1, Int(abs(deltaY)))
        let arrow: [UInt8] = deltaY > 0 ? [0x1b, 0x5b, 0x41] : [0x1b, 0x5b, 0x42]
        for _ in 0..<lines {
            coordinator.session?.sendToShell(Data(arrow))
        }
    }
}

struct TerminalViewWrapper: NSViewRepresentable {
    let session: SSHSession

    func makeNSView(context: Context) -> NSView {
        let container = PaddedContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let terminalView = Self.makeTerminalView(delegate: context.coordinator)
        container.addSubview(terminalView)
        container.coordinator = context.coordinator
        context.coordinator.terminalView = terminalView
        context.coordinator.session = session
        session.terminalView = terminalView

        Task { @MainActor in
            for _ in 0..<100 {
                if session.isConnected { break }
                try await Task.sleep(for: .milliseconds(100))
                if session.statusMessage.contains("실패") { return }
            }
            guard session.isConnected else {
                session.statusMessage = "연결 시간 초과"
                return
            }
            do {
                try await session.startShell()
                container.window?.makeFirstResponder(terminalView)
            } catch {
                session.statusMessage = "셸 시작 실패: \(error.localizedDescription)"
            }
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.session !== session else { return }

        let container = nsView as! PaddedContainerView

        // 기존 터미널 delegate 해제 후 제거
        if let old = coordinator.terminalView {
            old.terminalDelegate = nil
            old.removeFromSuperview()
        }

        if let existing = session.terminalView {
            // 이미 터미널이 있는 세션 (되돌아온 경우)
            container.addSubview(existing)
            existing.terminalDelegate = coordinator
            coordinator.terminalView = existing
            coordinator.session = session
        } else {
            // 새 세션 — 터미널 생성 및 셸 시작
            let tv = Self.makeTerminalView(delegate: coordinator)
            container.addSubview(tv)
            coordinator.terminalView = tv
            coordinator.session = session
            session.terminalView = tv

            Task { @MainActor in
                for _ in 0..<100 {
                    if session.isConnected { break }
                    try await Task.sleep(for: .milliseconds(100))
                    if session.statusMessage.contains("실패") { return }
                }
                guard session.isConnected else {
                    session.statusMessage = "연결 시간 초과"
                    return
                }
                do {
                    try await session.startShell()
                } catch {
                    session.statusMessage = "셸 시작 실패: \(error.localizedDescription)"
                }
            }
        }

        container.needsLayout = true
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(coordinator.terminalView)
        }
    }

    private static func makeTerminalView(delegate: Coordinator) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = delegate
        tv.nativeForegroundColor = NSColor(white: 0.85, alpha: 1)
        tv.nativeBackgroundColor = NSColor.black
        tv.caretColor = .systemGreen
        tv.optionAsMetaKey = true
        tv.allowMouseReporting = true
        tv.getTerminal().setCursorStyle(.steadyBlock)
        return tv
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Coordinator bridges SwiftTerm's TerminalViewDelegate to our SSHSession.
    /// The delegate methods are always called on the main thread by AppKit,
    /// so we use MainActor.assumeIsolated to safely access @MainActor-isolated SSHSession.
    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        @MainActor var session: SSHSession?
        var terminalView: TerminalView?

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                session?.sendToShell(Data(data))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                session?.resizeTerminal(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            MainActor.assumeIsolated {
                guard let directory, let session else { return }
                // OSC 7 sends "file://hostname/path" format
                if let url = URL(string: directory) {
                    let path = url.path
                    if !path.isEmpty {
                        session.currentPath = path
                    }
                } else {
                    session.currentPath = directory
                }
            }
        }
        func scrolled(source: TerminalView, position: Double) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }

        func bell(source: TerminalView) { NSSound.beep() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
