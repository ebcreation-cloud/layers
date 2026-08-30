import AppKit
import ImageIO
import CoreGraphics
import Foundation

// 아이콘은 앱이 실제로 그리는 것과 같은 형태여야 한다. 월 뷰를 가로지르는 막대를
// 그대로 마크로 쓴다. 네이비 바탕에 층이 어긋나며 쌓이고, 맨 위 한 층만 청록으로 든다.

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255,
            green: CGFloat((hex >> 8) & 0xFF)/255,
            blue: CGFloat(hex & 0xFF)/255, alpha: a)
}

func render(size S: CGFloat, rounded: Bool, variant: String) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let u = S / 1024   // 1024 기준으로 그리고 배율만 바꾼다

    // 바탕
    let dark = variant == "dark"
    if rounded {
        let r = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                       cornerWidth: 224*u, cornerHeight: 224*u, transform: nil)
        ctx.addPath(r); ctx.clip()
    }
    ctx.setFillColor(color(dark ? 0x111111 : 0xFAFAFA))
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

    // 층 넷. 위로 갈수록 좁아지고 오른쪽으로 밀려서 겹쳐 쌓인 느낌을 낸다.
    struct Bar { let w: CGFloat; let x: CGFloat; let y: CGFloat; let c: CGColor }
    // 네 층의 폭 580, 어긋남 44, 높이 108, 간격 34.
    // 전체 묶음이 1024 안에서 가로세로 정확히 가운데 오도록 계산한 값이다.
    // 흑백에서는 층의 밝기 차이가 곧 깊이다. 색이 없으니 그 계단이 유일한 단서가 된다.
    let h: CGFloat = 108
    let ink: UInt32 = dark ? 0xFFFFFF : 0x111111
    let bars: [Bar] = [
        Bar(w: 580, x: 156, y: 245, c: color(ink, 0.22)),
        Bar(w: 580, x: 200, y: 387, c: color(ink, 0.44)),
        Bar(w: 580, x: 244, y: 529, c: color(ink, 0.70)),
        Bar(w: 580, x: 288, y: 671, c: color(ink, 1.00)),
    ]
    for b in bars {
        ctx.setFillColor(b.c)
        let rect = CGRect(x: b.x*u, y: b.y*u, width: b.w*u, height: h*u)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 24*u, cornerHeight: 24*u, transform: nil))
        ctx.fillPath()
    }
    return ctx.makeImage()
}

func write(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments[1]
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
// iOS 는 시스템이 모서리를 깎으므로 사각형으로, macOS 는 둥근 모서리로 낸다.
if let i = render(size: 1024, rounded: false, variant: variant) { write(i, to: "\(out)/icon-ios-1024.png") }
for s in [16, 32, 64, 128, 256, 512, 1024] {
    if let i = render(size: CGFloat(s), rounded: true, variant: variant) { write(i, to: "\(out)/mac-\(s).png") }
}
print("아이콘 렌더 완료")
