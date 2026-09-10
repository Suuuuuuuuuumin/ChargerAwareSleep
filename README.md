# ChargerAwareSleep

충전기가 연결되면 뚜껑을 닫아도 본체가 계속 돌고, 뽑으면 macOS 기본 동작으로 돌아온다.
전원 공급원에 따라 `pmset disablesleep` 을 자동으로 전환하는 메뉴바 앱.

설계와 근거: `docs/superpowers/specs/2026-09-06-chargerawaresleep-design.md`
(실측 결과가 전부 여기 있다. 같은 조사를 반복하지 말 것.)

## 동작

| 전원 | 뚜껑 | 결과 |
|---|---|---|
| 충전기 | 닫힘 | 본체는 계속 돈다. 내부 패널은 앱이 직접 끈다. |
| 배터리 | 닫힘 | macOS 기본 — 잠든다. |

배터리인데 "항상 켬"이면 두 곳에서 알린다. 메뉴 맨 위에 경고 한 줄이 뜨고,
그 상태로 **뚜껑을 열면** 아이콘 아래에 말풍선이 뜬다(5초 뒤 저절로 닫힌다).
어느 쪽도 모드를 대신 바꾸지 않는다 — "자동 전환"을 직접 눌러야 바뀐다.

메뉴바 아이콘 두 상태: **뜬 눈** = 잠자기 비활성(깨어 있음), **감은 눈** = 평소대로 잘 수 있음.

메뉴에서 자동 전환 / 항상 켬 / 항상 끔 을 고를 수 있고, 첫 줄은 앱이 믿는 값이 아니라
IORegistry 에서 읽은 실제 값을 보여준다.

## 전제 조건

`PreventUserIdleDisplaySleep` assertion 을 잡는 앱(Amphetamine 등)이 떠 있으면
앱이 `displaysleepnow` 를 불러도 내부 패널이 꺼지지 않는다. 확인:

    pmset -g assertions | grep PreventUserIdleDisplaySleep

## 설치

1. sudoers 규칙 — `disablesleep` 쓰기에 root 가 필요하다.

        sudo install -m 0440 -o root -g wheel \
          install/chargerawaresleep.sudoers /etc/sudoers.d/chargerawaresleep
        sudo visudo -c -f /etc/sudoers.d/chargerawaresleep

   admin 그룹의 임의 프로세스가 암호 없이 `pmset -a disablesleep 0` 과 `... 1` 을
   실행할 수 있게 된다. 값을 두 줄로 고정해 두었다 — 와일드카드를 쓰면 `pmset -a` 의
   설정 체이닝 때문에 임의 전원 설정까지 열린다 (근거는 sudoers 파일 주석에).

2. 아이콘을 만들고 빌드한다.

        ./make-icon.sh      # Resources/AppIcon.icns 생성 (한 번만)
        ./build.sh
        cp -R build/ChargerAwareSleep.app /Applications/

3. 앱을 실행하고 메뉴에서 "로그인 시 시작" 을 켠다.
   ad-hoc 서명(Developer ID 없음)으로도 `SMAppService` 등록이 실동작한다
   (2026-09-07 재부팅으로 확인).

## 테스트

    ./test.sh

정책 결정 로직만 검증한다. `pmset` 을 부르지 않는다.

## 잔류 상태와 복원

앱이 죽은 채 `SleepDisabled=1` 이 남는 것이 이 앱의 유일한 심각한 실패 모드다
(가방 안에서 방전·발열).

| 종료 경로 | 복원 |
|---|---|
| Cmd-Q · 메뉴의 종료 · 로그아웃 | 된다 |
| SIGTERM (`pkill`, `launchctl stop`) | 된다 |
| SIGKILL · 크래시 · 전원 차단 | **안 된다** — OS 소관 |

부팅 리셋용 `LaunchDaemon` 은 두지 않았다. `disablesleep` 의 재부팅 영속성을 아직
측정하지 못했기 때문이다 (절차는 spec "구현 중 확인한 것" 1번). 재부팅이 스스로
리셋한다면 불필요한 부품이다.

수동 확인:

    ioreg -n IOPMrootDomain -r -d1 | grep SleepDisabled

수동 복원:

    sudo -n /usr/bin/pmset -a disablesleep 0

## 제거

    pkill -x ChargerAwareSleep          # 종료하면서 잠자기를 복원한다
    sudo rm /etc/sudoers.d/chargerawaresleep
    rm -rf /Applications/ChargerAwareSleep.app

메뉴의 "로그인 시 시작" 은 끄고 지울 것. 켠 채로 앱만 지우면 로그인 항목이 고아로 남는다.
