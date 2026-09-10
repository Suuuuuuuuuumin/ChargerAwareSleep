import Foundation
import CoreGraphics
import IOKit
import IOKit.ps

/// 권한 없이 읽을 수 있는 시스템 상태. 쓰기는 SleepControl 이 전담한다.
enum SystemState {

    /// IOPMrootDomain 의 불리언 속성을 읽는다.
    /// ioreg -n IOPMrootDomain -r -d1 로 같은 값을 눈으로 확인할 수 있다.
    private static func rootDomainBool(_ key: String) -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"))
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// 현재 disablesleep 값. 앱이 기억하는 값이 아니라 커널의 실제 값이다.
    static func sleepDisabled() -> Bool? {
        rootDomainBool("SleepDisabled")
    }

    /// 뚜껑이 닫혀 있는가. 표시 용도로만 쓴다.
    /// pmset -g assertions 의 lidopen assertion 은 뚜껑을 닫아도 남아 있어
    /// 개폐 판정에 쓸 수 없다. (2026-09-06 실측)
    static func clamshellClosed() -> Bool? {
        rootDomainBool("AppleClamshellState")
    }

    /// 화면이 잠겨 있는가.
    ///
    /// 뚜껑을 열면 대개 잠금 화면이 먼저 뜬다. 그 위에 말풍선을 띄워도 사용자는
    /// 못 본다 — 잠금 해제까지 기다려야 하는지 이 값으로 판단한다.
    ///
    /// CGSessionCopyCurrentDictionary 는 잠금 상태가 아닐 때 키 자체를 빼기도 해서
    /// nil 과 false 를 구분하지 않고 "없으면 안 잠김" 으로 읽는다.
    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// 전원 공급원. IOPSGetProvidingPowerSourceType 은 Get 계열이라
    /// takeUnretainedValue 가 맞다. takeRetainedValue 를 쓰면 over-release 된다.
    static func powerSource() -> PowerSource {
        let type = IOPSGetProvidingPowerSourceType(nil).takeUnretainedValue() as String
        return type == kIOPSACPowerValue ? .ac : .battery
    }
}
