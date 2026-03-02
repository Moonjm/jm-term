// Sources/JMTerm/Views/ConnectionFormView.swift
import SwiftUI

struct ConnectionFormView: View {
    @Binding var name: String
    @Binding var host: String
    @Binding var port: String
    @Binding var username: String
    @Binding var password: String
    @Binding var useKey: Bool
    @Binding var keyPath: String

    var body: some View {
        Form {
            TextField("이름", text: $name)
            TextField("호스트", text: $host)
            TextField("포트", text: $port)
            TextField("사용자", text: $username)

            Toggle("SSH 키 사용", isOn: $useKey)
            if useKey {
                TextField("키 경로", text: $keyPath)
            } else {
                SecureField("비밀번호", text: $password)
            }
        }
    }
}
