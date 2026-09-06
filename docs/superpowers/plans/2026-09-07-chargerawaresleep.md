# ChargerAwareSleep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 전원 공급원이 AC면 `pmset -a disablesleep 1`, 배터리면 `0`으로 자동 전환하는 macOS 메뉴바 앱을 만든다.

**Architecture:** 단일 실행 파일. 정책 결정은 부작용 없는 순수 함수(`Policy.swift`)로 분리해 `pmset` 없이 테스트한다. 상태 읽기는 IORegistry(권한 불필요), 쓰기만 `sudo pmset`(sudoers 규칙 의존)으로 경로를 나눈다. 전원 변경은 `IOPSNotificationCreateRunLoopSource`로 구독하며 polling하지 않는다.

**Tech Stack:** Swift 6.4, SwiftUI `MenuBarExtra`, IOKit / IOKit.ps, `swiftc` 직접 빌드 + 수제 `.app` 번들 (Xcode 없음)

**Spec:** `docs/superpowers/specs/2026-09-06-chargerawaresleep-design.md`

## Global Constraints

- 타겟: `arm64-apple-macos13.0`. `MenuBarExtra`와 `SMAppService`가 macOS 13 이상을 요구한다.
- Xcode가 없다. `xcodebuild`를 쓰지 않는다. 빌드는 `swiftc` + 수제 번들, 서명은 ad-hoc(`codesign -s -`).
- `Sources/`의 파일은 4개를 넘기지 않는다: `Policy.swift`, `SystemState.swift`, `SleepControl.swift`, `App.swift`.
- 테스트는 프레임워크 없이 `assert` 기반이다. `assert`는 `-O`에서 제거되므로 테스트 빌드는 반드시 `-Onone`으로 한다.
- 앱 실행 파일 빌드는 `-O -parse-as-library`를 쓴다. `-parse-as-library` 없이는 `@main`이 "top-level code" 오류로 실패한다.
- 전원 판정은 charging 여부가 아니라 공급원으로 한다. 기준값은 `kIOPSACPowerValue`("AC Power")다. (spec 실측 04)
- 앱은 `/etc/sudoers.d`에 쓰지 않는다. sudoers 규칙 설치는 사용자가 직접 한다.
- 종료 시에는 모드와 무관하게 `disablesleep 0`으로 복원한다. (spec 상태 모델)
- 번들 식별자: `dev.local.ChargerAwareSleep`. UserDefaults 키: `mode`.
- 한글 주석을 쓴다. 실측·실험으로 정한 값에는 근거와 날짜를 주석으로 남긴다.

## 검증된 사실 (구현 중 재조사 금지)

2026-09-07에 이 머신에서 실제로 컴파일·실행해 확인했다.

- `swiftc -O -parse-as-library -target arm64-apple-macos13.0` + 수제 번들 + `codesign -s -`로 만든 `MenuBarExtra` 앱이 메뉴 막대에 정상 표시된다.
- `IORegistryEntryCreateCFProperty(...)?.takeRetainedValue() as? Bool`로 `SleepDisabled`와 `AppleClamshellState`를 읽으면 `ioreg` 출력과 일치한다.
- `IOPSGetProvidingPowerSourceType(nil).takeUnretainedValue() as String`은 `"AC Power"`를 반환하며, 200회 반복 호출에도 over-release로 죽지 않는다. `takeRetainedValue`가 아니라 `takeUnretainedValue`가 맞다.
- `kIOPSACPowerValue`는 옵셔널이 아닌 `String`이다. 강제 언래핑하면 컴파일 오류가 난다.

## Spec에서 벗어난 결정

- spec의 Failsafe 1(`LaunchAgent` `KeepAlive=true`)을 v1에 넣지 않는다. "로그인 시 시작"을 `SMAppService.mainApp`으로 구현하는데, 여기에 별도 KeepAlive LaunchAgent를 더하면 두 기동 경로가 겹쳐 이중 실행이 된다. Task 6에서 재부팅 영속성을 측정한 뒤, 그 결과를 근거로 failsafe 형태를 정해 README에 남긴다.

## File Structure

