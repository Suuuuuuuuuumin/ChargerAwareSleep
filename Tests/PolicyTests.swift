// 정책 결정 로직의 self-check.
// 프레임워크를 쓰지 않는다. assert 는 -O 에서 제거되므로 test.sh 는 -Onone 으로 빌드한다.
@main
struct PolicyTests {
    static func main() {
        // 자동 모드는 전원 공급원을 따른다
        assert(desiredSleepDisabled(mode: .auto, source: .ac) == true,
               "자동 + AC 는 잠자기를 비활성화해야 한다")
        assert(desiredSleepDisabled(mode: .auto, source: .battery) == false,
               "자동 + 배터리는 macOS 기본 동작으로 돌아가야 한다")

        // 고정 모드는 전원 공급원을 무시한다
        assert(desiredSleepDisabled(mode: .alwaysOn, source: .battery) == true)
        assert(desiredSleepDisabled(mode: .alwaysOn, source: .ac) == true)
        assert(desiredSleepDisabled(mode: .alwaysOff, source: .ac) == false)
        assert(desiredSleepDisabled(mode: .alwaysOff, source: .battery) == false)

        // 뚜껑 닫힘 + 잠자기 비활성일 때만 패널을 직접 끈다
        assert(shouldTurnOffDisplay(lidClosed: true, sleepDisabled: true) == true,
               "잠자기가 막혀 있으면 패널이 스스로 꺼지지 않는다 — 직접 꺼야 한다")
        assert(shouldTurnOffDisplay(lidClosed: true, sleepDisabled: false) == false,
               "잠자기가 살아 있으면 clamshell sleep 이 화면까지 끈다 — 개입하지 않는다")
        assert(shouldTurnOffDisplay(lidClosed: false, sleepDisabled: true) == false,
               "뚜껑이 열려 있는데 화면을 끄면 사용자가 쓰는 중인 화면을 끄는 것이다")
        assert(shouldTurnOffDisplay(lidClosed: false, sleepDisabled: false) == false)

        // UserDefaults 왕복. rawValue 로 저장하므로 복원이 깨지면 모드가 조용히 초기화된다
        for m in Mode.allCases {
            assert(Mode(rawValue: m.rawValue) == m, "\(m) 왕복 실패")
        }
        assert(Mode(rawValue: "존재하지-않는-모드") == nil)

        // 모든 모드에 사람이 읽을 라벨이 있어야 한다
        for m in Mode.allCases {
            assert(!m.label.isEmpty, "\(m) 라벨 없음")
        }

        print("PolicyTests: 통과")
    }
}
