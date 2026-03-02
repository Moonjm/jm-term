import SwiftUI

struct PasswordPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ServerConnection?
    var onConnect: (String) -> Void
    var onCancel: () -> Void

    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            if let conn = connection {
                Text("\(conn.username)@\(conn.host)")
                    .font(.headline)
            }

            SecureField("비밀번호", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { connect() }

            HStack {
                Button("취소") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("연결") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private func connect() {
        onConnect(password)
        dismiss()
    }
}
