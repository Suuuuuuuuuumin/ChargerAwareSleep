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
