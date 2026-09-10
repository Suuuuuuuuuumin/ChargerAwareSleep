import SwiftUI
import AppKit

/// "항상 켬 모드입니다" 확인 말풍선. 뚜껑을 열었는데 배터리로 항상 켬이면
/// 방전·발열 위험을 알리고, 자동 전환으로 바꿀지 물어본다.
///
/// 모드를 스스로 바꾸지 않는다 — "자동 전환" 버튼을 누르면 콜백으로만 알리고,
/// 실제 모드 변경은 Controller 가 한다. 이 타입이 Controller 를 알면 역방향
/// 의존(Controller → AlwaysOnPrompt → Controller)이 생겨 순환한다.
@MainActor
final class AlwaysOnPrompt {

    /// NSPopover 를 지역변수로 두면 참조가 사라져 화면에서 즉시 닫힌다.
    /// 프로퍼티로 붙잡아야 살아있는 동안 유지된다.
    private var popover: NSPopover?
    /// 5초 자동 닫힘 타이머. 사용자가 버튼을 누르면 취소해야
    /// 이미 닫힌 뒤에 또 한 번 닫으려 들지 않는다.
    private var dismissWork: DispatchWorkItem?
    /// 표시 대기 타이머. 뚜껑을 다시 여닫으면 걷어낸다.
    private var pendingWork: DispatchWorkItem?
    /// 잠금 해제 관측자. 걷어내지 않으면 여닫을 때마다 쌓인다.
    private var unlockObserver: NSObjectProtocol?

    /// 이미 떠 있으면 다시 띄우지 않는다.
    ///
    /// `popover != nil` 로 판정하면 안 된다. behavior 가 .transient 라 사용자가 딴 곳을
    /// 클릭하면 팝오버가 스스로 닫히는데, 그때 이 타입은 아무 통보도 받지 못해
    /// 프로퍼티가 non-nil 로 남는다. 그러면 isShowing 이 영영 true 로 굳어
    /// 말풍선이 두 번 다시 뜨지 않는다. 실제 표시 여부를 popover 에게 직접 묻는다.
    var isShowing: Bool { popover?.isShown == true }

    /// 잠금 해제를 기다렸다가 띄운다. 이미 풀려 있으면 곧바로(웨이크 대기만) 띄운다.
    ///
    /// 뚜껑을 열면 대개 잠금 화면이 먼저 뜬다. 거기에 말풍선을 띄우면 사용자는 못
    /// 보고 5초 뒤 조용히 닫힌다 — 알리려던 목적이 통째로 날아간다. 그래서 기준을
    /// "뚜껑 열림 + 1초" 가 아니라 "뚜껑 열림 + 잠금 해제" 로 잡는다 (2026-09-10).
    ///
    /// 해제를 안 하고 자리를 뜨면 관측자가 떠 있게 되는데, 나중에 돌아와 풀 때
    /// 조건이 그대로면 그때 알리는 게 맞으므로 시한을 두지 않는다. 조건이 바뀌었으면
    /// stillApplies 가 걸러낸다.
    ///
    /// 사용자 클릭 없이 타이머로 띄워도 아이콘 아래에 제대로 뜬다 (2026-09-10 실측:
    /// 메뉴에서 5초 지연 스위치로 확인). 한때 화면 왼쪽 끝(x=0)으로 밀린 적이 있으나
    /// 그건 갓 띄운 프로브 앱에서만 재현됐다 — spec 의 "메뉴바 팝오버 위치" 참고.
    ///
    /// 1초는 실측이 아니다. 웨이크·해제 직후의 타이밍은 재보지 않았고, 너무 이르면
    /// 말풍선이 아예 안 뜨는 쪽으로 실패한다. 안 뜨면 이 값부터 키운다.
    ///
    /// 지연 중에 사용자가 메뉴에서 모드를 바꿨을 수 있으므로, 띄우기 직전에
    /// shouldAskKeepAlwaysOn 조건을 넘겨받아 다시 확인한다. 호출부(Controller)가
    /// 최신 상태를 알므로 재확인 클로저는 호출부가 채운다 — 이 타입은 시점만 정할 뿐
    /// "지금도 물어볼 상황인지"는 판단하지 않는다.
    func show(stillApplies: @escaping @Sendable @MainActor () -> Bool,
              onAutoSwitch: @escaping @Sendable @MainActor () -> Void) {
        guard !isShowing else { return }
        cancelPending()

        guard SystemState.screenLocked() else {
            schedule(stillApplies: stillApplies, onAutoSwitch: onAutoSwitch)
            return
        }

        // 관측자 클로저는 MainActor 밖에서 돈다. self 를 캡처하면 격리 경계를 넘으므로
        // MainActor 클로저 하나만 만들어 그것만 넘긴다 (LidWatcher 와 같은 이유).
        let resume: @Sendable @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.cancelPending()
            self.schedule(stillApplies: stillApplies, onAutoSwitch: onAutoSwitch)
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { _ in Task { @MainActor in resume() } }
    }

