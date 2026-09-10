# ChargerAwareSleep — 설계

작성일: 2026-09-06
상태: 승인됨 (구현 계획 대기)

## 문제

MacBook은 뚜껑을 닫으면 즉시 잠든다(clamshell sleep). 충전기가 연결된 상태에서
백그라운드 작업을 계속 돌리려면 이 동작을 꺼야 한다. 그러나 꺼둔 채로 두면
배터리로 전환됐을 때도 잠들지 않아 가방 안에서 방전·발열이 발생한다.

전원 상태에 따라 이 정책을 자동으로 전환하는 것이 목표다.

## 실측으로 확정한 사실 (2026-09-06, macOS 26.7, M3 Max)

설계의 근거이므로 재조사하지 말 것. 재현 방법은 각 항목에 적었다.

### 1. `pmset -a disablesleep 1`이 clamshell sleep을 막는다

`SleepDisabled=0`에서 충전기 연결 상태로 뚜껑을 닫으면 잠든다:

```
17:19:11  Notification  Display is turned off
17:19:16  Sleep         Entering Sleep state due to 'Clamshell Sleep' Using AC (Charge:90%)
```

`SleepDisabled=1`에서 뚜껑을 닫으면 잠들지 않는다. 2초 간격 타임스탬프 로그가
뚜껑 닫힘 구간(21:01:14~21:01:41) 내내 끊김 없이 기록됐고, `pmset -g log`에
`Entering Sleep` 항목이 없었다.

재현: `sudo pmset -a disablesleep 1` 후 뚜껑을 닫고,
`while :; do date; sleep 2; done > log` 의 출력에 구멍이 생기는지 본다.

### 2. (정정됨 2026-09-07) `disablesleep=1`이면 내부 패널이 꺼지지 않는다

**아래 원래 항목은 틀렸다. 사용자의 직접 관찰로 뒤집혔다.**

2026-09-07 새벽, 앱을 켠 채 충전기를 연결하고 뚜껑을 닫았을 때 내부 패널이 계속 켜져 있는 것을
사용자가 눈으로 확인했다. 시스템은 정상적으로 깨어 있었다(타임스탬프 로그 3분 20초 구멍 없음).

원래 판정의 근거였던 `pmset -g log`의 `Display is turned off` 알림은 패널 소등의 신뢰할 수 있는
지표가 아니다. 같은 날 다음 두 지표도 무효로 확인됐다. 다시 시도하지 말 것:

- `IOMobileFramebufferAP`의 `CurrentPowerState` — `pmset displaysleepnow`로 화면을 껐는데도
  값이 `1`로 고정이었다.
- `AppleSmartBattery`의 `FilteredPower` — 화면을 꺼도 값이 변하지 않았다. 장기 평균이라
  수십 초 단위 판별에 쓸 수 없다. `InstantAmperage`는 AC 연결 시 항상 `0`이다.

원인은 `disablesleep`이 아니라 디스플레이 idle sleep 설정이다:

```
pmset -g custom → Battery/AC 둘 다  displaysleep 0
```

뚜껑을 닫으면 입력이 없으니 원래는 idle 타이머가 패널을 끈다. 그 값이 `0`(never)이라 영원히
꺼지지 않는다. `disablesleep`은 시스템 잠자기만 막을 뿐 패널 소등과는 별개 경로다.

대응은 뚜껑 닫힘을 감지해 `pmset displaysleepnow`를 호출하는 것이다. 아래 5번 참조.

---

원래 항목 (틀림, 기록용으로만 남김):

### 2. ~~`disablesleep=1`이어도 내부 패널은 정상적으로 꺼진다~~

뚜껑을 닫는 순간 `Display is turned off`가 뜬다:

```
21:01:13  Notification  Display is turned off     ← 뚜껑 닫힘
21:01:41  Notification  Display is turned on      ← 뚜껑 열림
```

