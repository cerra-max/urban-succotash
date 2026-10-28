// 生成 App 图标：icon <输出的 .iconset 目录>
import Cocoa

func draw(_ px: Int) -> Data {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext

  // macOS 图标网格：824/1024 的圆角方块
  let inset = s * 100 / 1024, side = s - inset * 2
  let card = CGRect(x: inset, y: inset, width: side, height: side)
  let path = CGPath(roundedRect: card, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
  ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(path); ctx.clip()
  let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 1, green: 1, blue: 1, alpha: 1).cgColor,
                                 NSColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
  ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: card.maxY), end: CGPoint(x: 0, y: card.minY), options: [])
  // 点阵
  ctx.setFillColor(NSColor(red: 0.80, green: 0.81, blue: 0.84, alpha: 1).cgColor)
  let step = side / 9
  for i in 1..<9 { for j in 1..<9 {
    let r = s * 0.006
    ctx.fillEllipse(in: CGRect(x: card.minX + CGFloat(i) * step - r, y: card.minY + CGFloat(j) * step - r, width: r * 2, height: r * 2))
  } }

  let u = side / 100
  func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: card.minX + x * u, y: card.maxY - y * u) }
  // 分支
  let branches: [(CGFloat, NSColor)] = [
    (24, NSColor(red: 0.95, green: 0.36, blue: 0.33, alpha: 1)),
    (50, NSColor(red: 0.97, green: 0.62, blue: 0.23, alpha: 1)),
    (76, NSColor(red: 0.24, green: 0.55, blue: 0.91, alpha: 1)),
  ]
  ctx.setLineCap(.round)
  for (y, c) in branches {
    ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(u * 3.2)
    ctx.move(to: P(42, 50)); ctx.addCurve(to: P(62, y), control1: P(52, 50), control2: P(52, y)); ctx.strokePath()
    ctx.setFillColor(c.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(origin: P(62, y + 6), size: CGSize(width: 24 * u, height: 12 * u)),
                       cornerWidth: 3.5 * u, cornerHeight: 3.5 * u, transform: nil))
    ctx.fillPath()
  }
  // 中心主题
  ctx.setFillColor(NSColor(red: 0.18, green: 0.20, blue: 0.25, alpha: 1).cgColor)
  ctx.addPath(CGPath(roundedRect: CGRect(origin: P(12, 59), size: CGSize(width: 32 * u, height: 18 * u)),
                     cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil))
  ctx.fillPath()
  // 便签
  ctx.saveGState()
  ctx.translateBy(x: P(22, 22).x, y: P(22, 22).y); ctx.rotate(by: 0.12)
  ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.6), blur: u * 1.5, color: NSColor.black.withAlphaComponent(0.2).cgColor)
  ctx.setFillColor(NSColor(red: 1, green: 0.90, blue: 0.56, alpha: 1).cgColor)
  ctx.fill(CGRect(x: -11 * u, y: -11 * u, width: 22 * u, height: 22 * u))
  ctx.restoreGState()
  ctx.restoreGState()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
  try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
