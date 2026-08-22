// Sources/JMTerm/Services/AppTerminationCleanup.swift
import AppKit

/// 종료 직전에 pasteboard에 남은 lazy promise를 버린다.
///
/// SFTP 사이드바에서 파일을 Finder로 드래그하면 `SFTPViewModel.dragProvider`가
/// 등록한 lazy promise가 드래그 pasteboard에 남는다. 세션을 ⌘W로 닫아도 이
/// 등록은 지워지지 않는다. 그대로 ⌘Q를 누르면 AppKit이
/// NSApplicationWillTerminateNotification 처리 도중
/// `CFPasteboardResolveAllPromisedData`로 promise를 확정하려 하면서 메인 스레드를
/// 중첩 런루프에 가두고, 응답할 주체가 없어 앱이 영원히 멈춘다(강제종료 필요).
///
/// 드래그 pasteboard의 내용은 드래그가 진행 중일 때만 의미가 있으므로,
/// 종료 시점에 비워도 잃는 것이 없다. 일반 pasteboard(복사한 텍스트)는
/// 종료 후에도 남아야 하고 즉시 쓰기라 promise가 없으므로 건드리지 않는다.
enum AppTerminationCleanup {
    static func discardPendingPasteboardPromises(
        on pasteboard: NSPasteboard = NSPasteboard(name: .drag)
    ) {
        pasteboard.clearContents()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // willTerminate 알림보다 먼저 호출되므로 promise 확정이 시작되기 전에 정리된다.
        AppTerminationCleanup.discardPendingPasteboardPromises()
        return .terminateNow
    }
}