즉 "본체는 깨어 있고 패널만 꺼진 상태"가 `disablesleep`만으로 성립한다.
`pmset displaysleepnow` 호출도, 전역 `displaysleep` 값 변경도 필요 없다.

### 3. (정정됨 2026-09-07) Amphetamine은 원인의 전부가 아니었다

Amphetamine을 제거한 뒤에도 패널은 계속 켜져 있다(2번 참조). Amphetamine의
`PreventUserIdleDisplaySleep` assertion은 패널 소등을 막는 여러 요인 중 하나였을 뿐이고,
`displaysleep 0` 설정이 남아 있는 한 제거만으로는 해결되지 않는다.

---

원래 항목 (부분적으로만 맞음):

### 3. ~~패널이 계속 켜져 있던 원인은 Amphetamine이었다~~

Amphetamine 세션이 켜져 있으면 `PreventUserIdleDisplaySleep` assertion을 잡고,
이 상태에서는 뚜껑을 닫아도 `Display is turned off`가 발생하지 않는다.
세션을 끄면 위 2번처럼 정상 동작한다.

**따라서 이 앱을 쓰려면 Amphetamine을 제거하거나 display assertion을 잡지 않게
설정해야 한다.** 그러지 않으면 이 앱이 있어도 패널은 계속 켜져 있다.

### 4. 전원 판정은 charging 여부가 아니라 power source여야 한다

배터리 90%에서 충전기를 꽂으면 다음 상태가 된다:

```
Now drawing from 'AC Power'
 -InternalBattery-0  90%; AC attached; not charging present: true
```

"충전 중"을 기준으로 판정하면 이 상태에서 오작동한다.
`IOPSGetProvidingPowerSourceType() == kIOPMACPowerKey`를 기준으로 한다.

### 5. 명령별 문서화 상태와 권한

| 명령 | `man pmset` | root |
|---|---|---|
| `pmset -a disablesleep <0\|1>` | 없음 (미문서화) | 필요 |
| `pmset displaysleepnow` | 있음 | 불필요 |

`displaysleepnow`는 2026-09-06에 실행해 확인했다: `exit=0`, 암호 요구 없음,
`Display is turned off` 즉시 기록. 효과는 입력이 없는 동안 유지된다(20:54:40~20:58:44, 4분).
단, 호출 직후 입력이 있으면 즉시 취소된다(20:54:22에 off→on이 같은 초에 발생).
따라서 뚜껑이 닫힌 **뒤에** 호출해야 한다.

`disablesleep`이 미문서화라는 점은 감수한다. Amphetamine 같은 서드파티의 비공개
API보다는 표면적이 작지만, Apple이 보장한 인터페이스는 아니다. macOS major
업그레이드 때마다 1번 항목 재현 절차로 회귀 확인이 필요하다.

### 6. 상태 읽기는 권한 없이 가능하다

```
ioreg -n IOPMrootDomain -r -d1 | grep SleepDisabled
"SleepDisabled" = No
```

읽기는 IORegistry, 쓰기만 `pmset` + root. 경로가 분리된다.

### 7. 뚜껑 개폐 감지 키

```
ioreg -r -k AppleClamshellState → "AppleClamshellState" = Yes(닫힘) / No(열림)
```

`IOPMrootDomain`에 있는 공개 키다. 표시 용도로만 쓴다(아래 참조).

주의: `pmset -g assertions`의 `com.apple.powermanagement.lidopen` assertion은
뚜껑을 닫아도 남아 있어 개폐 판정에 쓸 수 없다.

### 9. (2026-09-07 추가) 뚜껑 닫힘 이벤트 구독과 패널 소등이 동작한다

`IOPMrootDomain`에 `IOServiceAddInterestNotification(kIOGeneralInterest)`로 구독하면 뚜껑 개폐가
이벤트로 온다. 콜백에서 `AppleClamshellState`를 다시 읽어 전이를 판정한다. polling이 필요 없다.
측정에서 이벤트가 1초 폴링보다 항상 먼저 도착했다.

