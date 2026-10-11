import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon-1024.png"
let canvasSize = NSSize(width: 1024, height: 1024)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func strokeLine(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat, cap: NSBezierPath.LineCapStyle = .round) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = cap
    path.move(to: start)
    path.line(to: end)
    color.setStroke()
    path.stroke()
}

func drawCaptureCorner(origin: NSPoint, horizontal: CGFloat, vertical: CGFloat, xDirection: CGFloat, yDirection: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = 32
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: origin)
    path.relativeLine(to: NSPoint(x: horizontal * xDirection, y: 0))
    path.move(to: origin)
    path.relativeLine(to: NSPoint(x: 0, y: vertical * yDirection))
    color(239, 252, 255, 0.9).setStroke()
    path.stroke()
}

let image = NSImage(size: canvasSize)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Cannot create drawing context")
}

context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 32, color: color(7, 18, 30, 0.34).cgColor)

let iconRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let background = roundedRect(iconRect, radius: 205)
background.addClip()

let gradient = NSGradient(colors: [
    color(19, 45, 72),
    color(28, 119, 132),
    color(43, 172, 144)
])!
gradient.draw(in: iconRect, angle: -42)

context.setShadow(offset: .zero, blur: 0, color: nil)

// Subtle light wash in the top-right corner.
let glow = NSGradient(colors: [
    color(255, 255, 255, 0.34),
    color(255, 255, 255, 0.0)
])!
glow.draw(in: NSRect(x: 470, y: 520, width: 420, height: 360), relativeCenterPosition: NSPoint(x: 0.25, y: 0.25))

// Screen capture brackets.
drawCaptureCorner(origin: NSPoint(x: 205, y: 820), horizontal: 142, vertical: 142, xDirection: 1, yDirection: -1)
drawCaptureCorner(origin: NSPoint(x: 819, y: 820), horizontal: 142, vertical: 142, xDirection: -1, yDirection: -1)
drawCaptureCorner(origin: NSPoint(x: 205, y: 204), horizontal: 142, vertical: 142, xDirection: 1, yDirection: 1)
drawCaptureCorner(origin: NSPoint(x: 819, y: 204), horizontal: 142, vertical: 142, xDirection: -1, yDirection: 1)

// Main todo card.
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: color(4, 21, 32, 0.28).cgColor)
let cardRect = NSRect(x: 250, y: 265, width: 524, height: 445)
let card = roundedRect(cardRect, radius: 58)
color(247, 252, 255, 0.96).setFill()
card.fill()
context.setShadow(offset: .zero, blur: 0, color: nil)

let cardStroke = roundedRect(cardRect.insetBy(dx: 10, dy: 10), radius: 48)
cardStroke.lineWidth = 4
color(255, 255, 255, 0.7).setStroke()
cardStroke.stroke()

// OCR text lines.
let lineColor = color(47, 81, 105, 0.42)
for (index, width) in [255, 310, 220].enumerated() {
    let y = CGFloat(615 - index * 58)
    let line = roundedRect(NSRect(x: 390, y: y, width: CGFloat(width), height: 20), radius: 10)
    lineColor.setFill()
    line.fill()
}

// Checkbox row.
let checkbox = roundedRect(NSRect(x: 330, y: 508, width: 42, height: 42), radius: 12)
color(25, 127, 144, 0.14).setFill()
checkbox.fill()
checkbox.lineWidth = 5
color(28, 126, 143, 0.55).setStroke()
checkbox.stroke()

// Large checkmark, drawn as the task completion signal.
let check = NSBezierPath()
check.lineWidth = 46
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.move(to: NSPoint(x: 346, y: 431))
check.line(to: NSPoint(x: 454, y: 337))
check.line(to: NSPoint(x: 680, y: 595))
color(38, 223, 174).setStroke()
check.stroke()

let checkHighlight = NSBezierPath()
checkHighlight.lineWidth = 18
checkHighlight.lineCapStyle = .round
checkHighlight.lineJoinStyle = .round
checkHighlight.move(to: NSPoint(x: 359, y: 434))
checkHighlight.line(to: NSPoint(x: 454, y: 353))
checkHighlight.line(to: NSPoint(x: 667, y: 596))
color(243, 255, 251, 0.62).setStroke()
checkHighlight.stroke()

// Small scan cursor dot.
let dotRect = NSRect(x: 707, y: 676, width: 46, height: 46)
let dot = NSBezierPath(ovalIn: dotRect)
color(38, 223, 174).setFill()
dot.fill()

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode icon PNG")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try pngData.write(to: outputURL)

// `lockFocus()` can render at the display backing scale. Normalize the project preview
// image to an exact 1024x1024 file while keeping the same drawn icon.
let normalizationTask = Process()
normalizationTask.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
normalizationTask.arguments = ["-z", "1024", "1024", outputURL.path, "--out", outputURL.path]
try normalizationTask.run()
normalizationTask.waitUntilExit()

print(outputURL.path)
