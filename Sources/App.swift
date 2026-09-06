import SwiftUI
import IOKit.ps

@MainActor
final class Controller: ObservableObject {

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            apply()
        }
    }

    @Published private(set) var source: PowerSource = .battery
    @Published private(set) var sleepDisabled: Bool = false

    /// apply() 가 매번 재평가하는 일시적 오류. 다음 apply() 성공 시 지워진다.
    @Published private(set) var applyErrorText: String?
    /// 구독 실패는 앱이 살아있는 동안 계속되는 상태다 — apply() 가 지워선 안 된다.
    /// (재시도 로직이 없으므로 프로세스 수명 동안 고정값이다.)
    @Published private(set) var subscriptionErrorText: String?

    /// 구독을 유지하기 위해 붙잡아 둔다. 놓으면 알림이 끊긴다.
    private var runLoopSource: CFRunLoopSource?

    init() {
        let raw = UserDefaults.standard.string(forKey: "mode") ?? Mode.auto.rawValue
        mode = Mode(rawValue: raw) ?? .auto
        if !subscribeToPowerChanges() {
            subscriptionErrorText = "전원 변경 감지를 시작하지 못했습니다. 자동 전환이 동작하지 않습니다."
        }
        apply()
    }

    /// polling 하지 않는다. 전원 상태가 바뀔 때만 깨어난다.
    /// 실패(등록 거부 등)를 호출부가 알 수 있도록 성공 여부를 반환한다 —
    /// 이 실패를 조용히 삼키면 사용자도 개발자도 모르게 자동 전환이 멈춘다.
    private func subscribeToPowerChanges() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.apply() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
        return true
    }

    /// 커널의 실제 값을 다시 읽는다. 앱이 기억하는 값을 믿지 않는다.
    func refresh() {
        source = SystemState.powerSource()
        sleepDisabled = SystemState.sleepDisabled() ?? false
    }

    func apply() {
        refresh()
        let want = desiredSleepDisabled(mode: mode, source: source)
        guard want != sleepDisabled else {
            applyErrorText = nil
            return
        }
        switch SleepControl.set(want) {
        case .success:
            applyErrorText = nil
        case .failure(.commandFailed(_, let message)):
            applyErrorText = message
        }
        refresh()
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Cmd-Q, 메뉴의 종료, launchctl stop, 로그아웃 등 "정상 종료" 경로에서만 복원한다.
        // 강제 종료·크래시까지 커버한다고 오해하지 말 것.
        //
        // 증상: 앱이 SIGKILL 되거나 크래시하면 SleepDisabled=1 이 잔류해, 뚜껑을 닫아도
        //       잠들지 않는다. 가방 안에서 방전·발열로 이어진다.
        // 트리거: 강제 종료, 크래시, 전원 차단.
        // 시도했으나 안 되는 것: applicationWillTerminate 는 SIGKILL 을 잡을 수 없다.
        //       OS 소관이다.
        // 최종 결정: 정상 종료 경로만 복원한다. 부팅 시 리셋용 LaunchDaemon 은
        //       disablesleep 의 재부팅 영속성을 측정한 뒤(Task 6) 필요할 때만 추가한다.
        //
        // SleepControl 은 MainActor 격리가 없는 순수 enum 이라 Controller 를 거치지 않는다.
        // (MainActor.assumeIsolated 는 macOS 14 이상이라 타겟 13.0 에서 쓸 수 없다)
        // 여기서는 실패해도 할 수 있는 일이 없다 — 프로세스가 죽는 중이다.
        // 반환값을 버리는 것이 의도임을 `_ =` 로 명시한다.
        _ = SleepControl.set(false)
    }
}

@main
struct ChargerAwareSleepApp: App {
    // 종료 알림을 받기 위해서만 필요하다. controller 를 넘기지 않는다.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = Controller()

    var body: some Scene {
        MenuBarExtra {
            Text(statusLine)

            if let subscriptionErrorText = controller.subscriptionErrorText {
                Divider()
                Text("오류: \(subscriptionErrorText)")
            }

            if let applyErrorText = controller.applyErrorText {
                Divider()
                Text("오류: \(applyErrorText)")
                Text("sudoers 규칙이 설치됐는지 확인하세요")
            }

            Divider()

            ForEach(Mode.allCases, id: \.self) { mode in
                Button {
                    controller.mode = mode
                } label: {
                    Text(controller.mode == mode ? "● \(mode.label)" : "○ \(mode.label)")
                }
            }

            Divider()

            Button("종료 (잠자기 복원됨)") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: controller.sleepDisabled ? "bolt.fill" : "bolt.slash")
        }
    }

    /// 앱이 믿는 값이 아니라 IORegistry 에서 읽은 실제 값을 보여준다.
    private var statusLine: String {
        let sleep = controller.sleepDisabled ? "잠자기 비활성" : "잠자기 활성"
        let power = controller.source == .ac ? "충전 중" : "배터리"
        let lid = SystemState.clamshellClosed() == true ? " · 뚜껑 닫힘" : ""
        return "\(sleep) · \(power)\(lid)"
    }
}