```
11:39:08  뚜껑 닫힘  msgType=0xe0034100
11:39:09  [폴링] 뚜껑 닫힘
```

뚜껑이 닫힌 **뒤에** `pmset displaysleepnow`를 호출하면 패널이 실제로 꺼지고, 입력이 없는 동안
유지된다. 2026-09-07에 뚜껑을 36초 닫아두고(11:41:42~11:42:18) 살짝 열어 눈으로 확인했다.

**재진입 주의.** `Process.waitUntilExit()`는 런루프를 돌리므로 콜백이 재진입한다. 상태 갱신을
작업보다 뒤에 두면 매번 통과해 중복 실행된다. 실제로 한 번의 뚜껑 닫힘에 `displaysleepnow`가
5번 발사됐다. 상태를 먼저 갱신하고, 콜백 안에서 `waitUntilExit()`를 부르지 않는다.

**판정에 로그를 쓰지 말 것.** `pmset -g log`의 `Display is turned off`는 `displaysleepnow` 없이
그냥 뚜껑을 닫아도 똑같이 찍힌다(11:39:08). 패널 소등 여부를 구분하지 못한다. 위 2번 참조.

### 8. 툴체인

Xcode 미설치, CommandLineTools만 있음 → `xcodebuild` 사용 불가.
`swiftc` (Swift 6.4) + macOS SDK 27.0은 사용 가능.

→ Xcode 프로젝트 대신 `swiftc` 빌드 + 수제 `.app` 번들로 간다.
이 환경에서 빌드·실행 검증이 가능하다.

## 범위

포함:
- 전원 상태에 따른 `disablesleep` 자동 전환
- 메뉴바 상태 표시와 수동 모드 전환

제외:
- idle sleep 관리. 현재 AC에서 `sleep 0`이라 이미 잠들지 않고, 배터리에서
  잠들지 않게 만드는 것은 방전을 부른다. Amphetamine의 이 기능은 대체하지 않는다.
(2026-09-07 정정) "뚜껑 상태에 따른 동작 분기"는 제외 항목이 아니다. 원래는 뚜껑 상태를 볼
필요가 없다고 봤으나, `disablesleep`만으로는 패널이 꺼지지 않는다는 것이 확인됐다(위 2번).
뚜껑 닫힘을 감지해 `pmset displaysleepnow`를 호출하는 것이 범위에 포함된다(위 9번).

## 상태 모델

3개 모드. 사용자가 메뉴에서 선택하며, 선택은 `UserDefaults`에 저장된다.

| 모드 | 동작 |
|---|---|
| 자동 (기본값) | AC → `disablesleep 1`, 배터리 → `disablesleep 0` |
| 항상 켬 | `1` 고정. 전원 변경 무시 |
| 항상 끔 | `0` 고정. 전원 변경 무시 |

모드 전환 시 즉시 반영한다.

### 항상 켬 경고 (2026-09-10 추가)

"항상 켬"은 전원 공급원을 무시하므로, 되돌리는 걸 잊은 채 배터리로 가방에
넣으면 안 자고 방전·발열이 난다. 실제로 겪은 사고다 — 자리를 옮기려고 켜두고
도착지에서 잊었다.

배터리 + 항상 켬일 때 두 곳에서 알린다.

| 표면 | 조건 | 성격 |
|---|---|---|
| 메뉴 맨 위 경고 한 줄 | 배터리 + 항상 켬 | 메뉴를 열면 항상 보인다 |
| 아이콘에 붙는 말풍선 | 위 조건 + **뚜껑이 열리고 잠금이 풀릴 때** | 5초 뒤 저절로 닫힌다 |

말풍선의 트리거가 뚜껑을 **여는** 순간인 이유: 닫을 땐 화면을 볼 사람이 없다.
다시 열어 자리에 도착한 시점이야말로 사용자가 화면 앞에 있다고 확신할 수 있는
순간이다.

