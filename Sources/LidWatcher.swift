import Foundation
import IOKit

/// 뚜껑 개폐를 구독해 전이(닫힘 ↔ 열림)를 주인에게 알린다.
/// 패널을 끌지 말지는 스스로 정하지 않는다 — 정책 판단은 Controller 몫이다.
///
/// polling 하지 않는다. IOPMrootDomain 에 kIOGeneralInterest 로 구독하면 뚜껑 개폐가
/// 이벤트로 온다. 이벤트가 1초 폴링보다 항상 먼저 도착했다. (spec 실측 9번, 2026-09-07)
final class LidWatcher {

    /// 뚜껑 상태가 바뀔 때만 호출된다. true = 닫힘.
    /// MainActor 에서 호출된다 — 콜백 안에서 직접 부르지 않고 Task 로 감싸 전달한다.
    /// 타입에 @MainActor 를 박아 호출부(Controller)의 격리와 컴파일러가 맞춰보게 한다.
    /// @Sendable 이 필요한 이유: 콜백은 MainActor 밖에서 돌고 이 값만 Task 로 넘긴다.
    /// LidWatcher 자체를 Task 에 캡처하면 격리 경계를 넘는 데이터 레이스가 된다.
    var onChange: (@Sendable @MainActor (Bool) -> Void)?

    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL

    /// 마지막으로 onChange 에 알린 값. 콜백 재진입 시 중복 발화를 막는 열쇠다.
    ///
    /// 증상: 한 번의 뚜껑 닫힘에 displaysleepnow 가 5번 발사됐다.
    /// 트리거: kIOGeneralInterest 는 뚜껑 개폐 한 번에도 여러 메시지를 보낸다. 그 중
    ///   하나를 처리하는 도중 Controller 가 SleepControl 을 거쳐 Process.waitUntilExit()
    ///   를 부르면 런루프가 돌아 이 콜백이 재진입한다. 이 값을 작업(Task 디스패치)보다
    ///   뒤에 갱신하면, 재진입한 호출도 매번 "아직 안 바뀜" 으로 보여 통과해버린다.
    /// 시도했으나 실패한 방법: messageType 으로 구분 — kIOGeneralInterest 의 messageType 은
    ///   뚜껑 개폐 전용이 아니라 판별 근거로 못 쓴다. AppleClamshellState 를 직접 다시
    ///   읽어야 한다(spec 실측 9번).
    /// 최종 결정: 콜백 진입 즉시(작업 디스패치 전에) 이 값을 갱신한다.
    private var lastClosed: Bool

    init() {
        lastClosed = SystemState.clamshellClosed() ?? false
    }

    deinit {
        if notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
        }
        if let notificationPort {
            // 이 포트로 얻은 CFRunLoopSource 도 함께 파괴된다 — 따로 제거할 필요 없다.
            IONotificationPortDestroy(notificationPort)
        }
    }

    /// 구독을 시작한다. 실패하면 false — 호출부가 사용자에게 알려야 한다
    /// (전원 구독 실패를 침묵시키지 않는 것과 같은 이유).
    func start() -> Bool {
        let matching = IOServiceMatching("IOPMrootDomain")
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard rootDomain != IO_OBJECT_NULL else { return false }
        // 알림은 등록 시 자체 참조를 잡으므로, 등록 후 이 핸들은 곧장 놓아도 된다.
        // (Apple IOKit 샘플 코드의 관행과 동일)
        defer { IOObjectRelease(rootDomain) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { context, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<LidWatcher>.fromOpaque(context).takeUnretainedValue()
            let closed = SystemState.clamshellClosed() ?? watcher.lastClosed
            guard closed != watcher.lastClosed else { return }
            watcher.lastClosed = closed
            // watcher 가 아니라 핸들러만 넘긴다 — watcher 를 캡처하면 Swift 6 에서 오류다.
            let handler = watcher.onChange
            Task { @MainActor in handler?(closed) }
        }

        let result = IOServiceAddInterestNotification(
            port, rootDomain, kIOGeneralInterest, callback, context, &notifier)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return false
        }

        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        notificationPort = port
        return true
    }
}