| 파일 | 책임 |
|---|---|
| `Sources/Policy.swift` | `PowerSource`, `Mode`, `desiredSleepDisabled`. 부작용 없음 |
| `Sources/SystemState.swift` | IORegistry·IOPS 읽기. 권한 불필요, 쓰기 없음 |
| `Sources/SleepControl.swift` | `sudo pmset`로 `disablesleep` 쓰기. 유일한 쓰기 경로 |
| `Sources/App.swift` | `MenuBarExtra` UI, `Controller`, 전원 변경 구독, 종료 복원 |
| `Tests/PolicyTests.swift` | `assert` 기반 self-check. `Policy.swift`만 의존 |
| `Resources/Info.plist` | 번들 메타데이터, `LSUIElement` |
| `build.sh` / `test.sh` | 빌드·테스트 진입점 |
| `install/chargerawaresleep.sudoers` | 사용자가 설치할 sudoers 규칙 |
| `README.md` | 설치 절차, 검증 결과 |

---

### Task 1: 빌드 스켈레톤과 정책 순수 함수

`pmset`이나 IOKit 없이 돌아가는 뼈대를 먼저 세운다. 정책 로직과 그 테스트가 이 태스크의 산출물이다.

**Files:**
- Create: `.gitignore`
- Create: `Sources/Policy.swift`
- Create: `Tests/PolicyTests.swift`
- Create: `test.sh`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum PowerSource: String { case ac, battery }`
  - `enum Mode: String, CaseIterable { case auto, alwaysOn, alwaysOff }`, `var label: String`
  - `func desiredSleepDisabled(mode: Mode, source: PowerSource) -> Bool`

- [ ] **Step 1: `.gitignore` 작성**

```gitignore
build/
.DS_Store
```

- [ ] **Step 2: 실패하는 테스트 작성**

`Tests/PolicyTests.swift`:

```swift
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
```

- [ ] **Step 3: `test.sh` 작성**

```bash
#!/bin/bash
# 정책 로직 self-check. assert 를 살려야 하므로 -Onone 으로 빌드한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
swiftc -Onone -parse-as-library -target arm64-apple-macos13.0 \
  -o "$ROOT/build/policytests" \
  "$ROOT/Sources/Policy.swift" "$ROOT/Tests/PolicyTests.swift"
"$ROOT/build/policytests"
```

`chmod +x test.sh`

- [ ] **Step 4: 테스트가 실패하는지 확인**

Run: `./test.sh`
Expected: 컴파일 실패. `cannot find 'desiredSleepDisabled' in scope`

- [ ] **Step 5: `Sources/Policy.swift` 구현**

```swift
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
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `./test.sh`
Expected: `PolicyTests: 통과`

- [ ] **Step 7: 커밋**

```bash
git add .gitignore Sources/Policy.swift Tests/PolicyTests.swift test.sh
git commit -m "feat: 정책 결정 순수 함수와 self-check

전원 공급원 + 모드 -> 목표 disablesleep 값. 부작용이 없어
pmset 없이 검증된다. assert 를 살리려 테스트는 -Onone 으로 빌드한다."
```

---

### Task 2: 시스템 상태 읽기

권한 없이 읽을 수 있는 값들. 여기서 쓰기는 하지 않는다.

**Files:**
- Create: `Sources/SystemState.swift`

**Interfaces:**
- Consumes: `PowerSource` (Task 1)
- Produces:
  - `enum SystemState`
  - `static func sleepDisabled() -> Bool?`
  - `static func clamshellClosed() -> Bool?`
  - `static func powerSource() -> PowerSource`

- [ ] **Step 1: `Sources/SystemState.swift` 구현**

```swift
import Foundation
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

    /// 전원 공급원. IOPSGetProvidingPowerSourceType 은 Get 계열이라
    /// takeUnretainedValue 가 맞다. takeRetainedValue 를 쓰면 over-release 된다.
    static func powerSource() -> PowerSource {
        let type = IOPSGetProvidingPowerSourceType(nil).takeUnretainedValue() as String
        return type == kIOPSACPowerValue ? .ac : .battery
    }
}
```

- [ ] **Step 2: 실제 값과 대조하는 임시 확인**

`SystemState`는 시스템 상태를 읽으므로 단위 테스트로 고정할 수 없다. 대신 실제 값과 한 번 대조한다.