다만 뚜껑을 열면 대개 잠금 화면이 먼저 뜬다. 거기에 말풍선을 띄우면 사용자는
못 보고 5초 뒤 조용히 닫힌다 — 알리려던 목적이 통째로 날아간다. 그래서 기준을
**잠금 해제**로 잡는다 (2026-09-10). 이미 풀려 있으면 곧바로 띄운다.

잠금 여부는 `CGSessionCopyCurrentDictionary()` 의 `CGSSessionScreenIsLocked` 로
읽는다. 잠기지 않았을 때는 **키 자체가 없다** (2026-09-10 실측 — 잠금 해제
상태에서 이 키가 딕셔너리에 나타나지 않았다). 그래서 없으면 "안 잠김"으로 읽는다.

해제를 안 하고 자리를 뜨면 `com.apple.screenIsUnlocked` 관측자가 떠 있게 되는데,
나중에 돌아와 풀 때 조건이 그대로면 그때 알리는 게 맞으므로 시한을 두지 않는다.

**모드를 자동으로 바꾸지 않는다.** 사용자가 의도적으로 켠 모드를 앱이 마음대로
끄면, 뚜껑을 잠깐 덮었다 여는 상황(발표 등)에서 더 나쁜 오작동이 된다. 목표는
인지이지 자동 교정이 아니다. 말풍선에 응답이 없으면 모드를 유지한 채 닫는다.

판정은 `shouldWarnAlwaysOnBattery(mode:source:)` 하나이고, 말풍선 쪽
`shouldAskKeepAlwaysOn(lidClosed:mode:source:)` 이 그것을 재사용한다 — 두 표면이
서로 다른 말을 하지 않게 한다.

#### 메뉴바 팝오버 위치 (2026-09-10 실측)

`NSPopover` 를 상태아이템에 붙이면 아이콘 아래에 정확히 뜬다. 사용자 클릭이
없어도(타이머로 띄워도) 뜬다 — 메뉴에 5초 지연 시험 스위치를 넣어 확인했다.

**`NSStatusBarWindow.frame` 은 믿지 말 것.** 항상 화면 밖을 보고한다:

```
NSStatusBarWindow frame      = {{-3694, 1290}, {37, 39}}
statusItem.button 화면좌표   = {{-3723, 1294.5}, {29, 31}}
NSScreen                     = {{0, 0}, {2056, 1329}}
```

`NSApp.activate` 후에도, `open` 으로 띄운 서명된 번들에서도, 메뉴를 열었다 닫은
뒤에도 값은 그대로였다. 그런데도 팝오버는 제자리에 뜬다 — AppKit 이 진짜 위치를
따로 안다. **이 좌표로 위치를 직접 계산하려 들지 말 것.**

한때 팝오버가 화면 왼쪽 끝(x=0)으로 밀리는 것을 보고 기능을 접었다가 되살렸다.
그 증상은 **갓 띄운 프로브 앱에서만** 재현됐다. 상태아이템이 메뉴바에서 실제
자리를 받지 못한 프로세스에서 나는 현상으로 보인다. 오래 살아 있는 진짜 앱에서는
클릭이든 타이머든 정상이다. 프로브로 잰 값을 본 앱의 동작으로 일반화하지 말 것 —
이 조사에서 하루를 썼다.

**미측정**: 웨이크·잠금 해제 직후는 화면이 아직 자리를 잡는 중이라 1초 늦춰
앵커를 찾는다. 이 값은 추정치다 — 말풍선이 안 뜨면 여기부터 키운다.

### 종료 시 동작

**어떤 모드였든 종료 시 `disablesleep 0`으로 복원한다.** "항상 켬"이었어도
복원한다.

근거: 잔류 상태의 실패 모드가 비대칭이다. `1`이 남으면 가방 안에서 잠들지 않아
방전·발열이 발생한다. `0`이 남으면 그냥 원래 macOS 동작이다. 사용자를 놀라게
하는 비용보다 열이 갇히는 비용이 크다.

