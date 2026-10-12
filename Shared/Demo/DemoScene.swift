import SwiftUI
#if os(macOS)
import AppKit
#endif

/// An illustrated group photo used in place of the camera feed for App Store-style screenshots
/// (no real people, no stock photos). Debug builds only; see `DemoMode`.
struct DemoScene: View {
    struct Person {
        let x: CGFloat
        let skin: Color
        let hair: Color
        let shirt: Color
        let height: CGFloat
    }

    static let people: [Person] = [
        Person(x: 0.24, skin: Color(red: 0.93, green: 0.76, blue: 0.62), hair: Color(red: 0.30, green: 0.20, blue: 0.14),
               shirt: Color(red: 0.16, green: 0.62, blue: 0.62), height: 0.47),
        Person(x: 0.50, skin: Color(red: 0.62, green: 0.43, blue: 0.31), hair: Color(red: 0.10, green: 0.09, blue: 0.09),
               shirt: Color(red: 0.95, green: 0.45, blue: 0.36), height: 0.43),
        Person(x: 0.76, skin: Color(red: 0.85, green: 0.65, blue: 0.50), hair: Color(red: 0.78, green: 0.58, blue: 0.32),
               shirt: Color(red: 0.22, green: 0.30, blue: 0.55), height: 0.48),
    ]

    /// People (by index) shown looking away from the camera, for the "not ready" screenshot.
    var lookingAway: Set<Int> = []

    /// Head radius as a fraction of the scene width.
    static let headRadius: CGFloat = 0.075

    /// Where each face is, in the same normalized, top-left coordinates the detector reports.
    static func faceBoxes(aspect: CGFloat) -> [CGRect] {
        people.map { p in
            let rx = headRadius, ry = headRadius * aspect
            return CGRect(x: p.x - rx, y: p.height - ry, width: rx * 2, height: ry * 2)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Golden-hour sky
                LinearGradient(colors: [Color(red: 0.98, green: 0.80, blue: 0.58),
                                        Color(red: 0.96, green: 0.62, blue: 0.52),
                                        Color(red: 0.55, green: 0.47, blue: 0.68)],
                               startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Color(red: 1, green: 0.93, blue: 0.75).opacity(0.9))
                    .frame(width: w * 0.28)
                    .blur(radius: 6)
                    .position(x: w * 0.72, y: h * 0.22)
                // Hills
                Hill(peak: 0.55, height: 0.36).fill(Color(red: 0.42, green: 0.40, blue: 0.62).opacity(0.75))
                Hill(peak: 0.2, height: 0.30).fill(Color(red: 0.33, green: 0.36, blue: 0.55))
                // Ground
                Rectangle()
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.40), Color(red: 0.22, green: 0.36, blue: 0.29)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: h * 0.3)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                ForEach(Array(Self.people.enumerated()), id: \.offset) { i, p in
                    figure(p, w: w, h: h, away: lookingAway.contains(i))
                }
            }
            .clipped()
        }
    }

    private func figure(_ p: Person, w: CGFloat, h: CGFloat, away: Bool) -> some View {
        let r = Self.headRadius * w
        let cx = p.x * w, cy = p.height * h
        // Looking away: the face slides to one side and the head tilts, like a turned head.
        let faceShift = away ? r * 0.33 : 0
        return ZStack {
            // Shoulders and body
            UnevenRoundedRectangle(topLeadingRadius: r * 1.2, topTrailingRadius: r * 1.2)
                .fill(p.shirt)
                .frame(width: r * 3.4, height: h)
                .position(x: cx, y: cy + r * 1.05 + h / 2)
            // Neck
            Capsule().fill(p.skin.opacity(0.92)).frame(width: r * 0.7, height: r * 0.8)
                .position(x: cx, y: cy + r * 0.95)
            // Head, hair and a friendly face
            ZStack {
                Circle().fill(p.skin).frame(width: r * 2, height: r * 2).position(x: cx, y: cy)
                Circle()
                    .trim(from: 0.5, to: 1)
                    .fill(p.hair)
                    .frame(width: r * 2.08, height: r * 2.08)
                    .position(x: cx, y: cy - r * 0.18)
                HStack(spacing: r * 0.55) {
                    Circle().fill(.black.opacity(0.75)).frame(width: r * 0.2)
                    Circle().fill(.black.opacity(0.75)).frame(width: r * 0.2)
                }
                .position(x: cx + faceShift, y: cy + r * 0.12)
                Circle()
                    .trim(from: 0.08, to: 0.42)
                    .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: r * 0.09, lineCap: .round))
                    .frame(width: r * 0.8, height: r * 0.8)
                    .position(x: cx + faceShift, y: cy + r * 0.12)
            }
            .frame(width: w, height: h)
            .rotationEffect(.degrees(away ? 9 : 0), anchor: UnitPoint(x: cx / w, y: cy / h))
        }
    }

    private struct Hill: Shape {
        let peak: CGFloat
        let height: CGFloat
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let base = rect.height * 0.72
            path.move(to: CGPoint(x: 0, y: base))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: base),
                              control: CGPoint(x: rect.width * peak, y: base - rect.height * height))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
            return path
        }
    }
}

/// Debug-only screenshot mode, chosen with a launch argument: `-SmartShotDemo holding|waiting|format`.
enum DemoMode {
    static var scene: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SmartShotDemo"), i + 1 < args.count else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }

    /// With `-SmartShotSnapshot <name>` (Mac, debug only), saves the window as a PNG in the app's temporary folder and quits,
    /// so store screenshots can be made without screen-recording permission.
    static func snapshotIfRequested() {
        #if DEBUG && os(macOS)
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SmartShotSnapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(path)   // inside the sandbox container
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            NSApp.terminate(nil)
        }
        #endif
    }
}