```bash
cat > /tmp/cas_check.swift <<'EOF'
@main struct Check {
    static func main() {
        print("sleepDisabled  =", SystemState.sleepDisabled().map(String.init) ?? "nil")
        print("clamshellClosed=", SystemState.clamshellClosed().map(String.init) ?? "nil")
        print("powerSource    =", SystemState.powerSource().rawValue)
    }
}
EOF
swiftc -Onone -parse-as-library -target arm64-apple-macos13.0 \
  -o /tmp/cas_check Sources/Policy.swift Sources/SystemState.swift /tmp/cas_check.swift
/tmp/cas_check
echo "--- 대조 ---"
ioreg -n IOPMrootDomain -r -d1 | grep -oE '"(SleepDisabled|AppleClamshellState)" = [A-Za-z]*'
pmset -g batt | head -1
```

Expected: `sleepDisabled`가 ioreg의 `SleepDisabled`(`No`→`false`, `Yes`→`true`)와 일치하고, `powerSource`가 `pmset -g batt`의 `Now drawing from` 값과 일치한다.

- [ ] **Step 3: 임시 파일 정리**

```bash
rm -f /tmp/cas_check.swift /tmp/cas_check
```

- [ ] **Step 4: 커밋**

```bash
git add Sources/SystemState.swift
git commit -m "feat: IORegistry/IOPS 기반 시스템 상태 읽기

SleepDisabled 와 AppleClamshellState 는 IOPMrootDomain 에서,
전원 공급원은 IOPSGetProvidingPowerSourceType 에서 읽는다.
모두 권한이 필요 없다. ioreg/pmset 출력과 대조해 확인했다."
```

---

### Task 3: disablesleep 쓰기와 sudoers 규칙

유일한 권한 필요 경로. 실패를 삼키지 않는 것이 핵심이다.

**Files:**
- Create: `Sources/SleepControl.swift`
- Create: `install/chargerawaresleep.sudoers`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum SleepControlError: Error { case commandFailed(status: Int32, message: String) }`
  - `enum SleepControl`
  - `static func set(_ disabled: Bool) -> Result<Void, SleepControlError>`

- [ ] **Step 1: sudoers 규칙 파일 작성**

`install/chargerawaresleep.sudoers`:

```
# ChargerAwareSleep — pmset 의 disablesleep 설정만 암호 없이 허용한다.
# 설치:
#   sudo install -m 0440 -o root -g wheel \
#     install/chargerawaresleep.sudoers /etc/sudoers.d/chargerawaresleep
#   sudo visudo -c -f /etc/sudoers.d/chargerawaresleep
#
# 보안 영향: admin 그룹의 임의 프로세스가 암호 없이 이 명령을 실행할 수 있다.
# 영향 범위는 잠자기 정책 변경으로 한정된다.
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *
```

- [ ] **Step 2: `Sources/SleepControl.swift` 구현**

```swift
import Foundation

enum SleepControlError: Error, Equatable {
    /// sudo 또는 pmset 이 0 이 아닌 종료 코드를 냈다.
    case commandFailed(status: Int32, message: String)
}

/// disablesleep 을 바꾸는 유일한 경로. root 가 필요하다.
/// 앱은 sudoers 를 수정하지 않는다 — 그 능력 자체가 규칙 한 줄보다 큰 구멍이다.
enum SleepControl {

    /// pmset 의 disablesleep 은 man 페이지에 없는 미문서화 설정이다.
    /// macOS major 업그레이드 때마다 회귀 확인이 필요하다. (spec 실측 05)
    @discardableResult
    static func set(_ disabled: Bool) -> Result<Void, SleepControlError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: 암호를 묻지 않는다. 규칙이 없으면 프롬프트로 멈추지 않고 즉시 실패한다.
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(.commandFailed(status: -1, message: "\(error)"))
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let raw = String(data: errorData, encoding: .utf8) ?? ""
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.commandFailed(
                status: process.terminationStatus,
                message: message.isEmpty ? "sudo 가 코드 \(process.terminationStatus) 로 실패했습니다" : message))
        }
        return .success(())
    }
}
```

- [ ] **Step 3: sudoers 규칙 설치**

```bash
sudo install -m 0440 -o root -g wheel install/chargerawaresleep.sudoers /etc/sudoers.d/chargerawaresleep
sudo visudo -c -f /etc/sudoers.d/chargerawaresleep
```

Expected: `/etc/sudoers.d/chargerawaresleep: parsed OK`

- [ ] **Step 4: 규칙이 실제로 먹는지 확인**

```bash
sudo -n /usr/bin/pmset -a disablesleep 1 && echo "쓰기 성공"
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
sudo -n /usr/bin/pmset -a disablesleep 0
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
```

Expected: 암호를 묻지 않고 `Yes` → `No` 로 바뀐다.

- [ ] **Step 5: Swift 경로로도 왕복 확인**

```bash
cat > /tmp/cas_write.swift <<'EOF'
import Foundation   // exit(_:) 에 필요하다