메뉴의 종료 항목에 "(잠자기 복원됨)"을 표기해 놀람을 줄인다.

## 메뉴바 UI

```
 ● 잠자기 비활성 · 충전 중
 ─────────────────────
 ◉ 자동 전환
 ○ 항상 켬
 ○ 항상 끔
 ─────────────────────
 ☑ 로그인 시 시작
 종료 (잠자기 복원됨)
```

- 첫 줄은 현재 `SleepDisabled` 값과 전원 상태를 그대로 보여준다.
  앱이 믿는 값이 아니라 IORegistry에서 읽은 실제 값을 표시한다.
- `LSUIElement=true` — Dock 아이콘 없음.
- 아이콘은 `SleepDisabled` 값에 따라 2상태.

## 아키텍처

단일 실행 파일. `Sources/` 파일 6개.

상한은 원래 4개였다. 뚜껑 개폐 구독(`LidWatcher`)에서 5개, 항상 켬 확인
말풍선(`AlwaysOnPrompt`)에서 6개가 됐다. 둘 다 수명주기를 가진 구독·표시
객체라 `App.swift` 에 합치면 `Controller` 가 정책·구독·표시를 한꺼번에 떠안는다.

| 관심사 | 구현 |
|---|---|
| 전원 변경 감지 | `IOPSNotificationCreateRunLoopSource` (이벤트 구독, polling 아님) |
| 전원 판정 | `IOPSGetProvidingPowerSourceType() == kIOPMACPowerKey` |
| 상태 읽기 | `IOPMrootDomain`의 `SleepDisabled` (IORegistry, 권한 불필요) |
| 상태 쓰기 | `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep <0\|1>` |
| 뚜껑 상태 | `IOPMrootDomain`의 `AppleClamshellState` |
| 뚜껑 개폐 감지 | `IOServiceAddInterestNotification(kIOGeneralInterest)` on `IOPMrootDomain` |
| 패널 소등 | `/usr/bin/pmset displaysleepnow` (권한 불필요) |
| UI | SwiftUI `MenuBarExtra` |
| 항상 켬 말풍선 | `NSPopover` + `NSHostingController`, 앵커는 `NSApp.windows` 의 `NSStatusBarWindow` |

경계: 전원 감지 / 정책 결정 / `pmset` 실행이 각각 분리돼야 정책 로직을
`pmset` 없이 테스트할 수 있다.

## 권한

설치 시 사용자가 직접 다음 파일을 만든다:

```
/etc/sudoers.d/chargerawaresleep
%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep *
```

앱은 `/etc/sudoers.d`에 쓰지 않는다. 앱이 sudoers를 수정할 수 있다는 것 자체가
이 규칙 한 줄보다 큰 구멍이다.

보안 영향: `%admin` 그룹의 임의 프로세스가 암호 없이 이 명령을 실행할 수 있게
된다. 영향 범위는 잠자기 정책 변경으로 한정된다. 이 트레이드오프를 받아들이지
못하면 `SMAppService` privileged helper로 가야 하며, Developer ID 서명($99/년)과
수 배의 코드가 필요하다.

`sudo -n`이 실패하면(규칙 미설치 등) 조용히 넘어가지 말고 메뉴에 오류 상태를
표시한다.

## Failsafe

앱이 죽은 채로 `SleepDisabled=1`이 남는 것이 이 앱의 유일한 심각한 실패 모드다.

1. `LaunchAgent`에 `KeepAlive=true` — 크래시 시 재시작. 재기동하면서 상태를
   다시 평가한다.
2. 정상 종료 시 `0` 복원 (위 상태 모델 참조).
3. 부팅 시 리셋용 `LaunchDaemon` — **보류.** `disablesleep`이 재부팅 후에도
   유지되는지 확인되지 않았다(측정 당시 uptime 7일). 유지되지 않는다면 불필요한
   부품이므로, 구현 중 재부팅으로 확인한 뒤 필요할 때만 추가한다.

