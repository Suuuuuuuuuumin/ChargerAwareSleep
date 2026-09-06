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
    @Published private(set) var errorText: String?

    /// 구독을 유지하기 위해 붙잡아 둔다. 놓으면 알림이 끊긴다.
    private var runLoopSource: CFRunLoopSource?

    init() {
        let raw = UserDefaults.standard.string(forKey: "mode") ?? Mode.auto.rawValue
        mode = Mode(rawValue: raw) ?? .auto
        subscribeToPowerChanges()
        apply()
    }

    /// polling 하지 않는다. 전원 상태가 바뀔 때만 깨어난다.
    private func subscribeToPowerChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.apply() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
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
            errorText = nil
            return
        }
        switch SleepControl.set(want) {
        case .success:
            errorText = nil
        case .failure(.commandFailed(_, let message)):
            errorText = message
        }
        refresh()
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Cmd-Q, launchctl, 로그아웃 등 어떤 경로로 끝나든 복원한다.
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

            if let errorText = controller.errorText {
                Divider()
                Text("오류: \(errorText)")
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
