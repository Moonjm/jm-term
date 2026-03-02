// Sources/ShellDock/Views/SessionTabBar.swift
import SwiftUI
import AppKit

struct SessionTabBar: View {
    @Binding var sessions: [SSHSession]
    @Binding var activeSessionID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions) { session in
                    SessionTab(
                        name: session.connection.name,
                        isConnected: session.isConnected,
                        isSelected: session.id == activeSessionID,
                        onSelect: { activeSessionID = session.id },
                        onClose: { closeSession(session) }
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.08))
    }

    private func closeSession(_ session: SSHSession) {
        Task { await session.disconnect() }
        sessions.removeAll { $0.id == session.id }
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }
}

struct SessionTab: View {
    let name: String
    let isConnected: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(name)
                .lineLimit(1)
                .font(.caption)
            if isHovered || isSelected {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.15) : Color.clear)
        )
        .overlay(TabClickOverlay(
            isCloseVisible: isHovered || isSelected,
            onSelect: onSelect,
            onClose: onClose
        ))
        .onHover { isHovered = $0 }
    }
}

// MARK: - NSView 기반 클릭 처리 (좌클릭 선택/닫기 + 휠클릭 닫기)

private struct TabClickOverlay: NSViewRepresentable {
    let isCloseVisible: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> TabClickNSView {
        let view = TabClickNSView()
        view.onSelect = onSelect
        view.onClose = onClose
        view.isCloseVisible = isCloseVisible
        return view
    }

    func updateNSView(_ nsView: TabClickNSView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onClose = onClose
        nsView.isCloseVisible = isCloseVisible
    }
}

final class TabClickNSView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var isCloseVisible = false

    override func mouseUp(with event: NSEvent) {
        if isCloseVisible {
            let location = convert(event.locationInWindow, from: nil)
            if location.x > bounds.width - 24 {
                onClose?()
                return
            }
        }
        onSelect?()
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onClose?()
        }
    }
}