## 구현 중 확인한 것 (2026-09-07)

### 1. `disablesleep`의 재부팅 영속성 — **미측정**

Failsafe 3번(부팅 리셋 `LaunchDaemon`)의 판단 근거인데 아직 재지 못했다.
2026-09-07 재부팅 때 로그인 항목이 켜져 있어 부팅 32초 만에 앱이 떠버렸고,
부팅 직후의 `SleepDisabled=No`가 부팅 리셋 때문인지 앱 때문인지 구분할 수 없었다.

약한 반증 하나: `pmset -g custom`에 `disablesleep` 키가 없다. 영구 설정이 아닐
가능성을 시사하지만 값이 `0`이라 확정할 수 없다.

재현 절차 (앱을 끄고 로그인 항목도 해제한 뒤에 해야 한다):

```bash
sudo -n /usr/bin/pmset -a disablesleep 1
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'   # Yes 확인
# 앱 종료 + 메뉴의 "로그인 시 시작" 해제 + 재부팅
ioreg -n IOPMrootDomain -r -d1 | grep -o '"SleepDisabled" = [A-Za-z]*'
```

`No`면 부팅이 스스로 리셋한다 → LaunchDaemon 불필요. `Yes`면 필요하다.
측정 전까지 Failsafe 3번은 보류 상태로 둔다.

### 2. `sudo -n`이 GUI 앱 컨텍스트에서 sudoers 규칙을 탄다 — **확인됨**

터미널 세션 밖에서 띄운 `.app`이 암호 프롬프트 없이 `disablesleep`을 바꾼다.
2026-09-07 23:06 측정:

```
23:06:34  SleepDisabled = No      ← 앱 종료 상태
23:06:34  open ChargerAwareSleep.app
23:06:37  SleepDisabled = Yes     ← 3초 안에 전환, 암호 프롬프트 없음
```

`sudo -n`은 tty를 요구하지 않으므로 GUI 컨텍스트에서도 sudoers 규칙만 맞으면 통과한다.

### 3. 시스템 슬립/웨이크 후 `IOPSNotification` 구독 유지 — **미측정**

재현 절차:

```bash
sudo -n /usr/bin/pmset -a disablesleep 0
pmset sleepnow
# 깨운 뒤 충전기를 뽑았다 꽂으며 3초 안에 SleepDisabled 가 따라오는지 본다
```

반응이 없으면 `NSWorkspace.didWakeNotification`에서 `subscribeToPowerChanges()`를
다시 불러야 한다는 뜻이다.

### 4. (추가 발견) SIGTERM은 `applicationWillTerminate`로 오지 않는다 — **고침**

2026-09-07 실측: 앱을 `pkill -x ChargerAwareSleep` 한 뒤 `SleepDisabled`가 `Yes`로
남았다. 위 Failsafe가 "유일한 심각한 실패 모드"라고 부른 잔류 상태다.
AppKit은 SIGTERM을 정상 종료 경로에 연결해주지 않는다. `launchctl stop`, 로그아웃
도중의 강제 종료, 설치 스크립트가 모두 이 경로다.

`DispatchSourceSignal`로 SIGTERM을 받아 `NSApp.terminate`로 돌려 해결했다.
확인: 실행 중 `Yes` → `pkill` → `No`.

SIGKILL과 크래시는 여전히 복원되지 않는다. OS 소관이라 앱이 할 수 있는 일이 없다.

## 검증

정책 결정 로직(전원 상태 + 모드 → 목표 `disablesleep` 값)은 순수 함수로 분리해
`assert` 기반 self-check를 남긴다. `pmset` 실행 없이 검증 가능해야 한다.

실제 동작 확인은 위 "실측으로 확정한 사실" 1번의 재현 절차를 쓴다.
