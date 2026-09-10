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

    /// apply() 가 매번 재평가하는 일시적 오류. 다음 apply() 성공 시 지워진다.
    @Published private(set) var applyErrorText: String?
    /// 구독 실패는 앱이 살아있는 동안 계속되는 상태다 — apply() 가 지워선 안 된다.
    /// (재시도 로직이 없으므로 프로세스 수명 동안 고정값이다.)
    @Published private(set) var subscriptionErrorText: String?
    /// 패널 소등(pmset displaysleepnow) 실패. sudo 를 타지 않으므로 sudoers 힌트를 붙이면
    /// 안 된다 — applyErrorText 와 도메인이 다르다. (Task 5 판정과 같은 이유)
    @Published private(set) var displayErrorText: String?
    /// 구독을 유지하기 위해 붙잡아 둔다. 놓으면 알림이 끊긴다.
    private var runLoopSource: CFRunLoopSource?

    /// 뚜껑 개폐 구독. 소유권을 놓으면 알림이 끊긴다.
    private let lidWatcher = LidWatcher()

    /// 항상 켬 확인 말풍선. lidWatcher 와 같은 이유로 프로퍼티로 붙잡는다 —
    /// 지역변수로 두면 handleLidChange 가 끝나는 순간 참조가 사라져 popover/타이머가
    /// 죽는다(내부 클로저들은 self 를 weak 로만 잡는다).
    private let alwaysOnPrompt = AlwaysOnPrompt()

    init() {
        let raw = UserDefaults.standard.string(forKey: "mode") ?? Mode.auto.rawValue
        mode = Mode(rawValue: raw) ?? .auto
        if !subscribeToPowerChanges() {
            noteSubscriptionFailure("전원 변경 감지를 시작하지 못했습니다. 자동 전환이 동작하지 않습니다.")
        }
        lidWatcher.onChange = { [weak self] closed in self?.handleLidChange(closed) }
        if !lidWatcher.start() {
            noteSubscriptionFailure("뚜껑 감지를 시작하지 못했습니다. 뚜껑을 닫아도 화면이 꺼지지 않습니다.")
        }
        apply()
    }

    /// 구독은 재시도하지 않으므로 실패가 겹치면 둘 다 보여야 한다. 덮어쓰지 않고 쌓는다.
    private func noteSubscriptionFailure(_ text: String) {
        subscriptionErrorText = [subscriptionErrorText, text].compactMap { $0 }.joined(separator: "\n")
    }

    /// polling 하지 않는다. 전원 상태가 바뀔 때만 깨어난다.
    /// 실패(등록 거부 등)를 호출부가 알 수 있도록 성공 여부를 반환한다 —
    /// 이 실패를 조용히 삼키면 사용자도 개발자도 모르게 자동 전환이 멈춘다.
    private func subscribeToPowerChanges() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.apply() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return false }
        // .commonModes 여야 한다. 메뉴가 열려 있는 동안 런루프는 이벤트 추적 모드로
        // 돌고, .defaultMode 에만 걸어두면 그동안 알림이 배달되지 않는다.
        // (2026-09-10: 메뉴를 열어둔 채 충전기를 뽑아도 "충전 중"이 그대로였다)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        return true
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
            applyErrorText = nil
            return
        }
        switch SleepControl.set(want) {
        case .success:
            applyErrorText = nil
        case .failure(.commandFailed(_, let message)):
            applyErrorText = message
        }
        refresh()
    }

    /// 뚜껑이 열리거나 닫힐 때만 호출된다 — polling 이 아니다.
    /// 여는 쪽은 할 일이 없다. macOS 가 알아서 화면을 켠다.
    private func handleLidChange(_ closed: Bool) {
        // 앱이 기억하는 값이 아니라 커널의 실제 값으로 판단한다.
        refresh()

        // lidClosed 가 서로 반대라 아래 guard 와 동시에 참이 될 수 없다.
        if shouldAskKeepAlwaysOn(lidClosed: closed, mode: mode, source: source) {
            // 띄우는 시점을 1초 늦춘다(웨이크 대기). 그 사이 사용자가 모드를 바꿨을
            // 수 있으므로 직전에 커널의 최신 값으로 다시 확인한다.
            alwaysOnPrompt.show(
                stillApplies: { [weak self] in
                    guard let self else { return false }
                    return shouldAskKeepAlwaysOn(lidClosed: SystemState.clamshellClosed() ?? closed,
                                                 mode: self.mode, source: SystemState.powerSource())
                },
                // 자동 전환을 고르면 mode 의 didSet 이 apply() 를 불러 pmset 까지 간다.
                onAutoSwitch: { [weak self] in self?.mode = .auto }
            )
        }

        guard shouldTurnOffDisplay(lidClosed: closed, sleepDisabled: sleepDisabled) else { return }
        switch SleepControl.displaySleepNow() {
        case .success:
            displayErrorText = nil
        case .failure(.commandFailed(_, let message)):
            displayErrorText = message
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SIGTERM 을 잡아 두는 동안만 살아 있으면 된다. 해제하면 구독이 끊긴다.
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit 은 SIGTERM 을 applicationWillTerminate 로 연결해주지 않는다
        // (2026-09-07 실측: `pkill -x ChargerAwareSleep` 뒤 SleepDisabled 가 Yes 로 남았다).
        // `launchctl stop`, 로그아웃 도중의 강제 종료, 설치 스크립트가 모두 이 경로다.
        // 기본 동작(즉시 죽음)을 끄고 정상 종료로 돌려 복원 경로를 태운다.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cmd-Q, 메뉴의 종료, 로그아웃 등 "정상 종료" 경로에서만 복원한다.
        // 강제 종료·크래시까지 커버한다고 오해하지 말 것.
        //
        // 증상: 앱이 SIGKILL 되거나 크래시하면 SleepDisabled=1 이 잔류해, 뚜껑을 닫아도
        //       잠들지 않는다. 가방 안에서 방전·발열로 이어진다.
        // 트리거: 강제 종료(SIGKILL), 크래시, 전원 차단. SIGTERM 은
        //       applicationDidFinishLaunching 의 핸들러가 정상 종료로 돌려 이 경로를 탄다.
        // 시도했으나 안 되는 것: applicationWillTerminate 는 SIGKILL 을 잡을 수 없다.
        //       OS 소관이다.
        // 최종 결정: 정상 종료 경로만 복원한다. 부팅 시 리셋용 LaunchDaemon 은
        //       disablesleep 의 재부팅 영속성을 측정한 뒤(Task 6) 필요할 때만 추가한다.
        //
        // SleepControl 은 MainActor 격리가 없는 순수 enum 이라 Controller 를 거치지 않는다.
        // (MainActor.assumeIsolated 는 macOS 14 이상이라 타겟 13.0 에서 쓸 수 없다)
        // 여기서는 실패해도 할 수 있는 일이 없다 — 프로세스가 죽는 중이다.
        // 반환값을 버리는 것이 의도임을 `_ =` 로 명시한다.
        _ = SleepControl.set(false)
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

            // 배터리로 항상 켬이 켜져 있으면 메뉴 맨 위에서 알린다. 바로 아래
            // 모드 목록에서 한 번 더 누르면 되돌릴 수 있으므로 버튼을 따로 두지 않는다.
            //
            // 증상: 항상 켬을 켜둔 채 자리를 옮기고 되돌리는 걸 잊으면, 가방 안에서
            //   안 자고 방전·발열이 난다.
            // 트리거: 배터리 + 항상 켬.
            // 시도했으나 실패한 방법: 뚜껑을 열 때 아이콘에 NSPopover 말풍선을 붙이려
            //   했다. 2026-09-10 실측 — macOS 26 은 메뉴바를 out-of-process 로 그려서
            //   NSStatusItem 의 창이 화면 밖(x≈-3700, 화면은 x 0..2056)에 주차돼 있다.
            //   MenuBarExtra 든 직접 만든 NSStatusItem 이든, 번들 .app 이든 맨
            //   실행파일이든 모두 같았다. 그 좌표로 팝오버를 띄우면 화면 왼쪽 끝
            //   (x=0)으로 밀려 아이콘과 아무 관계 없는 자리에 뜬다.
            // 최종 결정: 앵커를 포기하고 메뉴 안의 경고 한 줄로 간다. 접근성 API 로
            //   실제 좌표를 읽는 길이 남아 있지만, 그 권한을 설치 절차에 더할 만큼의
            //   값어치는 없다고 봤다.
            //
            // 한계: 메뉴를 열어야만 보인다. 안 열어보면 여전히 모른다.
            if shouldWarnAlwaysOnBattery(mode: controller.mode, source: controller.source) {
                Text("⚠︎ 배터리인데 항상 켬 — 뚜껑을 닫아도 잠들지 않습니다")
            }

            if let subscriptionErrorText = controller.subscriptionErrorText {
                Divider()
                Text("오류: \(subscriptionErrorText)")
            }

            if let applyErrorText = controller.applyErrorText {
                Divider()
                Text("오류: \(applyErrorText)")
                Text("sudoers 규칙이 설치됐는지 확인하세요")
            }

            if let displayErrorText = controller.displayErrorText {
                Divider()
                Text("오류: 화면 끄기 실패 — \(displayErrorText)")
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
            Image(nsImage: Self.menuBarIcon(controller.sleepDisabled))
        }
    }

    /// 메뉴바 아이콘. MenuBarExtra 는 Image 에 붙인 .font/.imageScale 을 무시하므로
    /// (2026-09-07 실측: .font(.system(size: 18)) 을 줘도 잉크 높이가 13.0pt 그대로였다)
    /// 심볼을 직접 렌더해 NSImage 로 넘긴다.
    private static func menuBarIcon(_ sleepDisabled: Bool) -> NSImage {
        let image = sleepDisabled ? openEye() : closedEye()
        // 템플릿으로 두면 메뉴바 색(라이트/다크)을 시스템이 칠한다.
        image.isTemplate = true
        image.accessibilityDescription = sleepDisabled ? "잠자기 비활성화" : "잠자기 활성화"
        return image
    }

    /// 속눈썹 선 굵기(pt). 눈 획(regular)과 눈으로 맞춘 값이다 (2026-09-07).
    private static let lashWidth = 1.3

    /// 감은 눈을 공용 캔버스 한가운데에서 얼마나 옮길지 (pt, +y 는 위).
    ///
    /// 두 상태는 같은 크기 캔버스로 그려 메뉴바에서 폭이 튀지 않게 한다. 캔버스가
    /// 같으니 남는 자유도는 감은 눈의 위치뿐이고, 그건 눈으로 정하는 값이다.
    /// 어긋나 보이면 이 두 수만 고친다.
    private static let lidOffset = CGPoint(x: 0, y: -4.9)

    /// 속 빈 눈(`eye`)과 그 위에 얹을 속눈썹 선분들.
    /// 좌표계 원점은 눈 잉크의 왼쪽 아래다.
    ///
    /// SF Symbols 에는 속눈썹 달린 뜬 눈이 없다 (2026-09-07, 심볼 8302 개 전수 확인:
    /// eye 계열 중 속눈썹은 eyebrow 뿐이다). eyebrow 의 속눈썹은 감은 눈 전용 곡률이라
    /// 뜬 눈 위에 얹으면 어긋난다. 그래서 눈 타원 둘레의 법선 방향으로 직접 긋는다.
    ///
    /// pointSize 19 는 실측이다 (2026-09-07): 메뉴바에서 이웃 아이콘과 높이가 같다.
    /// 기본 크기로 두면 잉크가 13.0pt 라 혼자 작아 보인다.
    ///
    /// weight 는 regular, 나머지 수(개수 4 · 길이 1.8 · 퍼짐 1.60)는 스튜디오에서 눈으로
    /// 고른 값이다 (2026-09-07). 겹침 0.8 은 실측이다: 0.4 면 바깥 두 속눈썹이 눈에서
    /// 떠 보이고, 1.2 이상이면 안쪽 속눈썹이 눈꺼풀 선을 뚫고 들어온다.
    private static func eyeAndLashes() -> (eye: NSImage, lashes: [(CGPoint, CGPoint)]) {
        guard let raw = symbol("eye", pointSize: 19, weight: .regular) else { return (NSImage(), []) }
        let eye = trimmed(raw)
        let a = eye.size.width / 2, b = eye.size.height / 2
        let count = 4, spread = 1.60, length = 1.8, overlap = 0.8, yShift = 0.3

        let lashes = (0..<count).map { i -> (CGPoint, CGPoint) in
            // 위쪽 눈꺼풀 호를 spread 만큼 훑으며 등간격으로 뿌린다.
            let f = Double(i) / Double(count - 1)
            let t = .pi / 2 + (f - 0.5) * spread
            let px = a + a * cos(t), py = b + b * sin(t) - yShift
            // 타원의 바깥 법선. 접선에 수직으로 나가야 속눈썹이 눈에 박혀 보인다.
            var nx = cos(t) / a, ny = sin(t) / b
            let n = (nx * nx + ny * ny).squareRoot()
            nx /= n; ny /= n
            // overlap 만큼 눈 안쪽에서 시작해야 이음매가 안 보인다.
            return (CGPoint(x: px - nx * overlap, y: py - ny * overlap),
                    CGPoint(x: px + nx * (length - overlap), y: py + ny * (length - overlap)))
        }
        return (eye, lashes)
    }

    /// 뜬 눈 잉크 상자 (눈 잉크 좌표계). 속눈썹까지 감싼다.
    private static func openBox(_ eye: NSImage, _ lashes: [(CGPoint, CGPoint)]) -> CGRect {
        let xs: [CGFloat] = lashes.flatMap { [$0.0.x, $0.1.x] } + [0, eye.size.width]
        let ys: [CGFloat] = lashes.flatMap { [$0.0.y, $0.1.y] } + [0, eye.size.height]
        let pad = lashWidth / 2
        let minX = xs.min()! - pad, maxX = xs.max()! + pad
        let minY = ys.min()! - pad, maxY = ys.max()! + pad
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 눈꺼풀이 놓일 자리. 뜬 눈 상자 한가운데에서 lidOffset 만큼 옮긴 곳이다.
    private static func lidBox(_ open: CGRect, _ lid: NSImage) -> CGRect {
        CGRect(x: open.midX - lid.size.width / 2 + lidOffset.x,
               y: open.midY - lid.size.height / 2 + lidOffset.y,
               width: lid.size.width, height: lid.size.height)
    }

    /// 두 상태가 공유하는 캔버스. 눈꺼풀 자리까지 합쳐야 lidOffset 이 커도 잘리지 않고,
    /// 두 이미지 크기가 같아야 메뉴바에서 아이콘이 튀지 않는다.
    private static func canvas(_ open: CGRect, _ lid: CGRect) -> CGRect {
        open.union(lid)
    }

    /// 뜬 눈 = 시스템이 깨어 있음.
    private static func openEye() -> NSImage {
        let (eye, lashes) = eyeAndLashes()
        guard !lashes.isEmpty, let lid = lidImage() else { return eye }
        let open = openBox(eye, lashes)
        let box = canvas(open, lidBox(open, lid))
        return NSImage(size: box.size, flipped: false) { _ in
            eye.draw(in: CGRect(x: -box.minX, y: -box.minY,
                                width: eye.size.width, height: eye.size.height))
            NSColor.black.set()   // isTemplate 이라 실제 색은 메뉴바가 다시 칠한다.
            let path = NSBezierPath()
            path.lineWidth = lashWidth
            path.lineCapStyle = .round
            for (from, to) in lashes {
                path.move(to: CGPoint(x: from.x - box.minX, y: from.y - box.minY))
                path.line(to: CGPoint(x: to.x - box.minX, y: to.y - box.minY))
            }
            path.stroke()
            return true
        }
    }

    /// 감은 눈 = 평소대로 잘 수 있음.
    ///
    /// eye.closed 는 이 SF Symbols 버전에 없다 (2026-09-07 확인). eyebrow 가
    /// [눈썹 · 빈 띠 · 감은 눈꺼풀+속눈썹] 구성이라 아래쪽만 잘라 눈꺼풀로 쓴다.
    ///
    /// 0.46 은 실측이다 (2026-09-07): pointSize 19 에서 눈썹은 y 2.0~9.5pt, 눈꺼풀은
    /// y 12.0~18.25pt 이고 그 사이 y 9.75~11.75pt 가 완전히 비어 있다. 심볼 높이(20pt)
    /// 기준으로 그 빈 띠 아래가 46% 지점이다.
    ///
    /// pointSize 29 는 뜬 눈과 폭을 맞춘 값이다. weight 는 thin — eyebrow 를 크게 뽑아
    /// 쓰는 탓에 같은 weight 면 눈꺼풀 획만 유독 두껍다. 두 상태의 획을 눈으로 맞췄다
    /// (2026-09-07).
    ///
    /// ponytail: macOS 업데이트로 eyebrow 심볼 모양이 바뀌면 이 비율이 틀어진다.
    /// 증상은 눈썹이 남거나 속눈썹이 잘리는 것뿐이고 동작에는 영향이 없다. 틀어지면
    /// 심볼을 다시 렌더해 빈 띠 위치를 재고 두 상수만 고친다.
    private static func lidImage() -> NSImage? {
        guard let brow = symbol("eyebrow", pointSize: 29, weight: .thin) else { return nil }
        let full = brow.size
        let keep = full.height * 0.46
        // NSImage 좌표는 왼쪽 아래가 원점이라, 아래쪽 keep 만큼이 눈꺼풀이다.
        return trimmed(NSImage(size: NSSize(width: full.width, height: keep),
                               flipped: false) { rect in
            brow.draw(in: rect, from: NSRect(x: 0, y: 0, width: full.width, height: keep),
                      operation: .sourceOver, fraction: 1)
            return true
        })
    }

    private static func closedEye() -> NSImage {
        guard let lid = lidImage() else { return NSImage() }
        let (eye, lashes) = eyeAndLashes()
        guard !lashes.isEmpty else { return lid }
        let open = openBox(eye, lashes)
        let placed = lidBox(open, lid)
        let box = canvas(open, placed)
        return NSImage(size: box.size, flipped: false) { _ in
            lid.draw(in: placed.offsetBy(dx: -box.minX, dy: -box.minY))
            return true
        }
    }

    /// 이미지에서 투명한 가장자리를 잘라 잉크에 딱 맞춘다.
    ///
    /// 심볼마다 그림이 박스 안에 놓이는 위치가 달라, 그대로 쓰면 두 상태의 아이콘이
    /// 서로 다른 자리에 그려진다. 메뉴바는 항목을 오른쪽부터 쌓으므로 잉크 오른쪽
    /// 여백이 넓은 쪽이 왼쪽으로 밀려 보인다. (2026-09-07 실측: 감은 눈은 우여백
    /// 5.75pt, 뜬 눈은 2.75pt 로 3pt 어긋났다 — 눈으로도 보인다.)
    ///
    /// 잘라내면 메뉴바가 붙이는 여백만 남아 두 상태가 같은 자리에 온다.
    private static func trimmed(_ image: NSImage) -> NSImage {
        let size = image.size
        let scale = 2.0   // 레티나 기준. 잉크 경계만 찾으므로 이 이상은 낭비다.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // 잉크가 없으면(심볼 로드 실패 등) 원본을 그대로 돌려준다.
        guard maxX >= minX, maxY >= minY else { return image }

        // rep 은 위가 원점, NSImage 는 아래가 원점이라 y 를 뒤집어 잘라낸다.
        let box = NSRect(x: Double(minX) / scale,
                         y: size.height - Double(maxY + 1) / scale,
                         width: Double(maxX - minX + 1) / scale,
                         height: Double(maxY - minY + 1) / scale)
        return NSImage(size: box.size, flipped: false) { rect in
            image.draw(in: rect, from: box, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private static func symbol(_ name: String, pointSize: CGFloat,
                               weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

    /// 앱이 믿는 값이 아니라 IORegistry 에서 읽은 실제 값을 보여준다.
    private var statusLine: String {
        let sleep = controller.sleepDisabled ? "잠자기 비활성화" : "잠자기 활성화"
        let power = controller.source == .ac ? "충전 중" : "배터리"
        let lid = SystemState.clamshellClosed() == true ? " · 뚜껑 닫힘" : ""
        return "\(sleep) · \(power)\(lid)"
    }
}