@main struct W {
    static func main() {
        for want in [true, false] {
            switch SleepControl.set(want) {
            case .success:
                let now = SystemState.sleepDisabled().map(String.init) ?? "nil"
                print("set(\(want)) -> SleepDisabled=\(now)")
                assert(SystemState.sleepDisabled() == want, "쓴 값과 읽은 값이 다르다")
            case .failure(let e):
                print("실패:", e); exit(1)
            }
        }
        print("SleepControl: 왕복 통과")
    }
}
EOF
swiftc -Onone -parse-as-library -target arm64-apple-macos13.0 \
  -o /tmp/cas_write Sources/Policy.swift Sources/SystemState.swift Sources/SleepControl.swift /tmp/cas_write.swift
/tmp/cas_write
rm -f /tmp/cas_write.swift /tmp/cas_write
```

Expected: `set(true) -> SleepDisabled=true`, `set(false) -> SleepDisabled=false`, `SleepControl: 왕복 통과`

- [ ] **Step 6: 종료 상태가 0인지 확인**

```bash
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
```

Expected: `"SleepDisabled" = No`. `Yes`면 `sudo -n /usr/bin/pmset -a disablesleep 0`으로 되돌린다.

- [ ] **Step 7: 커밋**

```bash
git add Sources/SleepControl.swift install/chargerawaresleep.sudoers
git commit -m "feat: sudo pmset 을 통한 disablesleep 쓰기

