import Foundation

/// 전원 공급원. "충전 중"이 아니라 "무엇으로부터 전력을 받는가"다.
/// 배터리 90% 에서 충전기를 꽂으면 "AC attached; not charging" 상태가 되는데,
/// charging 을 기준으로 판정하면 이 상태에서 오작동한다. (2026-09-06 실측)
enum PowerSource: String {
    case ac
    case battery
}

/// 사용자가 메뉴에서 고르는 동작 모드. UserDefaults 에 rawValue 로 저장한다.
enum Mode: String, CaseIterable {
    case auto
    case alwaysOn
    case alwaysOff

    var label: String {
        switch self {
        case .auto:      return "자동 전환"
        case .alwaysOn:  return "항상 켬"
        case .alwaysOff: return "항상 끔"
        }
    }
}

/// 모드와 전원 공급원으로부터 목표 disablesleep 값을 정한다.
/// 부작용이 없어야 한다. pmset 없이 검증 가능한 유일한 지점이다.
func desiredSleepDisabled(mode: Mode, source: PowerSource) -> Bool {
    switch mode {
    case .alwaysOn:  return true
    case .alwaysOff: return false
    case .auto:      return source == .ac
    }
}

/// 뚜껑을 닫았을 때 패널을 직접 꺼야 하는가.
///
/// disablesleep 은 시스템 잠자기만 막고 패널 소등과는 별개 경로다. 이 머신은
/// displaysleep 이 0(never)이라 뚜껑을 닫아도 패널이 영원히 켜져 있다. (spec 실측 02, 2026-09-07)
/// 잠자기가 살아 있으면 clamshell sleep 이 알아서 화면까지 끄므로 개입하지 않는다.
func shouldTurnOffDisplay(lidClosed: Bool, sleepDisabled: Bool) -> Bool {
    lidClosed && sleepDisabled
}

/// 항상 켬 모드를 배터리로 유지할지 물어봐야 하는가.
///
/// 트리거는 뚜껑을 **여는** 순간이다. 닫을 땐 물어봐야 화면을 볼 사람이 없다 —
/// 뚜껑을 다시 열어 자리에 도착한 시점이야말로 사용자가 화면 앞에 있다고 확신할
/// 수 있는 유일한 순간이다. 그때를 놓치면 다음 기회는 또 뚜껑을 열 때까지 없다.
///
/// 배터리일 때만 묻는다. 충전기가 꽂혀 있으면 방전·발열 위험이 없어 물어볼 이유가
/// 없다 — 항상 켬이 의도한 대로 동작하는 상황이다.
///
/// 모드를 자동으로 바꾸지 않는다. 사용자가 의도적으로 켠 항상 켬을 앱이 마음대로
/// 끄면, 뚜껑을 닫아도 안 자야 하는 상황(예: 발표 중 잠깐 덮었다 여는 경우)에서
/// 더 나쁜 오작동이 된다. 목표는 인지이지 자동 교정이 아니다.
func shouldAskKeepAlwaysOn(lidClosed: Bool, mode: Mode, source: PowerSource) -> Bool {
    !lidClosed && mode == .alwaysOn && source == .battery
}
