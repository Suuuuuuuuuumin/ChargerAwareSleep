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

    /// 이미 떠 있으면 다시 띄우지 않는다.
    ///
    /// `popover != nil` 로 판정하면 안 된다. behavior 가 .transient 라 사용자가 딴 곳을
    /// 클릭하면 팝오버가 스스로 닫히는데, 그때 이 타입은 아무 통보도 받지 못해
    /// 프로퍼티가 non-nil 로 남는다. 그러면 isShowing 이 영영 true 로 굳어
    /// 말풍선이 두 번 다시 뜨지 않는다. 실제 표시 여부를 popover 에게 직접 묻는다.
    var isShowing: Bool { popover?.isShown == true }

    /// 뚜껑이 열리는 순간 디스플레이가 웨이크 중이라, 메뉴바의 NSStatusBarWindow 가
    /// 아직 준비 안 됐을 가능성이 있다 (미측정 — 실패하면 이 지연을 키운다).
    /// 그래서 한 틱(0.4초) 늦춰 앵커를 찾는다.
    ///
    /// 지연 중에 사용자가 메뉴에서 모드를 바꿨을 수 있으므로, 콜백 안에서
    /// shouldAskKeepAlwaysOn 조건을 넘겨받아 다시 확인한다. 호출부(Controller)가
    /// 최신 상태를 알므로 재확인 클로저는 호출부가 채운다 — 이 타입은 시점만 늦출 뿐
    /// "지금도 물어볼 상황인지"는 판단하지 않는다.
    func show(stillApplies: @escaping @MainActor () -> Bool, onAutoSwitch: @escaping @MainActor () -> Void) {
        guard !isShowing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, stillApplies() else { return }
            self.present(onAutoSwitch: onAutoSwitch)
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
        // 천장: 상태바 창 클래스명이 바뀌면(향후 macOS) 매칭이 깨져 영영 안 뜰 수 있다.
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
