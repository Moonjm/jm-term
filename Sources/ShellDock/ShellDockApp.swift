import SwiftUI

@main
struct ShellDockApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
    }
}

struct ContentView: View {
    var body: some View {
        Text("ShellDock")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
