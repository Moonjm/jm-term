// Sources/ShellDock/Views/TerminalViewWrapper.swift
import SwiftUI
import SwiftTerm
import AppKit

struct TerminalViewWrapper: NSViewRepresentable {
    let session: SSHSession

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator

        terminalView.nativeForegroundColor = NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1)
        terminalView.caretColor = .systemGreen
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.getTerminal().setCursorStyle(.steadyBlock)

        context.coordinator.session = session
        session.terminalView = terminalView

        Task {
            try await session.startShell()
        }

        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Coordinator bridges SwiftTerm's TerminalViewDelegate to our SSHSession.
    /// The delegate methods are always called on the main thread by AppKit,
    /// so we use MainActor.assumeIsolated to safely access @MainActor-isolated SSHSession.
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate, @unchecked Sendable {
        @MainActor var session: SSHSession?

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
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
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