    private func schedule(stillApplies: @escaping @MainActor () -> Bool,
                          onAutoSwitch: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, stillApplies() else { return }
            self.present(onAutoSwitch: onAutoSwitch)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// 뚜껑을 여닫으면 show 가 다시 불린다. 앞선 대기를 걷어내지 않으면
    /// 관측자와 타이머가 쌓여 말풍선이 여러 번 뜨려 든다.
    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
        if let unlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockObserver)
            self.unlockObserver = nil
        }
    }

    private func present(onAutoSwitch: @escaping @MainActor () -> Void) {
        // 앞선 팝오버가 .transient 로 스스로 닫혔다면 그 5초 타이머가 아직 살아 있다.
        // 그대로 두면 지금 띄우는 팝오버를 5초가 되기도 전에 닫아버린다.
        dismissWork?.cancel()
        dismissWork = nil

        // ponytail: 앵커(NSStatusBarWindow)를 못 찾으면 조용히 포기한다. 실패해도
        // 앱의 핵심 동작(잠자기 제어)에는 영향이 없고, 오류 필드를 하나 더 늘려
        // 메뉴를 어지럽히는 것보다 낫다. 증상: 뚜껑을 열어도 말풍선이 안 뜬다.
        // 천장: 상태바 창 클래스명이 바뀌면(향후 macOS) 매칭이 깨져 영영 안 뜬다.
        //
        // window.frame 은 믿지 말 것. 2026-09-10 실측으로 항상 화면 밖(x≈-3700,
        // 화면은 x 0..2056)을 보고한다 — activate 해도, open 으로 띄워도, 메뉴를
        // 열었다 닫아도 같다. 그런데도 팝오버는 아이콘 아래에 정확히 뜬다.
        // AppKit 이 진짜 위치를 따로 안다. 좌표를 직접 계산하려 들지 말 것.
        guard let statusBarWindow = NSApp.windows.first(where: {
            String(describing: type(of: $0)).contains("StatusBar")
        }), let anchorView = statusBarWindow.contentView else { return }

        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: AlwaysOnPromptView(
            onKeep: { [weak self] in self?.dismiss() },
            onAutoSwitch: { [weak self] in
                onAutoSwitch()
                self?.dismiss()
            }
        ))
        p.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        popover = p

        // 5초는 실측이 아니라 사용자가 고른 값이다.
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func dismiss() {
        cancelPending()
        dismissWork?.cancel()
        dismissWork = nil
        popover?.performClose(nil)
        popover = nil
    }
}

private struct AlwaysOnPromptView: View {
    let onKeep: () -> Void
    let onAutoSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("항상 켬 모드입니다")
                .font(.headline)
            Text("배터리 상태라 뚜껑을 닫아도 잠자기가 막혀 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("유지하기", action: onKeep)
                Button("자동 전환", action: onAutoSwitch)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
