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
