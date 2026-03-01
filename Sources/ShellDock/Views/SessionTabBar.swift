// Sources/ShellDock/Views/SessionTabBar.swift
import SwiftUI

struct SessionTabBar: View {
    @Binding var sessions: [SSHSession]
    @Binding var activeSessionID: UUID?
    var onNewConnection: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onNewConnection) {
                Image(systemName: "plus")
                    .frame(width: 36, height: 28)
            }
            .buttonStyle(.plain)

            ForEach(sessions) { session in
                SessionTab(
                    name: session.connection.name,
                    isConnected: session.isConnected,
                    isSelected: session.id == activeSessionID,
                    onSelect: { activeSessionID = session.id },
                    onClose: { closeSession(session) }
                )
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
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
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
