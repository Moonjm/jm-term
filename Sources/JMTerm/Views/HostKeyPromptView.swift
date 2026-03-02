// Sources/JMTerm/Views/HostKeyPromptView.swift
import SwiftUI
import NIOSSH

enum HostKeyPromptType: Identifiable {
    case unknown(host: String, fingerprint: String)
    case mismatch(host: String, oldFingerprint: String, newFingerprint: String)

    var id: String {
        switch self {
        case .unknown(let host, _): return "unknown-\(host)"
        case .mismatch(let host, _, _): return "mismatch-\(host)"
        }
    }
}

/// Result of user's host key prompt decision.
enum HostKeyPromptResult {
    case reject
    case acceptOnce      // Connect without saving (mismatch only)
    case acceptAndSave   // Save to known_hosts (unknown) or update (mismatch)
}

struct HostKeyPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let promptType: HostKeyPromptType
    var onResult: (HostKeyPromptResult) -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch promptType {
            case .unknown(let host, let fingerprint):
                unknownHostView(host: host, fingerprint: fingerprint)
            case .mismatch(let host, let oldFP, let newFP):
                mismatchView(host: host, oldFingerprint: oldFP, newFingerprint: newFP)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    @ViewBuilder
    private func unknownHostView(host: String, fingerprint: String) -> some View {
        Image(systemName: "questionmark.shield")
            .font(.system(size: 36))
            .foregroundStyle(.yellow)

        Text("서버 \(host)에 처음 접속합니다")
            .font(.headline)

        Text("이 서버의 호스트 키를 확인할 수 없습니다.\n계속 연결하면 이 키가 신뢰 목록에 추가됩니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        fingerprintLabel(fingerprint)

        HStack {
            Button("취소") {
                onResult(.reject)
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("신뢰 및 저장") {
                onResult(.acceptAndSave)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func mismatchView(host: String, oldFingerprint: String, newFingerprint: String) -> some View {
        Image(systemName: "exclamationmark.shield.fill")
            .font(.system(size: 36))
            .foregroundStyle(.red)

        Text("경고: 호스트 키가 변경되었습니다")
            .font(.headline)
            .foregroundStyle(.red)

        Text("서버 \(host)의 호스트 키가 이전과 다릅니다.\n중간자 공격(MITM)일 수 있습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        VStack(alignment: .leading, spacing: 8) {
            Text("기존 fingerprint:")
                .font(.caption2).foregroundStyle(.secondary)
            fingerprintLabel(oldFingerprint)

            Text("새 fingerprint:")
                .font(.caption2).foregroundStyle(.secondary)
            fingerprintLabel(newFingerprint)
        }

        HStack(spacing: 12) {
            Button("연결 거부") {
                onResult(.reject)
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("새 키로 업데이트") {
                onResult(.acceptAndSave)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func fingerprintLabel(_ fp: String) -> some View {
        Text(fp)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .background(Color(white: 0.15))
            .cornerRadius(4)
            .textSelection(.enabled)
    }
}
