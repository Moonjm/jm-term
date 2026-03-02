// Sources/ShellDock/Views/ListDoubleClick.swift
import SwiftUI
import AppKit

/// Adds native NSTableView double-click handling to SwiftUI List.
/// This avoids gesture conflicts with List(selection:).
struct ListDoubleClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let tableView = Self.findTableView(from: view) else { return }
            tableView.doubleAction = #selector(Coordinator.onDoubleClick)
            tableView.target = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    private static func findTableView(from view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let v = current {
            if let table = v as? NSTableView { return table }
            if let found = searchSubviews(of: v) { return found }
            current = v.superview
        }
        return nil
    }

    private static func searchSubviews(of view: NSView) -> NSTableView? {
        for subview in view.subviews {
            if let table = subview as? NSTableView { return table }
            if let found = searchSubviews(of: subview) { return found }
        }
        return nil
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func onDoubleClick() {
            action()
        }
    }
}

extension View {
    func onListDoubleClick(perform action: @escaping () -> Void) -> some View {
        background(ListDoubleClickHandler(action: action))
    }
}
