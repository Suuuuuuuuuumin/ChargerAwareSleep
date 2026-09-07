import SwiftUI
import IOKit.ps
import ServiceManagement

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
    /// 패널 소등(pmset displaysleepnow) 실패. sudo 를 타지 않으므로 sudoers 힌트를 붙이면
    /// 안 된다 — applyErrorText 와 도메인이 다르다. (Task 5 판정과 같은 이유)
    @Published private(set) var displayErrorText: String?
    /// 로그인 항목 등록·해제 실패. 사용자 조작에 대한 피드백이라 다음 조작(재시도) 때까지
    /// 유지되고, apply() 의 전원 이벤트에 지워지지 않는다 — applyErrorText 와 도메인이 다르다.
    @Published private(set) var loginItemErrorText: String?

    /// 구독을 유지하기 위해 붙잡아 둔다. 놓으면 알림이 끊긴다.
    private var runLoopSource: CFRunLoopSource?

    /// 뚜껑 개폐 구독. 소유권을 놓으면 알림이 끊긴다.
    private let lidWatcher = LidWatcher()

    init() {
        let raw = UserDefaults.standard.string(forKey: "mode") ?? Mode.auto.rawValue
        mode = Mode(rawValue: raw) ?? .auto
        if !subscribeToPowerChanges() {
            noteSubscriptionFailure("전원 변경 감지를 시작하지 못했습니다. 자동 전환이 동작하지 않습니다.")
        }
        lidWatcher.onChange = { [weak self] closed in self?.handleLidChange(closed) }
        if !lidWatcher.start() {
            noteSubscriptionFailure("뚜껑 감지를 시작하지 못했습니다. 뚜껑을 닫아도 화면이 꺼지지 않습니다.")
        }
        apply()
    }

    /// 구독은 재시도하지 않으므로 실패가 겹치면 둘 다 보여야 한다. 덮어쓰지 않고 쌓는다.
    private func noteSubscriptionFailure(_ text: String) {
        subscriptionErrorText = [subscriptionErrorText, text].compactMap { $0 }.joined(separator: "\n")
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

    /// 뚜껑이 열리거나 닫힐 때만 호출된다 — polling 이 아니다.
    /// 여는 쪽은 할 일이 없다. macOS 가 알아서 화면을 켠다.
    private func handleLidChange(_ closed: Bool) {
        // 앱이 기억하는 값이 아니라 커널의 실제 값으로 판단한다.
        refresh()
        guard shouldTurnOffDisplay(lidClosed: closed, sleepDisabled: sleepDisabled) else { return }
        switch SleepControl.displaySleepNow() {
        case .success:
            displayErrorText = nil
        case .failure(.commandFailed(_, let message)):
            displayErrorText = message
        }
    }

    /// SMAppService 는 macOS 13 이상에서 쓸 수 있다.
    /// 별도 LaunchAgent plist 를 두지 않는다 — 기동 경로가 둘이면 이중 실행이 된다.
    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                // 재시도로 성공했으면 이전 실패 메시지를 남겨두지 않는다.
                loginItemErrorText = nil
            } catch {
                // SleepControl(pmset) 실패 전용인 applyErrorText 에 담으면 안 된다 —
                // sudoers 힌트가 무관하게 같이 뜨고, 전원 이벤트로 apply() 가 도는 사이
                // 사용자가 보기도 전에 지워질 수 있다. 전용 필드에 담는다.
                loginItemErrorText = "로그인 항목 변경 실패: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Cmd-Q, 메뉴의 종료, 로그아웃 등 "정상 종료" 경로에서만 복원한다.
        // 강제 종료·크래시까지 커버한다고 오해하지 말 것.
        //
        // 증상: 앱이 SIGKILL 되거나 크래시하면 SleepDisabled=1 이 잔류해, 뚜껑을 닫아도
        //       잠들지 않는다. 가방 안에서 방전·발열로 이어진다.
        // 트리거: 강제 종료, 크래시, 전원 차단, `launchctl stop` (SIGTERM 을 보낼 뿐이고
        //       AppKit 이 SIGTERM 을 applicationWillTerminate 로 자동 연결해주지 않는다.
        //       이 앱엔 SIGTERM 핸들러도 없다 — 복원되지 않는 경로다).
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

            if let displayErrorText = controller.displayErrorText {
                Divider()
                Text("오류: 화면 끄기 실패 — \(displayErrorText)")
            }

            if let loginItemErrorText = controller.loginItemErrorText {
                Divider()
                Text("오류: \(loginItemErrorText)")
                Text("시스템 설정 > 일반 > 로그인 항목 에서 확인하세요")
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

            Button(controller.launchesAtLogin ? "☑ 로그인 시 시작" : "☐ 로그인 시 시작") {
                controller.launchesAtLogin.toggle()
            }

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
