// 디자인 의도:
// - 어두운 슬레이트 squircle 바탕에 앰버 번개, 그 아래 닫힌 노트북을 옆에서 본 슬래브.
// - "충전기가 꽂혀 있으면 뚜껑을 닫아도 깨어 있다" 는 이 앱의 동작을 그대로 그린 것이다.
// - SF Symbols 를 쓰지 않고 직접 그렸다. SF Symbols 는 라이선스상 앱 아이콘에 쓸 수 없다.
// - 뚜껑 이음선은 64px 미만에서 생략된다. 작은 크기에서 뭉개지기 때문이다.
import AppKit

func draw(_ size: CGFloat) -> Data {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let inset = size * 0.055
    let r = CGRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
    NSBezierPath(roundedRect: r, xRadius: size*0.225, yRadius: size*0.225).fill()
    NSColor(calibratedRed: 0.098, green: 0.114, blue: 0.137, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: size*0.225, yRadius: size*0.225).fill()

    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: r.minX + r.width*x, y: r.minY + r.height*y)
    }
    let amber = NSColor(calibratedRed: 0.878, green: 0.627, blue: 0.290, alpha: 1)
    let slate = NSColor(calibratedRed: 0.443, green: 0.490, blue: 0.545, alpha: 1)

    // 닫힌 노트북 (옆에서 본 슬래브)
    let slab = NSBezierPath(roundedRect:
        CGRect(x: pt(0.135,0).x, y: pt(0,0.145).y, width: r.width*0.73, height: r.height*0.105),
        xRadius: r.height*0.028, yRadius: r.height*0.028)
    slate.setFill(); slab.fill()
    // 뚜껑 이음선. 16px 에서는 사라지지만 큰 크기에서 "닫힌 노트북" 을 읽히게 한다
    if size >= 64 {
        let seam = NSBezierPath(rect:
            CGRect(x: pt(0.155,0).x, y: pt(0,0.205).y, width: r.width*0.69, height: max(1, r.height*0.012)))
        NSColor(calibratedRed: 0.098, green: 0.114, blue: 0.137, alpha: 0.55).setFill()
        seam.fill()
    }

    // 번개
    let p = NSBezierPath()
    p.move(to: pt(0.575, 0.870))
    p.line(to: pt(0.310, 0.545))
    p.line(to: pt(0.462, 0.545))
    p.line(to: pt(0.432, 0.345))
    p.line(to: pt(0.692, 0.598))
    p.line(to: pt(0.540, 0.598))
    p.close()
    amber.setFill(); p.fill()

    img.unlockFocus()
    return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
}

@main struct G {
    static func main() {
        let dir = CommandLine.arguments[1]
        for s in [16,32,64,128,256,512,1024] {
            try! draw(CGFloat(s)).write(to: URL(fileURLWithPath: "\(dir)/icon_\(s).png"))
        }
        print("아이콘 PNG 생성 완료")
    }
}