sudo -n 이라 규칙이 없으면 프롬프트로 멈추지 않고 즉시 실패한다.
실패는 삼키지 않고 Result 로 올려보내 메뉴에 표시한다.
앱은 sudoers 를 건드리지 않는다 — 설치는 사용자 몫이다."
```

---

### Task 4: 메뉴바 앱과 배선

UI, 전원 변경 구독, 종료 복원. 여기서 앱이 처음으로 실행 가능해진다.

**Files:**
- Create: `Sources/App.swift`
- Create: `Resources/Info.plist`
- Create: `build.sh`

**Interfaces:**
- Consumes: `Mode`, `PowerSource`, `desiredSleepDisabled` (Task 1), `SystemState` (Task 2), `SleepControl` (Task 3)
- Produces: `ChargerAwareSleepApp`, `Controller`, `AppDelegate`

- [ ] **Step 1: `Resources/Info.plist` 작성**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.local.ChargerAwareSleep</string>
  <key>CFBundleName</key><string>ChargerAwareSleep</string>
  <key>CFBundleExecutable</key><string>ChargerAwareSleep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: `build.sh` 작성**

```bash
#!/bin/bash
# Xcode 가 없으므로 swiftc 로 직접 빌드하고 .app 번들을 손으로 만든다.
# -parse-as-library 가 없으면 @main 이 "top-level code" 오류로 실패한다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/ChargerAwareSleep.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/ChargerAwareSleep" \
  "$ROOT/Sources"/*.swift

# ad-hoc 서명. 로컬 실행에는 Developer ID 가 필요 없다.
codesign -s - --force "$APP"

echo "빌드 완료: $APP"
```

`chmod +x build.sh`

- [ ] **Step 3: `Sources/App.swift` 구현**

```swift
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
        SleepControl.set(false)
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
```

- [ ] **Step 4: 빌드**

Run: `./build.sh`
Expected: `빌드 완료: .../build/ChargerAwareSleep.app`, 경고나 오류 없음

- [ ] **Step 5: 실행하고 메뉴 확인**

```bash
open build/ChargerAwareSleep.app
sleep 2
pgrep -l ChargerAwareSleep
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
```

Expected: 프로세스가 뜨고, 메뉴 막대에 번개 아이콘이 보인다. 충전기가 연결돼 있으면 `SleepDisabled = Yes`가 된다. 메뉴를 열면 상태 줄과 모드 3개가 보인다.

- [ ] **Step 6: 모드 전환과 종료 복원 확인**

메뉴에서 "항상 끔"을 고르고 `ioreg`를 다시 읽어 `No`가 되는지 본다. "자동 전환"으로 되돌린 뒤, 메뉴의 종료를 누르고 다시 읽는다.

```bash
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
pgrep -l ChargerAwareSleep || echo "종료됨"
```

Expected: 종료 후 `"SleepDisabled" = No`. 프로세스 없음.

- [ ] **Step 7: 커밋**

```bash
git add Sources/App.swift Resources/Info.plist build.sh
git commit -m "feat: 메뉴바 앱과 전원 변경 구독

IOPSNotificationCreateRunLoopSource 로 전원 변경만 구독한다 — polling 하지 않는다.
상태 줄은 앱이 기억하는 값이 아니라 IORegistry 의 실제 값을 보여준다.
종료 경로는 applicationWillTerminate 로 모아 어떤 방식으로 끝나든 복원한다."
```

---

### Task 5: 로그인 시 시작

**Files:**
- Modify: `Sources/App.swift`

**Interfaces:**
- Consumes: `Controller` (Task 4)
- Produces: `Controller.launchesAtLogin: Bool`

- [ ] **Step 1: `Controller`에 로그인 항목 상태 추가**

`Sources/App.swift` 상단 import에 `ServiceManagement`를 추가한다:

```swift
import SwiftUI
import IOKit.ps
import ServiceManagement
```

`Controller` 안, `apply()` 바로 뒤에 다음을 넣는다:

```swift
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
            } catch {
                errorText = "로그인 항목 변경 실패: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
```

- [ ] **Step 2: 메뉴에 항목 추가**

`Sources/App.swift`의 `MenuBarExtra` 안, 모드 `ForEach` 블록과 종료 버튼 사이의 `Divider()` 다음에 넣는다:

```swift
            Button(controller.launchesAtLogin ? "☑ 로그인 시 시작" : "☐ 로그인 시 시작") {
                controller.launchesAtLogin.toggle()
            }
```

- [ ] **Step 3: 빌드**

Run: `./build.sh`
Expected: 오류 없음

- [ ] **Step 4: 토글 동작 확인**

```bash
open build/ChargerAwareSleep.app
sleep 2
```

메뉴에서 "로그인 시 시작"을 눌러 체크 표시가 바뀌는지 본다. 그 다음:

```bash
sfltool dumpbtm 2>/dev/null | grep -i -A2 ChargerAwareSleep || \
  echo "sfltool 확인 불가 — 시스템 설정 > 일반 > 로그인 항목 에서 직접 확인"
```

Expected: 등록 시 항목이 나타나고, 해제하면 사라진다. 시스템 설정의 로그인 항목 목록에서도 확인할 수 있다.

- [ ] **Step 5: 정리하고 커밋**

체크를 해제한 상태로 두고 앱을 종료한다.

```bash
pkill -x ChargerAwareSleep
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
git add Sources/App.swift
git commit -m "feat: SMAppService 로 로그인 시 시작 토글

별도 LaunchAgent plist 를 두지 않는다. 기동 경로가 둘이면 이중 실행이 된다."
```

주의: `pkill`은 `applicationWillTerminate`를 거치지 않을 수 있다. 위 `ioreg`가 `Yes`면 `sudo -n /usr/bin/pmset -a disablesleep 0`으로 되돌리고, 이 사실을 Task 6의 failsafe 판단 근거로 기록한다.

---

### Task 6: 실동작 검증과 미확인 항목 해소

spec의 "구현 중 확인할 것" 3개를 실제로 측정하고, 그 결과로 failsafe 형태를 정한다.

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-09-06-chargerawaresleep-design.md`

- [ ] **Step 1: 본래 목적이 동작하는지 확인**

충전기를 연결하고 외부 모니터를 분리한 상태에서:

```bash
./build.sh && open build/ChargerAwareSleep.app
sleep 2
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
```

Expected: `Yes`

그 다음 아래를 실행하고 **바로 뚜껑을 닫는다.** 3분 뒤 연다.

```bash
{ for i in $(seq 1 100); do date +%H:%M:%S; sleep 2; done; } > /tmp/cas_lid.log
```

뚜껑을 연 뒤:

```bash
head -3 /tmp/cas_lid.log; echo ...; tail -3 /tmp/cas_lid.log
awk 'NR>1{ "date -j -f %H:%M:%S "$0" +%s" | getline t; if (p && t-p > 6) print "구멍:", p, "->", t; p=t } NR==1{ "date -j -f %H:%M:%S "$0" +%s" | getline p }' /tmp/cas_lid.log
pmset -g log | grep -E "$(date +%Y-%m-%d)" | grep -E 'Notification|Entering Sleep' | tail -6
```

Expected: 타임스탬프에 구멍이 없다(시스템이 자지 않았다). `Display is turned off`가 있고 `Entering Sleep ... Clamshell Sleep`은 없다.

- [ ] **Step 2: 충전기를 뽑아 자동 전환 확인**

```bash
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'   # 뽑기 전
# 충전기를 뽑는다
sleep 3
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'   # 뽑은 후
# 다시 꽂는다
sleep 3
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
```

Expected: `Yes` → `No` → `Yes`. polling이 아니라 알림으로 도는지 확인하는 지점이다. 3초 안에 안 바뀌면 구독이 깨진 것이다.

- [ ] **Step 3: 슬립/웨이크 후 구독 유지 확인**

```bash
sudo -n /usr/bin/pmset -a disablesleep 0
pmset sleepnow
```

깨운 뒤 충전기를 뽑았다 꽂아 Step 2를 다시 한다.

Expected: 여전히 3초 안에 반응한다. 반응이 없으면 `IOPSNotification` 재구독이 필요하다는 뜻이므로, `NSWorkspace.didWakeNotification`에서 `subscribeToPowerChanges()`를 다시 부르는 코드를 추가하고 이 사실을 기록한다.

- [ ] **Step 4: 재부팅 영속성 측정**

```bash
sudo -n /usr/bin/pmset -a disablesleep 1
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'   # Yes 확인
```

앱을 완전히 종료하고 로그인 항목에서도 해제한 뒤 재부팅한다. 부팅 후:

```bash
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
uptime
```

- `No`면 재부팅이 스스로 리셋한다 → 부팅 리셋용 LaunchDaemon은 불필요하다.
- `Yes`면 잔류한다 → LaunchDaemon이 필요하다. Step 6에서 추가한다.

- [ ] **Step 5: spec의 미확인 항목 갱신**

`docs/superpowers/specs/2026-09-06-chargerawaresleep-design.md`의 "구현 중 확인할 것" 섹션을 측정 결과로 바꾼다. 각 항목에 측정 날짜와 관측값을 적는다. 추측을 남기지 않는다.

- [ ] **Step 6: 필요할 때만 부팅 리셋 LaunchDaemon 추가**

Step 4에서 `Yes`가 나온 경우에만 한다. `No`였다면 이 스텝을 건너뛰고 README에 "재부팅이 스스로 리셋하므로 부팅 리셋 데몬은 두지 않는다"와 측정 날짜를 적는다.

`install/dev.local.ChargerAwareSleep.reset.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.local.ChargerAwareSleep.reset</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/pmset</string>
    <string>-a</string>
    <string>disablesleep</string>
    <string>0</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```

설치:

```bash
sudo install -m 0644 -o root -g wheel \
  install/dev.local.ChargerAwareSleep.reset.plist \
  /Library/LaunchDaemons/dev.local.ChargerAwareSleep.reset.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/dev.local.ChargerAwareSleep.reset.plist
```

- [ ] **Step 7: `README.md` 작성**

```markdown
# ChargerAwareSleep

충전기가 연결되면 뚜껑을 닫아도 본체가 계속 돌고, 뽑으면 macOS 기본 동작으로 돌아온다.
전원 공급원에 따라 `pmset disablesleep` 을 자동으로 전환하는 메뉴바 앱.

설계와 근거: `docs/superpowers/specs/2026-09-06-chargerawaresleep-design.md`

## 전제 조건

Amphetamine 처럼 `PreventUserIdleDisplaySleep` assertion 을 잡는 앱이 떠 있으면
뚜껑을 닫아도 내부 패널이 꺼지지 않는다. 이 앱을 쓰기 전에 그런 앱을 정리해야 한다.

확인:

    pmset -g assertions | grep PreventUserIdleDisplaySleep

## 설치

1. sudoers 규칙 — `disablesleep` 쓰기에 root 가 필요하다.

        sudo install -m 0440 -o root -g wheel \
          install/chargerawaresleep.sudoers /etc/sudoers.d/chargerawaresleep
        sudo visudo -c -f /etc/sudoers.d/chargerawaresleep

   admin 그룹의 임의 프로세스가 암호 없이 `pmset -a disablesleep` 을 실행할 수 있게 된다.
   영향 범위는 잠자기 정책 변경으로 한정된다.

2. 빌드하고 설치한다.

        ./build.sh
        cp -R build/ChargerAwareSleep.app /Applications/

3. 앱을 실행하고 메뉴에서 "로그인 시 시작" 을 켠다.

## 테스트

    ./test.sh

정책 결정 로직만 검증한다. `pmset` 을 부르지 않는다.

## 제거

    pkill -x ChargerAwareSleep
    sudo rm /etc/sudoers.d/chargerawaresleep
    rm -rf /Applications/ChargerAwareSleep.app

앱은 종료 시 `disablesleep 0` 으로 복원한다. 확인:

    ioreg -n IOPMrootDomain -r -d1 | grep SleepDisabled
```

- [ ] **Step 8: 커밋**

```bash
git add README.md docs/ install/ Sources/
git commit -m "docs: 실동작 검증 결과와 설치 절차

spec 의 미확인 항목 3개를 측정값으로 대체했다.
부팅 리셋 데몬 여부는 재부팅 영속성 측정 결과에 따라 정했다."
```

---

## Self-Review

**Spec coverage**

| spec 항목 | 태스크 |
|---|---|
| 상태 모델 3모드 | Task 1 (`Mode`, `desiredSleepDisabled`), Task 4 (UI) |
| 종료 시 복원 | Task 4 Step 3 (`AppDelegate.applicationWillTerminate`) |
| 메뉴바 UI | Task 4 Step 3, Task 5 Step 2 |
| 전원 변경 감지 (이벤트 구독) | Task 4 Step 3 (`subscribeToPowerChanges`), Task 6 Step 2 검증 |
| 전원 판정 = power source | Task 2 (`powerSource`), Task 1 테스트 |
| 상태 읽기 = IORegistry | Task 2 (`sleepDisabled`, `clamshellClosed`) |
| 상태 쓰기 = sudo pmset | Task 3 (`SleepControl.set`) |
| 뚜껑 상태 표시용 | Task 2 (`clamshellClosed`), Task 4 (`statusLine`) |
| sudoers 규칙, 앱이 쓰지 않음 | Task 3 Step 1/3 |
| `sudo -n` 실패 시 메뉴에 표시 | Task 3 Step 2 (`Result`), Task 4 Step 3 (`errorText`) |
| Failsafe: 종료 복원 | Task 4 Step 3 (`applicationWillTerminate`) |
| Failsafe: 부팅 리셋 (보류) | Task 6 Step 4/6 — 측정 후 결정 |
| Failsafe: KeepAlive | 의도적 제외. "Spec에서 벗어난 결정" 참조 |
| 검증: 순수 함수 self-check | Task 1 Step 2, `test.sh` |
| 구현 중 확인할 것 3개 | Task 6 Step 2/3/4 |

**Placeholder scan:** 없음. 모든 코드 스텝에 실제 코드가 들어 있다.

**Type consistency:** `desiredSleepDisabled(mode:source:)`, `SystemState.sleepDisabled()`, `SystemState.clamshellClosed()`, `SystemState.powerSource()`, `SleepControl.set(_:)`, `SleepControlError.commandFailed(status:message:)`, `Controller.apply()`, `Controller.refresh()`, `Controller.launchesAtLogin` — 정의와 사용처의 이름·시그니처가 일치한다.
