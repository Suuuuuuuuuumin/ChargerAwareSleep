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

### 2. `disablesleep=1`이어도 내부 패널은 정상적으로 꺼진다

뚜껑을 닫는 순간 `Display is turned off`가 뜬다:

```
21:01:13  Notification  Display is turned off     ← 뚜껑 닫힘
21:01:41  Notification  Display is turned on      ← 뚜껑 열림
```

즉 "본체는 깨어 있고 패널만 꺼진 상태"가 `disablesleep`만으로 성립한다.
`pmset displaysleepnow` 호출도, 전역 `displaysleep` 값 변경도 필요 없다.

### 3. 패널이 계속 켜져 있던 원인은 Amphetamine이었다

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
- 뚜껑 상태에 따른 동작 분기. `disablesleep`은 뚜껑을 닫을 때만 의미가 있으므로
  뚜껑 상태를 볼 필요가 없다. `AppleClamshellState`는 메뉴 표시용으로만 쓴다.

## 상태 모델

3개 모드. 사용자가 메뉴에서 선택하며, 선택은 `UserDefaults`에 저장된다.

| 모드 | 동작 |
|---|---|
| 자동 (기본값) | AC → `disablesleep 1`, 배터리 → `disablesleep 0` |
| 항상 켬 | `1` 고정. 전원 변경 무시 |
| 항상 끔 | `0` 고정. 전원 변경 무시 |

모드 전환 시 즉시 반영한다.

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

단일 실행 파일. 파일 4개를 넘기지 않는다.

| 관심사 | 구현 |
|---|---|
| 전원 변경 감지 | `IOPSNotificationCreateRunLoopSource` (이벤트 구독, polling 아님) |
| 전원 판정 | `IOPSGetProvidingPowerSourceType() == kIOPMACPowerKey` |
| 상태 읽기 | `IOPMrootDomain`의 `SleepDisabled` (IORegistry, 권한 불필요) |
| 상태 쓰기 | `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep <0\|1>` |
| 뚜껑 상태 (표시용) | `IOPMrootDomain`의 `AppleClamshellState` |
| UI | SwiftUI `MenuBarExtra` |

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

## 구현 중 확인할 것

- `disablesleep`의 재부팅 영속성 (위 Failsafe 3번의 판단 근거)
- `sudo -n`이 GUI 앱 컨텍스트에서 sudoers 규칙을 타는지
- 시스템 슬립/웨이크 후 `IOPSNotification` 구독이 유지되는지, 재구독이 필요한지

## 검증

정책 결정 로직(전원 상태 + 모드 → 목표 `disablesleep` 값)은 순수 함수로 분리해
`assert` 기반 self-check를 남긴다. `pmset` 실행 없이 검증 가능해야 한다.

실제 동작 확인은 위 "실측으로 확정한 사실" 1번의 재현 절차를 쓴다.
